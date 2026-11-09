import Foundation
import Vapor

// SessionAuthenticator logs this in only after verifying a real session.
// Never trust a user ID supplied in query parameters or unverified headers.
// A validated request identity, separate from the stored Account model.
struct AuthenticatedUser: Authenticatable, Sendable {
    let id: String
    let displayName: String
    let verified: Bool
}

func configureRoutes(_ app: Application, catalog: Catalog) {
    // Uploaded versions are immutable; replacing a set changes the listing's URLs.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    let photoStorage = PhotoStorage(publicDirectory: app.directory.publicDirectory)

    app.get("health") { _ in ["status": "ok"] }
    let listings = app.grouped("api", "v1", "listings")
    listings.get { req async throws -> [Listing] in
        let query = try req.query.decode(SearchQuery.self)
        return try await catalog.search(query.q ?? "")
    }
    listings.get(":id") { req async throws -> Listing in
        guard let id = req.parameters.get("id"), let listing = try await catalog.active(id) else {
            throw Abort(.notFound, reason: "This listing is unavailable.")
        }
        return listing
    }

    // Publish. The guard rejects anonymous callers and the verified flag comes
    // from the session, so the client can never claim a seller or a status.
    listings.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware()).post { req async throws -> Response in
        let user = try req.auth.require(AuthenticatedUser.self)
        guard user.verified else {
            throw Abort(.forbidden, reason: "Verify your KU email before publishing.")
        }
        do {
            let draft = try ListingDraft(try req.content.decode(CreateListingBody.self))
            let listing = Listing(
                id: UUID().uuidString.lowercased(),
                title: draft.title, description: draft.description,
                priceCents: draft.priceCents, condition: draft.condition, category: draft.category,
                sellerDisplayName: user.displayName, pickupArea: draft.pickupArea, photoURLs: [])
            try await catalog.add(listing, ownerID: user.id)
            let response = Response(status: .created)
            response.headers.replaceOrAdd(name: .location, value: "/api/v1/listings/\(listing.id)")
            try response.content.encode(listing)
            return response
        } catch let failure as ListingFieldErrors {
            let response = Response(status: .unprocessableEntity)
            try response.content.encode(FieldErrorBody(message: "Check the highlighted fields.", fieldErrors: failure.fields))
            return response
        }
    }

    // Upload photos for a listing the caller owns (multipart, field `photos[]`).
    // Replaces the whole set; the first file is the primary photo.
    listings.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())
        .on(.POST, ":id", "photos", body: .collect(maxSize: "45mb")) { req async throws -> Response in
            let user = try req.auth.require(AuthenticatedUser.self)
            guard user.verified else {
                throw Abort(.forbidden, reason: "Verify your KU email before publishing.")
            }
            guard let id = req.parameters.get("id"),
                  (try await catalog.owned(by: user.id)).contains(where: { $0.listing.id == id && $0.status == .active }) else {
                throw Abort(.notFound, reason: "This listing is unavailable.")
            }
            do {
                let body: PhotoUploadBody
                do {
                    body = try req.content.decode(PhotoUploadBody.self)
                } catch let failure as AbortError {
                    throw failure
                } catch {
                    throw Abort(.badRequest, reason: "The photo upload body is malformed.")
                }
                let upload = try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
                    try PhotoUpload(body)
                }.get()
                let listing = try await photoStorage.replace(listingID: id, ownerID: user.id, with: upload, catalog: catalog, on: req)
                let response = Response(status: .ok)
                try response.content.encode(listing)
                return response
            } catch let failure as ListingFieldErrors {
                let response = Response(status: .unprocessableEntity)
                try response.content.encode(FieldErrorBody(message: "Check the highlighted fields.", fieldErrors: failure.fields))
                return response
            }
        }

    let mine = app.grouped("api", "v1", "me", "listings")
        .grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())
    mine.get { req async throws -> [OwnedListing] in
        let user = try req.auth.require(AuthenticatedUser.self)
        return try await catalog.owned(by: user.id)
    }
    mine.get(":id") { req async throws -> OwnedListing in
        let user = try req.auth.require(AuthenticatedUser.self)
        guard let id = req.parameters.get("id"),
              let listing = try await catalog.owned(by: user.id).first(where: { $0.listing.id == id }) else {
            throw Abort(.notFound, reason: "This listing is unavailable.")
        }
        return listing
    }
}

private struct SearchQuery: Decodable { let q: String? }
