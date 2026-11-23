import Fluent
import FluentSQL

/// Query indexes for the persistent marketplace tables.
///
/// This is a separate additive migration so existing databases retain their
/// rows and migration history. IF NOT EXISTS also makes retrying safe if a
/// process stops after creating an index but before Fluent records the batch.
struct CreateMarketplaceIndexes: AsyncMigration {
    private static let statements = [
        "CREATE INDEX IF NOT EXISTS \"idx_listings_status_sequence\" ON \"listings\" (\"status\", \"sequence\" DESC)",
        "CREATE INDEX IF NOT EXISTS \"idx_listings_owner_status_sequence\" ON \"listings\" (\"owner_id\", \"status\", \"sequence\" DESC)",
        "CREATE INDEX IF NOT EXISTS \"idx_auth_credentials_user_kind_expires\" ON \"auth_credentials\" (\"user_id\", \"kind\", \"expires_at\" DESC)",
        "CREATE INDEX IF NOT EXISTS \"idx_auth_credentials_token_kind_used\" ON \"auth_credentials\" (\"token_hash\", \"kind\", \"used\")"
    ]

    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        for statement in Self.statements {
            try await sql.raw(SQLQueryString(statement)).run()
        }
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        for statement in [
            "DROP INDEX IF EXISTS \"idx_auth_credentials_token_kind_used\"",
            "DROP INDEX IF EXISTS \"idx_auth_credentials_user_kind_expires\"",
            "DROP INDEX IF EXISTS \"idx_listings_owner_status_sequence\"",
            "DROP INDEX IF EXISTS \"idx_listings_status_sequence\""
        ] {
            try await sql.raw(SQLQueryString(statement)).run()
        }
    }
}
