import Foundation
import Vapor

// The accounts feature must log this in only after verifying a real session.
// Never trust a user ID supplied in query parameters or unverified headers.
struct MarketplaceUser: Authenticatable, Sendable {
    let id: String
    let displayName: String
    let verified: Bool
}

func configureRoutes(_ app: Application, catalog: Catalog = Catalog()) {
    // Serves uploaded listing photos from Public/ (e.g. /uploads/listings/<id>/0-<uuid>.jpg).
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    let photoStorage = PhotoStorage(publicDirectory: app.directory.publicDirectory)

    app.get("health") { _ in ["status": "ok"] }
    let listings = app.grouped("api", "v1", "listings")
    listings.get { req -> [Listing] in
        let query = try req.query.decode(SearchQuery.self)
        return catalog.search(query.q ?? "")
    }
    listings.get(":id") { req -> Listing in
        guard let id = req.parameters.get("id"), let listing = catalog.active(id) else {
            throw Abort(.notFound, reason: "This listing is unavailable.")
        }
        return listing
    }

    // Publish. The guard rejects anonymous callers and the verified flag comes
    // from the session, so the client can never claim a seller or a status.
    listings.grouped(MarketplaceUser.guardMiddleware()).post { req async throws -> Response in
        let user = try req.auth.require(MarketplaceUser.self)
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
            catalog.add(listing, ownerID: user.id)
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
    listings.grouped(MarketplaceUser.guardMiddleware())
        .on(.POST, ":id", "photos", body: .collect(maxSize: "45mb")) { req async throws -> Response in
            let user = try req.auth.require(MarketplaceUser.self)
            guard user.verified else {
                throw Abort(.forbidden, reason: "Verify your KU email before publishing.")
            }
            guard let id = req.parameters.get("id"),
                  catalog.owned(by: user.id).contains(where: { $0.listing.id == id && $0.status == .active }) else {
                throw Abort(.notFound, reason: "This listing is unavailable.")
            }
            do {
                let upload = try PhotoUpload(try req.content.decode(PhotoUploadBody.self))
                let urls = try await photoStorage.replace(listingID: id, with: upload, on: req)
                guard let listing = catalog.replacePhotos(urls, listingID: id, ownerID: user.id) else {
                    throw Abort(.notFound, reason: "This listing is unavailable.")
                }
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
        .grouped(MarketplaceUser.guardMiddleware())
    mine.get { req -> [OwnedListing] in
        let user = try req.auth.require(MarketplaceUser.self)
        return catalog.owned(by: user.id)
    }
    mine.get(":id") { req -> OwnedListing in
        let user = try req.auth.require(MarketplaceUser.self)
        guard let id = req.parameters.get("id"),
              let listing = catalog.owned(by: user.id).first(where: { $0.listing.id == id }) else {
            throw Abort(.notFound, reason: "This listing is unavailable.")
        }
        return listing
    }
}

private struct SearchQuery: Decodable { let q: String? }
