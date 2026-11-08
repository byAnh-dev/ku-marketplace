import Fluent
import Vapor

/// Resolves a session token into the request principal the route guards expect.
///
/// Runs before every route. Requests without a bearer token never touch the
/// database, and an expired, revoked, or unverified session leaves the request
/// anonymous so the guards return `401` instead of trusting a stale token.
struct SessionAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard bearer.token.count >= 60 else { return }
        guard let credential = try await AuthCredential.query(on: request.db)
                .filter(\.$tokenHash == digest(bearer.token)).filter(\.$kind == "session")
                .filter(\.$used == false).first(),
              credential.expiresAt > Date(),
              let account = try await Account.find(credential.userID, on: request.db),
              account.verified else { return }
        let id = try account.requireID()
        request.auth.login(MarketplaceUser(id: id.uuidString, displayName: account.displayName, verified: true))
    }
}
