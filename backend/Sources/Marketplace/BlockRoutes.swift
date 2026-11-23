import Fluent
import Vapor

func registerBlockRoutes(_ secured: RoutesBuilder) {
    let block = secured.grouped("conversations", ":id", "block")
    block.put { req async throws -> BlockState in
        let participants = try await messagingParticipants(req)
        return try await setUserBlock(true, actor: participants.actor, peer: participants.peer, on: req.db)
    }
    block.delete { req async throws -> BlockState in
        let participants = try await messagingParticipants(req)
        return try await setUserBlock(false, actor: participants.actor, peer: participants.peer, on: req.db)
    }
}
