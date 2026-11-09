import Foundation
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

    @Test func publishRejectsAnonymousAndUnverifiedSellers() async throws {
        let catalog = Catalog(rows: [])
        try await withApp(configure: { app in configureRoutes(app, catalog: catalog) }) { app in
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: "sam")
                req.headers.add(name: "X-User-ID", value: "alice")
                try req.content.encode(PublishBody())
            })
            #expect(response.status == .unauthorized)
        }
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice", verified: false))
            configureRoutes(app, catalog: catalog)
        }) { app in
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                try req.content.encode(PublishBody())
            })
            #expect(response.status == .forbidden)
        }
        #expect(catalog.search("").isEmpty) // neither request stored a row
    }

    @Test func publishReportsEveryInvalidField() async throws {
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice"))
            configureRoutes(app, catalog: Catalog(rows: []))
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
        let catalog = Catalog(rows: [])
        try await withApp(configure: { app in
            app.middleware.use(TestUser(id: "alice", displayName: "Alice"))
            configureRoutes(app, catalog: catalog)
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

    // MARK: Photo upload

    private static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]

    /// A multipart body with one `photos[]` part per file, as the app sends it.
    private func photoForm(_ files: [[UInt8]]) -> (HTTPMediaType, ByteBuffer) {
        let boundary = "test-boundary"
        var buffer = ByteBuffer()
        for (index, bytes) in files.enumerated() {
            buffer.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"photos[]\"; filename=\"photo-\(index).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            buffer.writeBytes(bytes)
            buffer.writeString("\r\n")
        }
        buffer.writeString("--\(boundary)--\r\n")
        return (HTTPMediaType(type: "multipart", subType: "form-data", parameters: ["boundary": boundary]), buffer)
    }

    /// Uploads land in a throwaway working directory, never in the repo.
    private func scratchDirectory() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path + "/"
    }

    @Test func ownerUploadsOrderedPhotosThatDetailsServe() async throws {
        let catalog = fixture()
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try await withApp(configure: { app in
            app.directory = DirectoryConfiguration(workingDirectory: directory)
            app.middleware.use(TestUser(id: "alice"))
            configureRoutes(app, catalog: catalog)
        }) { app in
            let (type, body) = photoForm([Self.jpeg + [1], Self.jpeg + [2, 2]])
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings/active/photos", beforeRequest: { req in
                req.headers.contentType = type
                req.body = body
            })
            #expect(response.status == .ok)
            let urls = try response.content.decode(Listing.self).photoURLs
            #expect(urls.count == 2)
            #expect(urls.allSatisfy { $0.hasPrefix("/uploads/listings/active/") && $0.hasSuffix(".jpg") })
            #expect(urls.first?.hasPrefix("/uploads/listings/active/0-") == true) // first file is primary

            let detail = try await app.testing().sendRequest(.GET, "api/v1/listings/active")
            #expect(try detail.content.decode(Listing.self).photoURLs == urls)
            let primary = try await app.testing().sendRequest(.GET, String(urls[0].dropFirst()))
            #expect(primary.status == .ok)
            #expect(primary.body.readableBytes == Self.jpeg.count + 1)
        }
    }

    @Test func photoUploadRejectsStrangersAndBadFiles() async throws {
        let catalog = fixture()
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try await withApp(configure: { app in
            app.directory = DirectoryConfiguration(workingDirectory: directory)
            configureRoutes(app, catalog: catalog)
        }) { app in
            let (type, body) = photoForm([Self.jpeg])
            let response = try await app.testing().sendRequest(.POST, "api/v1/listings/active/photos", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: "alice")
                req.headers.contentType = type
                req.body = body
            })
            #expect(response.status == .unauthorized)
        }
        try await withApp(configure: { app in
            app.directory = DirectoryConfiguration(workingDirectory: directory)
            app.middleware.use(TestUser(id: "alice"))
            configureRoutes(app, catalog: catalog)
        }) { app in
            let html: [UInt8] = Array("<html>".utf8)
            let cases: [(id: String, files: [[UInt8]], status: HTTPStatus)] = [
                ("other", [Self.jpeg], .notFound),   // someone else's listing
                ("sold", [Self.jpeg], .notFound),    // not active
                ("missing", [Self.jpeg], .notFound),
                ("active", [html], .unprocessableEntity),
                ("active", Array(repeating: Self.jpeg, count: 6), .unprocessableEntity)
            ]
            for item in cases {
                let (type, body) = photoForm(item.files)
                let response = try await app.testing().sendRequest(.POST, "api/v1/listings/\(item.id)/photos", beforeRequest: { req in
                    req.headers.contentType = type
                    req.body = body
                })
                #expect(response.status == item.status, "\(item.id), \(item.files.count) file(s)")
                if item.status == .unprocessableEntity {
                    #expect(try response.content.decode(FieldErrorBody.self).fieldErrors.keys.contains("photos"))
                }
            }
        }
        #expect(catalog.active("active")?.photoURLs.isEmpty == true) // nothing was stored
        #expect(catalog.active("other")?.photoURLs.isEmpty == true)
    }
}
