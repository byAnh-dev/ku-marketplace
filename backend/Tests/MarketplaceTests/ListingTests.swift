@testable import Marketplace
import Testing
import VaporTesting

// Only linked into the test target. No fake login is exposed by the server.
private struct TestUser: AsyncMiddleware {
    let id: String
    var displayName = "Test Seller"
    var verified = true
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.auth.login(MarketplaceUser(id: id, displayName: displayName, verified: verified))
        return try await next.respond(to: request)
    }
}

/// Publish body for tests, including fields the server must ignore so the
/// forged-seller and forged-status cases can be exercised.
private struct PublishBody: Content {
    var title = "Gooseneck desk lamp"
    var description = "Warm light with a clamp base."
    var priceCents = 1200
    var category = "Dorm essentials"
    var condition = "Good"
    var pickupArea: String? = nil
    var sellerDisplayName: String? = nil
    var ownerID: String? = nil
    var id: String? = nil
    var status: String? = nil
}

@Suite struct ListingTests {
    private func fixture() -> Catalog {
        Catalog(rows: [
            row("active", owner: "alice", status: .active),
            row("sold", owner: "alice", status: .sold),
            row("reserved", owner: "alice", status: .reserved),
            row("deleted", owner: "alice", status: .deleted),
            row("other", owner: "bob", status: .active)
        ])
    }

    private func row(_ id: String, owner: String, status: Catalog.Status) -> Catalog.Row {
        Catalog.Row(ownerID: owner, status: status, listing: Listing(
            id: id, title: "Desk lamp", description: "For a DORM room", priceCents: 1200,
            condition: "Good", category: "Home", sellerDisplayName: "Same display name",
            pickupArea: "Campus", photoURLs: []))
    }

    @Test func anonymousAndForgedIdentityAreRejected() async throws {
        try await withApp(configure: { app in configureRoutes(app) }) { app in
            for path in ["api/v1/me/listings", "api/v1/me/listings/desk-lamp", "api/v1/me/listings?userId=sam&ownerID=sam"] {
                try await app.testing().test(.GET, path, beforeRequest: { req in
                    req.headers.add(name: "X-User-ID", value: "sam")
                    req.headers.bearerAuthorization = .init(token: "sam")
                }, afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
            }
        }
    }

    @Test func ownerListAndDetails() async throws {
        let catalog = fixture()
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice"))
            configureRoutes(app, catalog: catalog)
        }) { app in
            try await app.testing().test(.GET, "api/v1/me/listings?ownerID=bob") { res async throws in
                #expect(res.status == .ok)
                let items = try res.content.decode([OwnedListing].self)
                #expect(items.map { $0.listing.id } == ["active", "sold", "reserved"])
                #expect(items.map { $0.status } == [.active, .sold, .reserved])
            }
            for id in ["active", "sold", "reserved"] {
                try await app.testing().test(.GET, "api/v1/me/listings/\(id)") { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(OwnedListing.self).listing.id == id)
                }
            }
            for id in ["other", "deleted", "missing"] {
                try await app.testing().test(.GET, "api/v1/me/listings/\(id)") { res async in
                    #expect(res.status == .notFound)
                }
            }
        }
    }

    @Test func newUserHasEmptyList() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "new-user"))
            configureRoutes(app)
        }) { app in
            try await app.testing().test(.GET, "api/v1/me/listings") { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode([OwnedListing].self).isEmpty)
            }
        }
    }

    @Test func searchAndClearOnlyReturnActiveItems() async throws {
        let catalog = fixture()
        try await withApp(configure: { app in configureRoutes(app, catalog: catalog) }) { app in
            for suffix in ["", "?q=", "?q=%20%0A%20", "?q=dEsK", "?q=%20dOrM%20"] {
                try await app.testing().test(.GET, "api/v1/listings\(suffix)") { res async throws in
                    #expect(res.status == .ok)
                    let items = try res.content.decode([Listing].self)
                    #expect(items.map { $0.id } == ["active", "other"])
                }
            }
            try await app.testing().test(.GET, "api/v1/listings?q=no-match") { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode([Listing].self).isEmpty)
            }
            for id in ["sold", "reserved", "deleted", "missing"] {
                try await app.testing().test(.GET, "api/v1/listings/\(id)") { res async in
                    #expect(res.status == .notFound)
                }
            }
        }
    }

    @Test func emptyCatalogServesAnEmptyFeed() async throws {
        try await withApp(configure: { app in configureRoutes(app, catalog: Catalog(rows: [])) }) { app in
            try await app.testing().test(.GET, "api/v1/listings") { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode([Listing].self).isEmpty)
            }
        }
    }

    @Test func feedReflectsNewRowsWithoutARestart() async throws {
        let catalog = Catalog(rows: [])
        try await withApp(configure: { app in configureRoutes(app, catalog: catalog) }) { app in
            for (id, title) in [("first", "Desk lamp"), ("second", "Bike lock")] {
                catalog.add(Listing(id: id, title: title, description: "For a DORM room", priceCents: 1200,
                                    condition: "Good", category: "Home", sellerDisplayName: "Alice",
                                    pickupArea: "Campus", photoURLs: ["/photos/\(id).jpg"]),
                            ownerID: "alice")
            }
            try await app.testing().test(.GET, "api/v1/listings") { res async throws in
                let items = try res.content.decode([Listing].self)
                #expect(items.map { $0.id } == ["second", "first"]) // newest first
                #expect(items.first?.photoURLs.first == "/photos/second.jpg") // primary photo first
            }
            try await app.testing().test(.GET, "api/v1/listings/second") { res async in
                #expect(res.status == .ok) // details route sees the same store
            }
        }
    }
}
