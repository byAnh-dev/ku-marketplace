import Fluent
import FluentSQL
import Vapor

struct BlockState: Content, Equatable {
    let blockedByMe: Bool
    let canMessage: Bool
}

private func blockSQL(_ db: any Database) throws -> any SQLDatabase {
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    return sql
}

struct CreateUserBlocks: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await blockSQL(db).raw("""
            CREATE TABLE IF NOT EXISTS user_blocks (
                blocker_id BLOB NOT NULL REFERENCES marketplace_users(id) ON DELETE CASCADE,
                blocked_id BLOB NOT NULL REFERENCES marketplace_users(id) ON DELETE CASCADE,
                created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (blocker_id, blocked_id),
                CHECK (blocker_id <> blocked_id)
            )
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await blockSQL(db).raw("DROP TABLE IF EXISTS user_blocks").run()
    }
}

func blockState(actor: UUID, peer: UUID, on db: any Database) async throws -> BlockState {
    let row = try await blockSQL(db).raw("""
        SELECT EXISTS(SELECT 1 FROM user_blocks WHERE blocker_id = \(bind: actor) AND blocked_id = \(bind: peer)) AS outgoing,
               EXISTS(SELECT 1 FROM user_blocks WHERE blocker_id = \(bind: peer) AND blocked_id = \(bind: actor)) AS incoming
        """).first()
    guard let row else { throw Abort(.internalServerError) }
    let outgoing = try row.decode(column: "outgoing", as: Int.self) != 0
    let incoming = try row.decode(column: "incoming", as: Int.self) != 0
    return BlockState(blockedByMe: outgoing, canMessage: !outgoing && !incoming)
}

func setUserBlock(_ blocked: Bool, actor: UUID, peer: UUID, on db: any Database) async throws -> BlockState {
    try await db.transaction { transaction in
        let sql = try blockSQL(transaction)
        // Write first so SQLite orders block changes with R9's write-first sends.
        if blocked {
            try await sql.raw("""
                INSERT INTO user_blocks (blocker_id, blocked_id) VALUES (\(bind: actor), \(bind: peer))
                ON CONFLICT(blocker_id, blocked_id) DO NOTHING
                """).run()
        } else {
            try await sql.raw("""
                DELETE FROM user_blocks WHERE blocker_id = \(bind: actor) AND blocked_id = \(bind: peer)
                """).run()
        }
        return try await blockState(actor: actor, peer: peer, on: transaction)
    }
}
