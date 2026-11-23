
import Fluent
import Vapor

func messagingActor(_ req: Request) throws -> UUID {
    let user = try req.auth.require(
        AuthenticatedUser.self
    )

    guard let id = UUID(uuidString: user.id),
          user.verified else {
        throw Abort(.unauthorized)
    }

    return id
}

func messagingParticipants(
    _ req: Request
) async throws -> (
    conversation: ConversationRecord,
    actor: UUID,
    peer: UUID
) {
    let actor = try messagingActor(req)

    guard let id = req.parameters.get(
        "id",
        as: UUID.self
    ) else {
        throw Abort(.notFound)
    }

    let conversation = try await memberConversation(
        id,
        actor: actor,
        on: req.db
    )

    let peer = actor == conversation.buyerID
        ? conversation.sellerID
        : conversation.buyerID

    return (conversation, actor, peer)
}

func memberConversation(
    _ id: UUID,
    actor: UUID,
    on db: any Database
) async throws -> ConversationRecord {

    guard let conversation = try await ConversationRecord.find(
        id,
        on: db
    ),
    actor == conversation.buyerID ||
    actor == conversation.sellerID
    else {
        throw Abort(
            .notFound,
            reason: "Conversation unavailable."
        )
    }

    return conversation
}

struct MessageView: Content {
    let sequence: Int
    let clientMessageId: UUID
    let senderId: UUID
    let recipientId: UUID
    let senderDisplayName: String
    let body: String
    let createdAt: String

    init(
        _ message: MessageRecord,
        senderName: String
    ) throws {
        sequence = try message.requireID()
        clientMessageId = message.clientMessageID
        senderId = message.senderID
        recipientId = message.recipientID
        senderDisplayName = senderName

        body = try MessageEncryption.decrypt(
            message.body
        )

        createdAt = message.createdAt.ISO8601Format()
    }
}
