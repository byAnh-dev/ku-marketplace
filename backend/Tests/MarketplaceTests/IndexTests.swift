@testable import Marketplace
import Fluent
import FluentSQL
import Foundation
import Testing
import VaporTesting

@Suite struct IndexTests {
    private struct IndexName: Decodable { let name: String }

    @Test func indexesAreAdditiveIdempotentAndQueriesStillReturnExpectedRows() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: Catalog.samples)
        }) { app in
            // A retry must be harmless, including the partial-migration recovery case.
            try await CreateMarketplaceIndexes().prepare(on: app.db)

            let sql = try #require(app.db as? any SQLDatabase)
            let names = try await sql.raw("""
                SELECT name FROM sqlite_master
                WHERE type = 'index' AND name IN (
                  'idx_listings_status_sequence',
                  'idx_listings_owner_status_sequence',
                  'idx_auth_credentials_user_kind_expires',
                  'idx_auth_credentials_token_kind_used'
                ) ORDER BY name
                """).all(decoding: IndexName.self).map(\.name)
            #expect(names == [
                "idx_auth_credentials_token_kind_used",
                "idx_auth_credentials_user_kind_expires",
                "idx_listings_owner_status_sequence",
                "idx_listings_status_sequence"
            ])

            let catalog = Catalog(database: app.db)
            #expect(try await catalog.search("").map(\.id) == ["desk-lamp", "calculus"])
            #expect(try await catalog.owned(by: "sam").map { $0.listing.id } == ["desk-lamp"])

            let account = Account(displayName: "Index test", email: "index-test@ku.edu", passwordHash: "hash")
            try await account.create(on: app.db)
            let userID = try account.requireID()
            let credential = AuthCredential(userID: userID, tokenHash: "index-token", kind: "verification",
                                            expiresAt: Date().addingTimeInterval(60))
            try await credential.create(on: app.db)
            #expect(try await AuthCredential.query(on: app.db).filter(\.$userID == userID)
                .filter(\.$kind ~~ VerificationTokens.kinds).sort(\.$expiresAt, .descending).first()?.tokenHash == "index-token")
        }
    }
}
