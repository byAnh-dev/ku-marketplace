
import Fluent
import FluentSQL
import Vapor

private struct SendInput: Content {
    let body: String
    let clientMessageId: UUID
}

private struct SentMessage: Content {
    let conversationId: UUID
    let message: MessageView
}

private enum Destination: Sendable {
    case listing(String)
    case conversation(UUID)
}

func registerMessageSends(_ secured: RoutesBuilder) {

    secured.post("listings", ":id", "conversations") {
        req async throws -> Response in

        guard let id = req.parameters.get("id") else {
            throw Abort(.notFound)
        }

        return try await send(
            req,
            to: .listing(id)
        )
    }

    secured.post("conversations", ":id", "messages") {
        req async throws -> Response in

        guard let id = req.parameters.get(
            "id",
            as: UUID.self
        ) else {
            throw Abort(.notFound)
        }

        return try await send(
            req,
            to: .conversation(id)
        )
    }
}

private func send(
    _ req: Request,
    to destination: Destination
) async throws -> Response {

    let actor = try messagingActor(req)

    let senderName = try req.auth.require(
        AuthenticatedUser.self
    ).displayName

    let input = try req.content.decode(SendInput.self)

    let (saved, created) = try await req.db.transaction {
        db -> (MessageRecord, Bool) in

        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError)
        }

        // Serialize message, block, status and quota checks.
        try await sql.raw(
            "UPDATE messages SET body = body WHERE 0"
        ).run()

        let listingID: String
        var conversation: ConversationRecord?

        switch destination {
        case .conversation(let id):
            let member = try await memberConversation(
                id,
                actor: actor,
                on: db
            )
            listingID = member.listingID
            conversation = member

        case .listing(let id):
            listingID = id
        }

        guard let listing = try await ListingRecord.query(on: db)
            .filter(\.$listingID == listingID)
            .first()
        else {
            throw Abort(
                .notFound,
                reason: "Listing unavailable."
            )
        }

        if case .listing = destination {
            guard let seller = UUID(
                uuidString: listing.ownerID
            ) else {
                throw Abort(
                    .conflict,
                    reason: "This seller cannot receive messages."
                )
            }

            guard seller != actor else {
                throw Abort(
                    .forbidden,
                    reason: "You cannot message yourself."
                )
            }

            conversation = try await ConversationRecord
                .query(on: db)
                .filter(\.$listingID == listingID)
                .filter(\.$buyerID == actor)
                .filter(\.$sellerID == seller)
                .first()
        }

        if let previous = try await MessageRecord.query(on: db)
            .filter(\.$senderID == actor)
            .filter(\.$clientMessageID == input.clientMessageId)
            .first() {

            let original = try MessageEncryption.decrypt(
                previous.body
            )

            guard conversation?.id == previous.conversationID,
                  original == input.body else {
                throw Abort(
                    .conflict,
                    reason: "This message ID was used for another send."
                )
            }

            return (previous, false)
        }

        guard !input.body.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              input.body.count <= 1000 else {
            throw Abort(
                .unprocessableEntity,
                reason: "Enter a message of 1 to 1,000 characters."
            )
        }

        guard listing.status == "active" ||
            (
                listing.status == "reserved" &&
                conversation != nil
            ) else {
            throw Abort(
                .conflict,
                reason: "This listing is closed to new messages."
            )
        }

        let thread: ConversationRecord

        if let conversation {
            thread = conversation
        } else {
            guard let seller = UUID(
                uuidString: listing.ownerID
            ) else {
                throw Abort(.conflict)
            }

            thread = ConversationRecord(
                listingID: listingID,
                buyerID: actor,
                sellerID: seller
            )
        }

        let recipient = actor == thread.buyerID
            ? thread.sellerID
            : thread.buyerID

        guard let peer = try await Account.find(
            recipient,
            on: db
        ), peer.verified else {
            throw Abort(
                .conflict,
                reason: "This account cannot receive messages."
            )
        }

        guard try await blockState(
            actor: actor,
            peer: recipient,
            on: db
        ).canMessage else {
            throw Abort(
                .forbidden,
                reason: "Messaging is blocked."
            )
        }

        let now = Date()

        let recent = try await MessageRecord.query(on: db)
            .filter(\.$senderID == actor)
            .filter(
                \.$createdAt > now.addingTimeInterval(-60)
            )
            .filter(\.$createdAt <= now)
            .sort(\.$createdAt, .descending)
            .range(0..<10)
            .all()

        if recent.count == 10,
           let oldest = recent.last {

            let seconds = max(
                1,
                Int(ceil(
                    oldest.createdAt
                        .addingTimeInterval(60)
                        .timeIntervalSince(now)
                ))
            )

            throw Abort(
                .tooManyRequests,
                headers: [
                    "Retry-After": String(seconds)
                ],
                reason: "You can send 10 messages per minute."
            )
        }

        if conversation == nil {
            try await thread.create(on: db)
        }

        let encryptedBody = try MessageEncryption.encrypt(
            input.body
        )

        let message = MessageRecord(
            conversationID: try thread.requireID(),
            senderID: actor,
            recipientID: recipient,
            clientMessageID: input.clientMessageId,
            body: encryptedBody,
            createdAt: now
        )

        try await message.create(on: db)

        return (message, true)
    }

    let response = Response(
        status: created ? .created : .ok
    )

    try response.content.encode(
        SentMessage(
            conversationId: saved.conversationID,
            message: try MessageView(
                saved,
                senderName: senderName
            )
        )
    )

    return response
}
