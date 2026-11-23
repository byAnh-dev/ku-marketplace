import Fluent
import Vapor

enum VerificationTokens {
    static let lifetime: TimeInterval = 30 * 60
    static let cooldown: TimeInterval = 60
    static let kinds = ["verification", "verification_pending"]

    enum Reservation: Sendable {
        case notNeeded
        case wait(Int)
        case pending(userID: UUID, credentialID: UUID)
    }

    private static func latest(userID: UUID, on db: any Database) async throws -> AuthCredential? {
        try await AuthCredential.query(on: db).filter(\.$userID == userID)
            .filter(\.$kind ~~ kinds).sort(\.$expiresAt, .descending).first()
    }

    static func reserve(email: String, token: String, on db: any Database) async throws -> Reservation {
        try await db.transaction { db in
            // Acquire SQLite's write lock before checking the persisted cooldown.
            try await Account.query(on: db).filter(\.$email == email).filter(\.$verified == false)
                .set(\.$verified, to: false).update()
            guard let user = try await Account.query(on: db).filter(\.$email == email)
                .filter(\.$verified == false).first() else { return .notNeeded }
            let userID = try user.requireID()
            let now = Date()
            if let previous = try await latest(userID: userID, on: db) {
                // Every verification attempt has a fixed lifetime, including failed sends.
                // Its expiry therefore also records issuance without changing old schemas.
                let remaining = previous.expiresAt.addingTimeInterval(-lifetime + cooldown).timeIntervalSince(now)
                if remaining > 0 { return .wait(Int(ceil(remaining))) }
            }
            let pending = AuthCredential(userID: userID, tokenHash: sessionTokenDigest(token),
                                         kind: "verification_pending", expiresAt: now.addingTimeInterval(lifetime))
            try await pending.create(on: db)
            return .pending(userID: userID, credentialID: try pending.requireID())
        }
    }

    static func complete(userID: UUID, credentialID: UUID, on db: any Database) async throws {
        try await db.transaction { db in
            try await Account.query(on: db).filter(\.$id == userID).filter(\.$verified == false)
                .set(\.$verified, to: false).update()
            guard let user = try await Account.find(userID, on: db), !user.verified,
                  let pending = try await AuthCredential.find(credentialID, on: db),
                  pending.kind == "verification_pending", !pending.used,
                  try await latest(userID: userID, on: db)?.id == credentialID else { return }
            // Never let a delayed sender activate a token superseded by a later request.
            try await AuthCredential.query(on: db).filter(\.$userID == userID)
                .filter(\.$kind ~~ kinds).filter(\.$id != credentialID).set(\.$used, to: true).update()
            pending.kind = "verification"
            try await pending.update(on: db)
        }
    }

    static func fail(credentialID: UUID, on db: any Database) async throws {
        // Keep the attempt for its cooldown, but do not touch the previous usable link.
        try await AuthCredential.query(on: db).filter(\.$id == credentialID)
            .filter(\.$kind == "verification_pending").set(\.$used, to: true).update()
    }

    static func verify(token: String, on db: any Database) async throws {
        guard token.count >= 60 else { throw invalidLink() }
        let digest = sessionTokenDigest(token)
        try await db.transaction { db in
            // Serialize consumption with resend completion before reading token state.
            try await AuthCredential.query(on: db).filter(\.$tokenHash == digest)
                .filter(\.$kind == "verification").filter(\.$used == false).set(\.$used, to: false).update()
            guard let credential = try await AuthCredential.query(on: db).filter(\.$tokenHash == digest)
                .filter(\.$kind == "verification").filter(\.$used == false).first(),
                  credential.expiresAt > Date(),
                  let user = try await Account.find(credential.userID, on: db), !user.verified else {
                throw invalidLink()
            }
            user.verified = true
            try await user.update(on: db)
            try await AuthCredential.query(on: db).filter(\.$userID == credential.userID)
                .filter(\.$kind ~~ kinds).set(\.$used, to: true).update()
        }
    }

    private static func invalidLink() -> Abort {
        Abort(.badRequest, reason: "Verification link is invalid or expired.")
    }
}
