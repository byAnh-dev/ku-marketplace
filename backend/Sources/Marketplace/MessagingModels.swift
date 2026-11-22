import Fluent
import FluentSQL
import Foundation

final class ConversationRecord: Model, @unchecked Sendable {
    static let schema = "conversations"

    @ID(key: .id) var id: UUID?
    @Field(key: "listing_id") var listingID: String
    @Field(key: "buyer_id") var buyerID: UUID
    @Field(key: "seller_id") var sellerID: UUID
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(listingID: String, buyerID: UUID, sellerID: UUID, createdAt: Date = Date()) {
        self.id = UUID()
        self.listingID = listingID
        self.buyerID = buyerID
        self.sellerID = sellerID
        self.createdAt = createdAt
    }
}

final class MessageRecord: Model, @unchecked Sendable {
    static let schema = "messages"

    @ID(custom: "sequence", generatedBy: .database) var id: Int?
    @Field(key: "conversation_id") var conversationID: UUID
    @Field(key: "sender_id") var senderID: UUID
    @Field(key: "recipient_id") var recipientID: UUID
    @Field(key: "client_message_id") var clientMessageID: UUID
    @Field(key: "body") var body: String
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "read_at") var readAt: Date?

    init() {}

    init(conversationID: UUID, senderID: UUID, recipientID: UUID, clientMessageID: UUID,
         body: String, createdAt: Date = Date()) {
        self.conversationID = conversationID
        self.senderID = senderID
        self.recipientID = recipientID
        self.clientMessageID = clientMessageID
        self.body = body
        self.createdAt = createdAt
        self.readAt = nil
    }
}

struct CreateMessaging: AsyncMigration {
    private struct RequiresSQLDatabase: Error {}

    func prepare(on db: any Database) async throws {
        try await db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw RequiresSQLDatabase() }
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS conversations (
                    id BLOB PRIMARY KEY NOT NULL,
                    listing_id TEXT NOT NULL REFERENCES listings(listing_id) ON DELETE RESTRICT,
                    buyer_id BLOB NOT NULL REFERENCES marketplace_users(id),
                    seller_id BLOB NOT NULL REFERENCES marketplace_users(id),
                    created_at REAL NOT NULL,
                    UNIQUE (listing_id, buyer_id, seller_id),
                    CHECK (buyer_id <> seller_id)
                )
                """).run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS messages (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id BLOB NOT NULL REFERENCES conversations(id),
                    sender_id BLOB NOT NULL REFERENCES marketplace_users(id),
                    recipient_id BLOB NOT NULL REFERENCES marketplace_users(id),
                    client_message_id BLOB NOT NULL,
                    body TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    read_at REAL,
                    UNIQUE (sender_id, client_message_id),
                    CHECK (sender_id <> recipient_id)
                )
                """).run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_conversations_buyer ON conversations (buyer_id)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_conversations_seller ON conversations (seller_id)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_messages_history ON messages (conversation_id, sequence)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_messages_sender_time ON messages (sender_id, created_at)").run()
        }
    }

    func revert(on db: any Database) async throws {
        try await db.transaction { db in
            try await db.schema(MessageRecord.schema).delete()
            try await db.schema(ConversationRecord.schema).delete()
        }
    }
}
