@testable import Marketplace
import Testing
import VaporTesting

// Only linked into the test target. No fake login is exposed by the server.
private struct TestUser: AsyncMiddleware {
    let id: String
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.auth.login(MarketplaceUser(id: id))
        return try await next.respond(to: request)
    }
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
}
