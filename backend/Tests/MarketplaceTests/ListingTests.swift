@testable import Marketplace
import Fluent
import Testing
import VaporTesting

// Only linked into the test target. No fake login is exposed by the server.
private struct TestUser: AsyncMiddleware {
    let id: String
    var displayName = "Test Seller"
    var verified = true
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.auth.login(AuthenticatedUser(id: id, displayName: displayName, verified: verified))
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
    private func fixture() -> [Catalog.Row] {
        [
            row("active", owner: "alice", status: .active),
            row("sold", owner: "alice", status: .sold),
            row("reserved", owner: "alice", status: .reserved),
            row("deleted", owner: "alice", status: .deleted),
            row("other", owner: "bob", status: .active)
        ]
    }

    private func row(_ id: String, owner: String, status: Catalog.Status) -> Catalog.Row {
        Catalog.Row(ownerID: owner, status: status, listing: Listing(
            id: id, title: "Desk lamp", description: "For a DORM room", priceCents: 1200,
            condition: "Good", category: "Home", sellerDisplayName: "Same display name",
            pickupArea: "Campus", photoURLs: []))
    }

    @Test func anonymousAndForgedIdentityAreRejected() async throws {
        try await withApp(configure: { app in _ = try await configureApplication(app) }) { app in
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
        let rows = fixture()
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice"))
            _ = try await configureApplication(app, seedListings: rows)
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

    @Test func ownedLookupTargetsOneListingWithoutChangingVisibilityRules() async throws {
        let rows = fixture()
        try await withApp(configure: { app in _ = try await configureApplication(app, seedListings: rows) }) { app in
            let catalog = Catalog(database: app.db)
            let active = try await catalog.owned(listingID: "active", by: "alice")
            let sold = try await catalog.owned(listingID: "sold", by: "alice")
            let deleted = try await catalog.owned(listingID: "deleted", by: "alice")
            let foreign = try await catalog.owned(listingID: "active", by: "bob")
            let missing = try await catalog.owned(listingID: "missing", by: "alice")
            #expect(active?.status == .active)
            #expect(sold?.status == .sold)
            #expect(deleted == nil)
            #expect(foreign == nil)
            #expect(missing == nil)
        }
    }

    @Test func newUserHasEmptyList() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "new-user"))
            _ = try await configureApplication(app)
        }) { app in
            try await app.testing().test(.GET, "api/v1/me/listings") { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode([OwnedListing].self).isEmpty)
            }
        }
    }

    @Test func searchAndClearOnlyReturnActiveItems() async throws {
        let rows = fixture()
        try await withApp(configure: { app in _ = try await configureApplication(app, seedListings: rows) }) { app in
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

    @Test func searchFiltersAndPaginatesAtTheDatabaseBoundary() async throws {
        let sold = row("sold-lamp", owner: "alice", status: .sold)
        try await withApp(configure: { app in _ = try await configureApplication(app, seedListings: [sold]) }) { app in
            let catalog = Catalog(database: app.db)
            for id in ["old", "middle", "new"] {
                let active = row(id, owner: "alice", status: .active)
                try await catalog.add(active.listing, ownerID: active.ownerID)
            }
            try await app.testing().test(.GET, "api/v1/listings?q=lamp&page=1&per=2") { response async throws in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "X-Page") == "1")
                #expect(response.headers.first(name: "X-Page-Size") == "2")
                #expect(response.headers.first(name: "X-Has-More") == "true")
                #expect(try response.content.decode([Listing].self).map(\.id) == ["new", "middle"])
            }
            try await app.testing().test(.GET, "api/v1/listings?q=lamp&page=2&per=2") { response async throws in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "X-Has-More") == "false")
                #expect(try response.content.decode([Listing].self).map(\.id) == ["old"])
            }
        }
    }

    @Test func emptyCatalogServesAnEmptyFeed() async throws {
        try await withApp(configure: { app in _ = try await configureApplication(app, seedListings: []) }) { app in
            try await app.testing().test(.GET, "api/v1/listings") { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode([Listing].self).isEmpty)
            }
        }
    }

    @Test func feedReflectsNewRowsWithoutARestart() async throws {
        try await withApp(configure: { app in _ = try await configureApplication(app, seedListings: []) }) { app in
            let catalog = Catalog(database: app.db)
            for (id, title) in [("first", "Desk lamp"), ("second", "Bike lock")] {
                try await catalog.add(Listing(id: id, title: title, description: "For a DORM room", priceCents: 1200,
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

    @Test func publishRejectsAnonymousAndUnverifiedSellers() async throws {
        try await withApp(configure: { app in _ = try await configureApplication(app, seedListings: []) }) { app in
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: "sam")
                req.headers.add(name: "X-User-ID", value: "alice")
                try req.content.encode(PublishBody())
            })
            #expect(response.status == .unauthorized)
            #expect(try await Catalog(database: app.db).search("").isEmpty)
        }
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice", verified: false))
            _ = try await configureApplication(app, seedListings: [])
        }) { app in
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                try req.content.encode(PublishBody())
            })
            #expect(response.status == .forbidden)
            #expect(try await Catalog(database: app.db).search("").isEmpty)
        }
    }

    @Test func publishReportsEveryInvalidField() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice"))
            _ = try await configureApplication(app, seedListings: [])
        }) { app in
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                try req.content.encode(PublishBody(
                    title: "   ", description: "", priceCents: 0, category: "", condition: "Mint"))
            })
            #expect(response.status == .unprocessableEntity)
            let errors = try response.content.decode(FieldErrorBody.self)
            #expect(Set(errors.fieldErrors.keys) == ["title", "description", "priceCents", "category", "condition"])

            let tooLong = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                try req.content.encode(PublishBody(title: String(repeating: "a", count: 121)))
            })
            #expect(tooLong.status == .unprocessableEntity)
            let longErrors = try tooLong.content.decode(FieldErrorBody.self)
            #expect(Set(longErrors.fieldErrors.keys) == ["title"])
        }
    }

    @Test func publishAssociatesTheSessionSellerAndAppearsEverywhere() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice", displayName: "Alice"))
            _ = try await configureApplication(app, seedListings: [])
        }) { app in
            // Forged seller, status, and id: all must be ignored.
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                try req.content.encode(PublishBody(
                    title: "  Desk lamp  ", sellerDisplayName: "Mallory", ownerID: "bob",
                    id: "forged", status: "sold"))
            })
            #expect(response.status == .created)
            let listing = try response.content.decode(Listing.self)
            #expect(response.headers.first(name: .location) == "/api/v1/listings/\(listing.id)")
            #expect(listing.title == "Desk lamp")            // trimmed
            #expect(listing.sellerDisplayName == "Alice")     // session, not the body
            #expect(listing.pickupArea == "Campus")           // documented default
            #expect(listing.id != "forged")                   // server-minted id
            #expect(listing.photoURLs.isEmpty)                // photos belong to the upload feature

            let feed = try await app.testing().sendRequest(.GET, "api/v1/listings")
            #expect(try feed.content.decode([Listing].self).map { $0.id } == [listing.id])
            let detail = try await app.testing().sendRequest(.GET, "api/v1/listings/\(listing.id)")
            #expect(detail.status == .ok)
            let owned = try await app.testing().sendRequest(.GET, "api/v1/me/listings")
            let entries = try owned.content.decode([OwnedListing].self)
            #expect(entries.map { $0.listing.id } == [listing.id])
            #expect(entries.first?.status == .active)          // forged "sold" ignored
        }
    }

    @Test func editsAreAtomicVersionedAndPreserveIdentity() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice"))
            _ = try await configureApplication(app, seedListings: fixture())
        }) { app in
            let before = try #require(try await ListingRecord.query(on: app.db).filter(\.$listingID == "active").first())
            let originalDate = before.createdAt
            let originalSequence = before.id
            let invalid = try await app.testing().sendRequest(.PATCH, "api/v1/listings/active", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: "initial")
                try req.content.encode(PublishBody(title: "Changed", description: "", priceCents: 0, category: "", condition: "Mint"))
            })
            #expect(invalid.status == .unprocessableEntity)
            #expect(try invalid.content.decode(FieldErrorBody.self).fieldErrors.count == 4)
            #expect(try await Catalog(database: app.db).active("active")?.title == "Desk lamp")
            let missingVersion = try await app.testing().sendRequest(.PATCH, "api/v1/listings/active", beforeRequest: { req in
                try req.content.encode(PublishBody())
            })
            #expect(missingVersion.status == .preconditionRequired)
            let edited = try await app.testing().sendRequest(.PATCH, "api/v1/listings/active", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: "initial")
                try req.content.encode(PublishBody(title: "  Updated desk  ", description: "Updated description", priceCents: 1999,
                    category: "Furniture", condition: "fair", pickupArea: "Forged pickup", sellerDisplayName: "Mallory",
                    ownerID: "bob", id: "forged", status: "sold"))
            })
            #expect(edited.status == .ok)
            let owned = try edited.content.decode(OwnedListing.self)
            #expect(owned.revision != "initial")
            #expect(owned.listing.title == "Updated desk")
            #expect(owned.listing.description == "Updated description")
            #expect(owned.listing.priceCents == 1999)
            #expect(owned.listing.condition == "Fair")
            #expect(owned.listing.category == "Furniture")
            #expect(owned.listing.id == "active")
            #expect(owned.listing.pickupArea == "Campus")
            #expect(owned.listing.sellerDisplayName == "Same display name")
            #expect(owned.status == .active)
            let after = try #require(try await ListingRecord.query(on: app.db).filter(\.$listingID == "active").first())
            #expect(after.createdAt == originalDate)
            #expect(after.id == originalSequence)
            #expect(after.ownerID == "alice")
            let stale = try await app.testing().sendRequest(.PATCH, "api/v1/listings/active", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: "initial")
                try req.content.encode(PublishBody(title: "Stale overwrite"))
            })
            #expect(stale.status == .conflict)
            #expect(try await Catalog(database: app.db).active("active")?.title == "Updated desk")
            let reload = try await app.testing().sendRequest(.GET, "api/v1/me/listings/active")
            #expect(try reload.content.decode(OwnedListing.self).revision == owned.revision)
        }
    }

    @Test func editsRejectOtherOwnersAndInactiveItems() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice"))
            _ = try await configureApplication(app, seedListings: fixture())
        }) { app in
            for (id, status) in [("other", HTTPStatus.notFound), ("missing", .notFound), ("deleted", .notFound), ("sold", .conflict), ("reserved", .conflict)] {
                let response = try await app.testing().sendRequest(.PATCH, "api/v1/listings/\(id)", beforeRequest: { req in
                    req.headers.add(name: .ifMatch, value: "initial")
                    try req.content.encode(PublishBody(title: "Unauthorized change"))
                })
                #expect(response.status == status)
            }
            let records = try await ListingRecord.query(on: app.db).all()
            #expect(records.allSatisfy { $0.title == "Desk lamp" && $0.revision == nil })
        }
    }

    @Test func simultaneousEditsAcceptOnlyOneAndPreservePhotos() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: fixture())
        }) { app in
            let catalog = Catalog(database: app.db)
            _ = try await catalog.replacePhotos(["/uploads/keep.jpg"], listingID: "active", ownerID: "alice")
            let draft = try ListingDraft(CreateListingBody(title: "New title", description: "New description", priceCents: 2000,
                category: "Home", condition: "Good", pickupArea: nil))
            let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do { _ = try await catalog.edit(draft, listingID: "active", ownerID: "alice", revision: "initial"); return true }
                        catch let failure as Abort { #expect(failure.status == .conflict); return false }
                        catch { Issue.record("Unexpected edit failure: \(error)"); return false }
                    }
                }
                var count = 0
                for await success in group { if success { count += 1 } }
                return count
            }
            #expect(successes == 1)
            #expect(try await catalog.active("active")?.photoURLs == ["/uploads/keep.jpg"])
        }
    }


    @Test func soldAndDeletedListingsLeaveTheMarketplaceAndRejectStaleEdits() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice"))
            _ = try await configureApplication(app, seedListings: fixture())
        }) { app in
            let before = try #require(try await ListingRecord.query(on: app.db).filter(\.$listingID == "active").first())
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings/active/sold", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: "initial")
            })
            #expect(response.status == .ok)
            let sold = try response.content.decode(OwnedListing.self)
            #expect(sold.status == .sold)
            #expect(sold.revision != "initial")
            #expect(try await Catalog(database: app.db).active("active") == nil)
            #expect(try await Catalog(database: app.db).search("DORM").map(\.id) == ["other"])
            let after = try #require(try await ListingRecord.query(on: app.db).filter(\.$listingID == "active").first())
            #expect(after.createdAt == before.createdAt)
            #expect(after.ownerID == before.ownerID)
            let retry = try await app.testing().sendRequest(.POST, "api/v1/listings/active/sold", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: "initial")
            })
            #expect(retry.status == .ok)
            let staleDelete = try await app.testing().sendRequest(.DELETE, "api/v1/listings/active", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: "initial")
            })
            #expect(staleDelete.status == .conflict)
            let deleted = try await app.testing().sendRequest(.DELETE, "api/v1/listings/active", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: sold.revision)
            })
            #expect(deleted.status == .ok)
            #expect(try deleted.content.decode(OwnedListing.self).status == .deleted)
            #expect(try await Catalog(database: app.db).owned(by: "alice").contains { $0.listing.id == "active" } == false)
            for path in ["api/v1/listings/active", "api/v1/me/listings/active"] {
                #expect(try await app.testing().sendRequest(.GET, path).status == .notFound)
            }
            let edit = try await app.testing().sendRequest(.PATCH, "api/v1/listings/active", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: sold.revision)
                try req.content.encode(PublishBody())
            })
            #expect(edit.status == .notFound)
            let deleteRetry = try await app.testing().sendRequest(.DELETE, "api/v1/listings/active", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: sold.revision)
            })
            #expect(deleteRetry.status == .ok)
        }
    }

    @Test func statusActionsRequireOwnershipAndCurrentRevision() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice"))
            _ = try await configureApplication(app, seedListings: fixture())
        }) { app in
            for (method, suffix) in [(HTTPMethod.POST, "/sold"), (.DELETE, "")] {
                for id in ["other", "missing"] {
                    let response = try await app.testing().sendRequest(method, "api/v1/listings/\(id)\(suffix)", beforeRequest: { req in
                        req.headers.add(name: .ifMatch, value: "initial")
                    })
                    #expect(response.status == .notFound)
                }
                let missingVersion = try await app.testing().sendRequest(method, "api/v1/listings/active\(suffix)")
                #expect(missingVersion.status == .preconditionRequired)
                let stale = try await app.testing().sendRequest(method, "api/v1/listings/active\(suffix)", beforeRequest: { req in
                    req.headers.add(name: .ifMatch, value: "stale")
                })
                #expect(stale.status == .conflict)
            }
            #expect(try await Catalog(database: app.db).active("active") != nil)
            let reserved = try await app.testing().sendRequest(.POST, "api/v1/listings/reserved/sold", beforeRequest: { req in
                req.headers.add(name: .ifMatch, value: "initial")
            })
            #expect(reserved.status == .ok)
        }
    }

}
