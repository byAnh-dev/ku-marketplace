import Fluent
import Vapor

final class Account: Model, @unchecked Sendable {
    // Keep the existing table name so renaming the Swift model preserves data.
    static let schema = "marketplace_users"
    @ID(key: .id) var id: UUID?
    @Field(key: "display_name") var displayName: String
    @Field(key: "email") var email: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "verified") var verified: Bool

    init() {}
    init(displayName: String, email: String, passwordHash: String) {
        self.id = UUID()
        self.displayName = displayName
        self.email = email
        self.passwordHash = passwordHash
        self.verified = false
    }
}

final class AuthCredential: Model, @unchecked Sendable {
    static let schema = "auth_credentials"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "kind") var kind: String
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "used") var used: Bool

    init() {}
    init(userID: UUID, tokenHash: String, kind: String, expiresAt: Date) {
        self.id = UUID()
        self.userID = userID
        self.tokenHash = tokenHash
        self.kind = kind
        self.expiresAt = expiresAt
        self.used = false
    }
}

// Fluent records this migration's type name. Keep it stable for existing databases.
struct CreateMarketplaceUsers: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Account.schema)
            .id()
            .field("display_name", .string, .required)
            .field("email", .string, .required)
            .unique(on: "email")
            .field("password_hash", .string, .required)
            .field("verified", .bool, .required)
            .create()
        try await db.schema(AuthCredential.schema)
            .id()
            .field("user_id", .uuid, .required, .references(Account.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .unique(on: "token_hash")
            .field("kind", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used", .bool, .required)
            .create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(AuthCredential.schema).delete()
        try await db.schema(Account.schema).delete()
    }
}

struct RegisterBody: Content {
    let displayName: String
    let email: String
    let password: String
    let passwordConfirmation: String
}
struct LoginBody: Content { let email: String; let password: String }
struct RegistrationResponse: Content { let message: String }
struct LoginResponse: Content { let token: String; let user: PublicUser }
struct PublicUser: Content {
    let id: UUID
    let displayName: String
    let email: String
    let verified: Bool
    init(_ user: Account) throws {
        self.id = try user.requireID()
        self.displayName = user.displayName
        self.email = user.email
        self.verified = user.verified
    }
}
