import Fluent
import FluentSQL
import Vapor

struct CreateUnreadIndex: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await unreadSQL(db).raw("""
            CREATE INDEX IF NOT EXISTS idx_messages_recipient_unread
            ON messages (recipient_id, conversation_id) WHERE read_at IS NULL
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await unreadSQL(db).raw("DROP INDEX IF EXISTS idx_messages_recipient_unread").run()
    }
}

private func unreadSQL(_ db: any Database) throws -> any SQLDatabase {
    guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    return sql
}

private struct UnreadThread: Content {
    let conversationId: UUID
    let unreadCount: Int
}

private struct UnreadSummary: Content {
    let total: Int
    let threads: [UnreadThread]
}

private struct DisplayedMessages: Content {
    let sequences: [Int]
}

func registerUnreadRoutes(_ secured: RoutesBuilder) {
    secured.get("me", "unread") { req async throws -> UnreadSummary in
        let actor = try messagingActor(req)
        let threads = try await unreadSQL(req.db).raw("""
            SELECT conversation_id AS "conversationId", COUNT(*) AS "unreadCount"
            FROM messages WHERE recipient_id = \(bind: actor) AND read_at IS NULL
            GROUP BY conversation_id ORDER BY conversation_id
            """).all(decoding: UnreadThread.self)
        return UnreadSummary(total: threads.reduce(0) { $0 + $1.unreadCount }, threads: threads)
    }

    secured.post("conversations", ":id", "read") { req async throws -> HTTPStatus in
        let (conversation, actor, _) = try await messagingParticipants(req)
        let conversationID = try conversation.requireID()
        let body = try req.content.decode(DisplayedMessages.self)
        guard (1...100).contains(body.sequences.count), body.sequences.allSatisfy({ $0 > 0 }) else {
            throw Abort(.unprocessableEntity, reason: "Send 1 to 100 positive message sequences.")
        }
        let sequences = Array(Set(body.sequences))
        try await req.db.transaction { db in
            // Write first so overlapping receipts acquire SQLite's writer lock before reading.
            // An invalid batch rolls back the update, including its otherwise valid members.
            func incoming() -> QueryBuilder<MessageRecord> {
                MessageRecord.query(on: db)
                    .filter(\.$conversationID == conversationID)
                    .filter(\.$recipientID == actor)
                    .filter(\.$id ~~ sequences)
            }
            try await incoming().filter(\.$readAt == nil).set(\.$readAt, to: Date()).update()
            guard try await incoming().count() == sequences.count else {
                throw Abort(.unprocessableEntity, reason: "Invalid displayed messages.")
            }
        }
        return .noContent
    }
}
