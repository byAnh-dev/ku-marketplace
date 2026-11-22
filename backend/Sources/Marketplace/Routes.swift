
import Foundation
import Vapor

struct AuthenticatedUser: Authenticatable, Sendable {
    let id: String
    let displayName: String
    let verified: Bool
}

func configureRoutes(
    _ app: Application,
    catalog: Catalog
) {
    app.middleware.use(
        PhotoDeliveryMiddleware(
            publicDirectory: app.directory.publicDirectory
        )
    )

    app.middleware.use(
        FileMiddleware(
            publicDirectory: app.directory.publicDirectory
        )
    )

    let photoStorage = PhotoStorage(
        publicDirectory: app.directory.publicDirectory
    )

    app.get("health") { _ in
        ["status": "ok"]
    }

    let listings = app.grouped("api", "v1", "listings")

    // Public browse and pagination.
    listings.get { req async throws -> Response in
        let query = try req.query.decode(SearchQuery.self)
        let filters: ListingFilters
        do {
            filters = try ListingFilters(
                category: query.category,
                condition: query.condition,
                minPriceCents: query.minPriceCents,
                maxPriceCents: query.maxPriceCents
            )
        } catch let failure as ListingFieldErrors {
            let response = Response(status: .unprocessableEntity)
            try response.content.encode(
                FieldErrorBody(
                    message: "Check the filter values.",
                    fieldErrors: failure.fields
                )
            )
            return response
        }

        let page = try await catalog.search(
            query.q ?? "",
            page: query.page ?? 1,
            per: query.per ?? 20,
            filters: filters
        )
        let response = Response(status: .ok)

        response.headers.replaceOrAdd(
            name: "X-Page",
            value: String(page.page)
        )

        response.headers.replaceOrAdd(
            name: "X-Page-Size",
            value: String(page.per)
        )

        response.headers.replaceOrAdd(
            name: "X-Has-More",
            value: page.hasMore ? "true" : "false"
        )

        try response.content.encode(page.items)
        return response
    }

    listings.get(":id") { req async throws -> Listing in
        guard let id = req.parameters.get("id"),
              let listing = try await catalog.active(id)
        else {
            throw Abort(
                .notFound,
                reason: "This listing is unavailable."
            )
        }

        return listing
    }

    listings.grouped(
        SessionAuthenticator(),
        AuthenticatedUser.guardMiddleware()
    )
    .on(
        .POST,
        body: .collect(maxSize: "55mb")
    ) { req async throws -> Response in

        let user = try req.auth.require(
            AuthenticatedUser.self
        )

        guard user.verified else {
            throw Abort(
                .forbidden,
                reason: "Verify your KU email before publishing."
            )
        }

        do {
            let (draft, photos) = try decodePublishRequest(req)

            let id = UUID().uuidString.lowercased()

            let urls = try await photoStorage.prepareForPublish(
                photos,
                listingID: id,
                on: req
            )

            let listing = Listing(
                id: id,
                title: draft.title,
                description: draft.description,
                priceCents: draft.priceCents,
                condition: draft.condition,
                category: draft.category,
                sellerDisplayName: user.displayName,
                pickupArea: draft.pickupArea,
                photoURLs: urls
            )

            do {
                // Catalog.add applies the persistent rolling
                // five-listings-per-ten-minutes limit.
                try await catalog.add(
                    listing,
                    ownerID: user.id
                )
            } catch {
                // A failed insert must not leave public photos.
                await photoStorage.discard(
                    urls,
                    listingID: id,
                    on: req
                )
                throw error
            }

            let response = Response(status: .created)

            response.headers.replaceOrAdd(
                name: .location,
                value: "/api/v1/listings/\(listing.id)"
            )

            try response.content.encode(listing)
            return response

        } catch let failure as ListingFieldErrors {
            let response = Response(
                status: .unprocessableEntity
            )

            try response.content.encode(
                FieldErrorBody(
                    message: "Check the highlighted fields.",
                    fieldErrors: failure.fields
                )
            )

            return response
        }
    }

    // Edit an owned active listing.
    listings.grouped(
        SessionAuthenticator(),
        AuthenticatedUser.guardMiddleware()
    )
    .patch(":id") { req async throws -> Response in

        let user = try req.auth.require(
            AuthenticatedUser.self
        )

        guard user.verified else {
            throw Abort(
                .forbidden,
                reason: "Verify your KU email before editing."
            )
        }

        guard let id = req.parameters.get("id") else {
            throw Abort(.notFound)
        }

        guard let revision = req.headers.first(
            name: .ifMatch
        ), !revision.isEmpty else {
            throw Abort(
                .preconditionRequired,
                reason: "Reload the listing before saving."
            )
        }

        do {
            let draft = try ListingDraft(
                try req.content.decode(CreateListingBody.self)
            )

            let updated = try await catalog.edit(
                draft,
                listingID: id,
                ownerID: user.id,
                revision: revision
            )

            let response = Response(status: .ok)
            try response.content.encode(updated)
            return response

        } catch let failure as ListingFieldErrors {
            let response = Response(
                status: .unprocessableEntity
            )

            try response.content.encode(
                FieldErrorBody(
                    message: "Check the highlighted fields.",
                    fieldErrors: failure.fields
                )
            )

            return response
        }
    }

    // Sold and deleted listing actions.
    let managed = listings.grouped(
        SessionAuthenticator(),
        AuthenticatedUser.guardMiddleware()
    )

    managed.post(":id", "sold") {
        req async throws -> OwnedListing in

        try await changeListingStatus(
            req,
            catalog: catalog,
            target: .sold
        )
    }

    managed.delete(":id") {
        req async throws -> OwnedListing in

        try await changeListingStatus(
            req,
            catalog: catalog,
            target: .deleted
        )
    }

    // Replace photos for an owned listing.
    listings.grouped(
        SessionAuthenticator(),
        AuthenticatedUser.guardMiddleware()
    )
    .on(
        .POST,
        ":id",
        "photos",
        body: .collect(maxSize: "55mb")
    ) { req async throws -> Response in

        let user = try req.auth.require(
            AuthenticatedUser.self
        )

        guard user.verified else {
            throw Abort(
                .forbidden,
                reason: "Verify your KU email before publishing."
            )
        }

        guard let id = req.parameters.get("id") else {
            throw Abort(
                .notFound,
                reason: "This listing is unavailable."
            )
        }

        do {
            let body: PhotoUploadBody

            do {
                body = try req.content.decode(
                    PhotoUploadBody.self
                )
            } catch let failure as AbortError {
                throw failure
            } catch {
                throw Abort(
                    .badRequest,
                    reason: "The photo upload body is malformed."
                )
            }

            let upload = try await req.application.threadPool
                .runIfActive(eventLoop: req.eventLoop) {
                    try PhotoUpload(body)
                }
                .get()

            let listing = try await photoStorage.replace(
                listingID: id,
                ownerID: user.id,
                with: upload,
                catalog: catalog,
                on: req
            )

            let response = Response(status: .ok)
            try response.content.encode(listing)
            return response

        } catch let failure as ListingFieldErrors {
            let response = Response(
                status: .unprocessableEntity
            )

            try response.content.encode(
                FieldErrorBody(
                    message: "Check the highlighted fields.",
                    fieldErrors: failure.fields
                )
            )

            return response
        }
    }

    let mine = app.grouped(
        "api", "v1", "me", "listings"
    )
    .grouped(
        SessionAuthenticator(),
        AuthenticatedUser.guardMiddleware()
    )

    mine.get { req async throws -> [OwnedListing] in
        let user = try req.auth.require(
            AuthenticatedUser.self
        )

        return try await catalog.owned(by: user.id)
    }

    mine.get(":id") {
        req async throws -> OwnedListing in

        let user = try req.auth.require(
            AuthenticatedUser.self
        )

        guard let id = req.parameters.get("id"),
              let listing = try await catalog.owned(
                listingID: id,
                by: user.id
              )
        else {
            throw Abort(
                .notFound,
                reason: "This listing is unavailable."
            )
        }

        return listing
    }
}

