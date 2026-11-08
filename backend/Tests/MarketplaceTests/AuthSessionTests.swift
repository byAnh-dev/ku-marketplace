@testable import Marketplace
import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import VaporTesting

/// The seam the whole sprint depends on: a stored session token must turn into
/// `MarketplaceUser` for the guarded routes, and nothing weaker may.
@Suite struct AuthSessionTests {
    private let token = String(repeating: "t", count: 64)

    private struct Body: Content {
        var title = "Gooseneck desk lamp"
        var description = "Warm light with a clamp base."
        var priceCents = 1200
        var category = "Dorm essentials"
        var condition = "Good"
    }

    /// A file-backed scratch database; an in-memory one can hand each pooled
    /// connection its own empty schema.
    private func configure(_ app: Application, catalog: Catalog) async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ku-auth-\(UUID().uuidString).sqlite").path
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
        app.migrations.add(CreateAccounts())
        try await app.autoMigrate()
        app.middleware.use(SessionAuthenticator())
        configureRoutes(app, catalog: catalog)
    }

    private func seedSession(_ app: Application, verified: Bool = true,
                             expiresIn: TimeInterval = 600, used: Bool = false) async throws -> Account {
        let account = Account(displayName: "Alice", email: "alice@ku.edu", passwordHash: "x")
        account.verified = verified
        try await account.create(on: app.db)
        let credential = AuthCredential(userID: try account.requireID(), tokenHash: digest(token),
                                        kind: "session", expiresAt: Date().addingTimeInterval(expiresIn))
        credential.used = used
        try await credential.create(on: app.db)
        return account
    }

    private func publish(_ app: Application, token: String) async throws -> TestingHTTPResponse {
        try await app.testing().sendRequest(.POST, "api/v1/listings",
                                            headers: ["Authorization": "Bearer \(token)"],
                                            beforeRequest: { req in try req.content.encode(Body()) })
    }

    @Test func verifiedSessionPublishesAndOwnsTheListing() async throws {
        let catalog = Catalog(rows: [])
        try await withApp(configure: { app in try await configure(app, catalog: catalog) }) { app in
            _ = try await seedSession(app)

            let response = try await publish(app, token: token)
            #expect(response.status == .created)
            let listing = try response.content.decode(Listing.self)
            #expect(listing.sellerDisplayName == "Alice") // from the account row, not the body

            let mine = try await app.testing().sendRequest(.GET, "api/v1/me/listings",
                                                           headers: ["Authorization": "Bearer \(token)"])
            #expect(try mine.content.decode([OwnedListing].self).map { $0.listing.id } == [listing.id])
        }
    }

    @Test func rejectedSessionsNeverAuthenticate() async throws {
        // Unknown token: no credential row at all.
        try await withApp(configure: { app in try await configure(app, catalog: Catalog(rows: [])) }) { app in
            let response = try await publish(app, token: token)
            #expect(response.status == .unauthorized)
        }
        // Expired, revoked, and unverified sessions are each refused.
        for variant in ["expired", "used", "unverified"] {
            try await withApp(configure: { app in try await configure(app, catalog: Catalog(rows: [])) }) { app in
                _ = try await seedSession(app,
                                          verified: variant != "unverified",
                                          expiresIn: variant == "expired" ? -60 : 600,
                                          used: variant == "used")
                let response = try await publish(app, token: token)
                #expect(response.status == .unauthorized, "\(variant) session authenticated")
            }
        }
    }
}
