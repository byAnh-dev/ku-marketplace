import Vapor

// The accounts feature must log this in only after verifying a real session.
// Never trust a user ID supplied in query parameters or unverified headers.
struct MarketplaceUser: Authenticatable, Sendable {
    let id: String
}

func configureRoutes(_ app: Application, catalog: Catalog = Catalog()) {
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