private func changeListingStatus(
    _ req: Request,
    catalog: Catalog,
    target: Catalog.Status
) async throws -> OwnedListing {

    let user = try req.auth.require(
        AuthenticatedUser.self
    )

    guard user.verified else {
        throw Abort(
            .forbidden,
            reason: "Verify your KU email before managing listings."
        )
    }

    guard let id = req.parameters.get("id") else {
        throw Abort(.notFound)
    }

    guard let revision = req.headers.first(
        name: .ifMatch
    ), !revision.isEmpty else {
        throw Abort(
            .preconditionRequired,
            reason: "Reload your listings before trying again."
        )
    }

    return try await catalog.changeStatus(
        target,
        listingID: id,
        ownerID: user.id,
        revision: revision
    )
}

private struct SearchQuery: Decodable {
    let q: String?
    let page: Int?
    let per: Int?
    // Strings so an invalid price becomes a `422` field error rather than a `400` decode failure.
    let category: String?
    let condition: String?
    let minPriceCents: String?
    let maxPriceCents: String?
}

private struct PublishWithPhotosBody: Content {
    let listing: String
    let photos: [File]
}

private func decodePublishRequest(
    _ req: Request
) throws -> (ListingDraft, [File]) {

    guard let type = req.headers.contentType,
          type.type == "multipart",
          type.subType == "form-data"
    else {
        return (
            try ListingDraft(
                try req.content.decode(CreateListingBody.self)
            ),
            []
        )
    }

    let form: PublishWithPhotosBody
    let fields: CreateListingBody

    do {
        form = try req.content.decode(
            PublishWithPhotosBody.self
        )

        fields = try JSONDecoder().decode(
            CreateListingBody.self,
            from: Data(form.listing.utf8)
        )
    } catch {
        throw Abort(
            .badRequest,
            reason: "Send listing details and selected photos in the multipart form."
        )
    }

    return (try ListingDraft(fields), form.photos)
}
