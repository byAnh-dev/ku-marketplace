import Crypto
import Fluent
import Vapor

func sessionTokenDigest(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

// Read the current database state on every request so expiry, revocation and
// account verification changes apply to auth and listing endpoints alike.
func currentSession(_ req: Request) async throws -> (Account, AuthCredential) {
    guard let bearer = req.headers.bearerAuthorization?.token, bearer.count >= 60,
          let credential = try await AuthCredential.query(on: req.db)
            .filter(\.$tokenHash == sessionTokenDigest(bearer)).filter(\.$kind == "session")
            .filter(\.$used == false).first(),
          credential.expiresAt > Date(),
          let account = try await Account.find(credential.userID, on: req.db),
          account.verified else {
        throw Abort(.unauthorized, reason: "Authentication required.")
    }
    return (account, credential)
}

struct SessionAuthenticator: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if request.headers.bearerAuthorization != nil {
            let (account, _) = try await currentSession(request)
            request.auth.login(AuthenticatedUser(
                id: try account.requireID().uuidString,
                displayName: account.displayName,
                verified: account.verified))
        }
        // Missing credentials remain unauthenticated and are rejected by the guard.
        return try await next.respond(to: request)
    }
}
