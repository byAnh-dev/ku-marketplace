import Fluent
import FluentSQL
import Vapor

private struct InboxConversation: Content {
    let id: UUID
    let listingId: String
    let listingTitle: String
    let listingStatus: String
    let peerDisplayName: String
    let latestMessage: String?
    let blockedByMe: Bool
    let canMessage: Bool
}

private struct HistoryQuery: Decodable {
    let before: Int?
    let after: Int?
    let limit: Int?
}

private struct HistoryPage: Content {
    let items: [MessageView]
    let hasOlder: Bool
    let hasNewer: Bool
    let blockedByMe: Bool
    let canMessage: Bool
    let listingStatus: String
}

private struct SequenceBounds: Decodable {
    let oldest: Int?
    let newest: Int?
}

func registerMessagingHistory(_ secured: RoutesBuilder) {
    secured.get("conversations") { req async throws -> [InboxConversation] in
        let actor = try messagingActor(req)
        guard let sql = req.db as? any SQLDatabase else { throw Abort(.internalServerError) }
        return try await sql.raw("""
            SELECT c.id, c.listing_id AS listingId, l.title AS listingTitle, l.status AS listingStatus,
                   peer.display_name AS peerDisplayName, latest.body AS latestMessage,
                   (outgoing.blocker_id IS NOT NULL) AS blockedByMe,
                   (l.status IN ('active', 'reserved') AND outgoing.blocker_id IS NULL
                       AND incoming.blocker_id IS NULL) AS canMessage
            FROM conversations c
            JOIN listings l ON l.listing_id = c.listing_id
            JOIN marketplace_users peer ON peer.id =
                CASE WHEN c.buyer_id = \(bind: actor) THEN c.seller_id ELSE c.buyer_id END
            LEFT JOIN user_blocks outgoing ON outgoing.blocker_id = \(bind: actor) AND outgoing.blocked_id = peer.id
            LEFT JOIN user_blocks incoming ON incoming.blocker_id = peer.id AND incoming.blocked_id = \(bind: actor)
            LEFT JOIN messages latest ON latest.sequence = (
                SELECT MAX(sequence) FROM messages WHERE conversation_id = c.id
            )
            WHERE c.buyer_id = \(bind: actor) OR c.seller_id = \(bind: actor)
            ORDER BY latest.sequence DESC, c.id
            """).all(decoding: InboxConversation.self)
    }

    secured.get("conversations", ":id", "messages") { req async throws -> HistoryPage in
        let (conversation, actor, peer) = try await messagingParticipants(req)
        let id = try conversation.requireID()
        let query = try req.query.decode(HistoryQuery.self)
        guard query.before == nil || query.after == nil,
              query.before.map({ $0 > 0 }) ?? true, query.after.map({ $0 >= 0 }) ?? true,
              (query.limit ?? 30) > 0 else {
            throw Abort(.badRequest, reason: "Use one valid message cursor and a positive page size.")
        }
        let limit = min(query.limit ?? 30, 50)
        return try await req.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            // Keep the message page, cursor boundaries, listing status and blocks on one SQLite snapshot.
            let request = MessageRecord.query(on: db)
                .join(Account.self, on: \MessageRecord.$senderID == \Account.$id)
                .filter(\.$conversationID == id)
            if let before = query.before { request.filter(\.$id < before) }
            if let after = query.after { request.filter(\.$id > after) }
            var messages = try await request
                .sort(\.$id, query.after == nil ? .descending : .ascending)
                .range(0..<limit).all()
            if query.after == nil { messages.reverse() }
            let items = try messages.map {
                try MessageView($0, senderName: $0.joined(Account.self).displayName)
            }
            guard let bounds = try await sql.raw("""
                SELECT (SELECT MIN(sequence) FROM messages WHERE conversation_id = \(bind: id)) AS oldest,
                       (SELECT MAX(sequence) FROM messages WHERE conversation_id = \(bind: id)) AS newest
                """).first(decoding: SequenceBounds.self),
                  let listing = try await ListingRecord.query(on: db)
                    .filter(\.$listingID == conversation.listingID).first() else { throw Abort(.notFound) }
            let blocks = try await blockState(actor: actor, peer: peer, on: db)
            // An empty page beyond an endpoint can still have history in the opposite direction.
            let hasOlder = items.first.map { (bounds.oldest ?? $0.sequence) < $0.sequence }
                ?? (query.after != nil && bounds.oldest != nil)
            let hasNewer = items.last.map { (bounds.newest ?? $0.sequence) > $0.sequence }
                ?? (query.before != nil && bounds.newest != nil)
            return HistoryPage(items: items, hasOlder: hasOlder, hasNewer: hasNewer,
                blockedByMe: blocks.blockedByMe,
                canMessage: blocks.canMessage && ["active", "reserved"].contains(listing.status),
                listingStatus: listing.status)
        }
    }
}
