@testable import Marketplace
import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import VaporTesting

// Expectations come from the existing HTTP contract and the restart requirement.
// Each withApp closes its database before the next application opens the same file.
@Suite struct PersistenceTests {
    private let password = "Persistence-test-password-2026"
    private static let png = Array(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAOSURBVBhXY/jPwPAfhAER9wP9lTZx2QAAAABJRU5ErkJggg==")!)
    private static let jpeg = Array(Data(base64Encoded: "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAACAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDu6KKK/h8/ziP/2Q==")!)

    private func directory() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("persistence-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path + "/"
    }

    private func login(_ app: Application, email: String) async throws -> LoginResponse {
        let response = try await app.testing().sendRequest(.POST, "api/v1/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: email, password: password))
        })
        try #require(response.status == .ok)
        return try response.content.decode(LoginResponse.self)
    }

    private func account(_ app: Application, email: String) async throws -> LoginResponse {
        let account = Account(displayName: "Persistent seller", email: email,
                              passwordHash: try await app.password.async.hash(password))
        account.verified = true
        try await account.create(on: app.db)
        return try await login(app, email: email)
    }

    private func get(_ app: Application, _ path: String, token: String? = nil) async throws -> TestingHTTPResponse {
        try await app.testing().sendRequest(.GET, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
        })
    }

    private func publish(_ app: Application, title: String, description: String, token: String) async throws -> Listing {
        let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateListingBody(title: title, description: description, priceCents: 2750,
                                                    category: "Furniture", condition: "Like new", pickupArea: "West campus"))
        })
        try #require(response.status == .created)
        let listing = try response.content.decode(Listing.self)
        #expect(response.headers.first(name: .location) == "/api/v1/listings/\(listing.id)")
        return listing
    }

    private func upload(_ app: Application, id: String, files: [[UInt8]], token: String) async throws -> TestingHTTPResponse {
        let boundary = "persistence-test-\(UUID().uuidString)"
        var body = ByteBuffer()
        for (index, bytes) in files.enumerated() {
            body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"photos[]\"; filename=\"image-\(index).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            body.writeBytes(bytes)
            body.writeString("\r\n")
        }
        body.writeString("--\(boundary)--\r\n")
        return try await app.testing().sendRequest(.POST, "api/v1/listings/\(id)/photos", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
            req.body = body
        })
    }

    private func images(_ app: Application, _ urls: [String]) async throws -> [[UInt8]] {
        var bytes: [[UInt8]] = []
        for url in urls {
            let response = try await get(app, String(url.dropFirst()))
            try #require(response.status == .ok)
            bytes.append(Array(response.body.readableBytesView))
        }
        return bytes
    }

    private func expectSameListing(_ actual: Listing, _ expected: Listing) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(actual) == encoder.encode(expected))
    }

    @Test func listingsOwnershipAndOrderedPhotosSurviveRepeatedRestarts() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let database = directory + "marketplace.sqlite"
        var owner: LoginResponse?
        var stranger: LoginResponse?
        var older: Listing?
        var newer: Listing?
        var originalBytes: [[UInt8]] = []
        try await withApp(configure: { app in
            app.directory = DirectoryConfiguration(workingDirectory: directory)
            try await configureApplication(app, databasePath: database, seedListings: [])
        }) { app in
            let seller = try await account(app, email: "persistent-owner@ku.edu")
            owner = seller
            stranger = try await account(app, email: "persistent-other@ku.edu")
            let first = try await publish(app, title: "Persistent desk", description: "Desk for a DORM room", token: seller.token)
            newer = try await publish(app, title: "Persistent chair", description: "Chair for studying", token: seller.token)
            let uploaded = try await upload(app, id: first.id, files: [Self.png, Self.jpeg], token: seller.token)
            try #require(uploaded.status == .ok)
            let listing = try uploaded.content.decode(Listing.self)
            older = listing
            try #require(listing.photoURLs.count == 2)
            originalBytes = try await images(app, listing.photoURLs)
            #expect(originalBytes[0].starts(with: [0x89, 0x50, 0x4e, 0x47]))
            #expect(originalBytes[1].starts(with: [0xff, 0xd8, 0xff]))
        }

        let seller = try #require(owner)
        let other = try #require(stranger)
        let first = try #require(older)
        let second = try #require(newer)
        var replaced: Listing?
        var replacementBytes: [[UInt8]] = []
        // Default samples must not appear in a database already migrated with an empty seed.
        try await withApp(configure: { app in
            app.directory = DirectoryConfiguration(workingDirectory: directory)
            try await configureApplication(app, databasePath: database)
        }) { app in
            let feed = try await get(app, "api/v1/listings")
            let listings = try feed.content.decode([Listing].self)
            try #require(listings.count == 2)
            try expectSameListing(listings[0], second)
            try expectSameListing(listings[1], first)
            let searched = try await get(app, "api/v1/listings?q=%20dOrM%20")
            #expect(try searched.content.decode([Listing].self).map(\.id) == [first.id])
            let profile = try await get(app, "api/v1/auth/me", token: seller.token)
            #expect(profile.status == .ok)
            #expect(try profile.content.decode(PublicUser.self).id == seller.user.id)
            let mine = try await get(app, "api/v1/me/listings", token: seller.token)
            let owned = try mine.content.decode([OwnedListing].self)
            #expect(owned.map { $0.listing.id } == [second.id, first.id])
            #expect(owned.map(\.status) == [.active, .active])
            let ownedDetail = try await get(app, "api/v1/me/listings/\(first.id)", token: seller.token)
            try expectSameListing(try ownedDetail.content.decode(OwnedListing.self).listing, first)
            let others = try await get(app, "api/v1/me/listings", token: other.token)
            #expect(try others.content.decode([OwnedListing].self).isEmpty)
            #expect(try await get(app, "api/v1/me/listings/\(first.id)", token: other.token).status == .notFound)
            #expect(try await upload(app, id: first.id, files: [Self.jpeg], token: other.token).status == .notFound)
            #expect(try await images(app, first.photoURLs) == originalBytes)
            let uploaded = try await upload(app, id: first.id, files: [Self.jpeg], token: seller.token)
            try #require(uploaded.status == .ok)
            let updated = try uploaded.content.decode(Listing.self)
            replaced = updated
            #expect(updated.photoURLs.count == 1)
            #expect(updated.photoURLs != first.photoURLs)
            replacementBytes = try await images(app, updated.photoURLs)
        }

        let replacement = try #require(replaced)
        try await withApp(configure: { app in
            app.directory = DirectoryConfiguration(workingDirectory: directory)
            try await configureApplication(app, databasePath: database)
        }) { app in
            let detail = try await get(app, "api/v1/listings/\(first.id)")
            try expectSameListing(try detail.content.decode(Listing.self), replacement)
            let feed = try await get(app, "api/v1/listings")
            #expect(try feed.content.decode([Listing].self).map(\.id) == [second.id, first.id])
            #expect(try await images(app, replacement.photoURLs) == replacementBytes)
            for old in first.photoURLs {
                #expect(try await get(app, String(old.dropFirst())).status == .notFound)
            }
        }
    }

    @Test func accountOnlyDatabaseUpgradesWithoutResettingUsersSessionsOrSeedData() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let database = directory + "marketplace.sqlite"
        var original: LoginResponse?
        // Construct the pre-change schema using its unchanged account migration.
        try await withApp(configure: { app in
            app.databases.use(.sqlite(.file(database)), as: .sqlite)
            app.migrations.add(CreateMarketplaceUsers())
            try await app.autoMigrate()
            registerAuthRoutes(app)
        }) { app in
            original = try await self.account(app, email: "upgrade@ku.edu")
        }
        let account = try #require(original)
        var created: Listing?
        try await withApp(configure: { app in
            try await configureApplication(app, databasePath: database)
        }) { app in
            let profile = try await get(app, "api/v1/auth/me", token: account.token)
            #expect(profile.status == .ok)
            #expect(try profile.content.decode(PublicUser.self).id == account.user.id)
            #expect(try await login(app, email: account.user.email).user.id == account.user.id)
            #expect(try await Account.query(on: app.db).count() == 1)
            let feed = try await get(app, "api/v1/listings")
            #expect(try feed.content.decode([Listing].self).map(\.id) == ["desk-lamp", "calculus"])
            #expect(try await get(app, "api/v1/listings/bike").status == .notFound)
            created = try await publish(app, title: "After upgrade", description: "Must survive another migration check", token: account.token)
        }
        let listing = try #require(created)
        try await withApp(configure: { app in
            try await configureApplication(app, databasePath: database)
        }) { app in
            let feed = try await get(app, "api/v1/listings")
            #expect(try feed.content.decode([Listing].self).map(\.id) == [listing.id, "desk-lamp", "calculus"])
            let mine = try await get(app, "api/v1/me/listings", token: account.token)
            let entries = try mine.content.decode([OwnedListing].self)
            try #require(entries.count == 1)
            try expectSameListing(entries[0].listing, listing)
            #expect(try await Account.query(on: app.db).count() == 1)
        }
    }

    @Test func startupRecoversWhenListingMigrationFinishedBeforeItsHistoryWasRecorded() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let database = directory + "marketplace.sqlite"
        var owner: LoginResponse?
        var created: Listing?
        try await withApp(configure: { app in
            app.databases.use(.sqlite(.file(database)), as: .sqlite)
            app.migrations.add(CreateMarketplaceUsers())
            try await app.autoMigrate()
            // Simulate a stop after prepare commits but before Fluent records completion.
            // Deliberately do not register this migration with the migrator.
            try await CreateListings(seedRows: Catalog.samples).prepare(on: app.db)
            registerAuthRoutes(app)
            configureRoutes(app, catalog: Catalog(database: app.db))
        }) { app in
            let account = try await self.account(app, email: "migration-recovery@ku.edu")
            owner = account
            created = try await publish(app, title: "Keep this listing", description: "Already stored before migration recovery", token: account.token)
        }
        let account = try #require(owner)
        let listing = try #require(created)
        try await withApp(configure: { app in
            try await configureApplication(app, databasePath: database)
        }) { app in
            let feed = try await get(app, "api/v1/listings")
            #expect(try feed.content.decode([Listing].self).map(\.id) == [listing.id, "desk-lamp", "calculus"])
            let detail = try await get(app, "api/v1/listings/\(listing.id)")
            try expectSameListing(try detail.content.decode(Listing.self), listing)
            let mine = try await get(app, "api/v1/me/listings", token: account.token)
            #expect(try mine.content.decode([OwnedListing].self).map { $0.listing.id } == [listing.id])
        }
    }
}
