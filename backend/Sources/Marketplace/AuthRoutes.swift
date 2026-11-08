import Crypto
import Fluent
import Vapor

func digest(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}
private func newToken() -> String { UUID().uuidString + UUID().uuidString }
private func normalizedEmail(_ input: String) -> String { input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
private func validKUEmail(_ email: String) -> Bool {
    let parts = email.split(separator: "@", omittingEmptySubsequences: false)
    return parts.count == 2 && !parts[0].isEmpty && parts[0].count <= 64
        && parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._%+-".contains($0)) }
        && parts[1] == "ku.edu"
}

private func sendVerification(_ req: Request, email: String, token: String) async throws {
    let base = Environment.get("PUBLIC_API_URL") ?? "http://localhost:8080"
    guard var components = URLComponents(string: base + "/api/v1/auth/verify") else {
        throw Abort(.internalServerError)
    }
    components.queryItems = [URLQueryItem(name: "token", value: token)]
    guard let link = components.url?.absoluteString else { throw Abort(.internalServerError) }
    // Development only: opt-in logging. Never enable with real accounts or a public host.
    if Environment.get("DEV_EMAIL_VERIFICATION") == "true" {
        req.logger.warning("DEVELOPMENT verification link for \(email): \(link)")
        return
    }
    // Resend is an example provider. Set a verified sender and API key in the host environment.
    guard let key = Environment.get("RESEND_API_KEY"),
          let sender = Environment.get("VERIFICATION_FROM_EMAIL"),
          !key.isEmpty, !sender.isEmpty else {
        throw Abort(.serviceUnavailable, reason: "Email verification is not configured.")
    }
    struct Mail: Content {
        struct Recipient: Content { let email: String }
        let from: String
        let to: [String]
        let subject: String
        let text: String
    }
    let response = try await req.client.post(URI(string: "https://api.resend.com/emails")) { outgoing in
        outgoing.headers.bearerAuthorization = BearerAuthorization(token: key)
        outgoing.headers.contentType = .json
        try outgoing.content.encode(Mail(from: sender, to: [email], subject: "Verify your KU Marketplace email",
                                         text: "Open this one-time link within 30 minutes: \(link)"))
    }
    guard response.status == .ok || response.status == .created || response.status == .accepted else {
        req.logger.error("Verification email provider rejected request (HTTP \(response.status.code))")
        throw Abort(.serviceUnavailable, reason: "Verification email could not be delivered.")
    }
}

/// The account plus the credential row that authenticated it, so logout can revoke.
private func currentAccount(_ req: Request) async throws -> (Account, AuthCredential) {
    guard let bearer = req.headers.bearerAuthorization?.token, bearer.count >= 60,
          let credential = try await AuthCredential.query(on: req.db)
            .filter(\.$tokenHash == digest(bearer)).filter(\.$kind == "session")
            .filter(\.$used == false).first(),
          credential.expiresAt > Date(),
          let account = try await Account.find(credential.userID, on: req.db), account.verified else {
        throw Abort(.unauthorized, reason: "Authentication required.")
    }
    return (account, credential)
}

func registerAuthRoutes(_ app: Application) {
    let auth = app.grouped("api", "v1", "auth")

    auth.post("register") { req async throws -> RegistrationResponse in
        let data = try req.content.decode(RegisterBody.self)
        let name = data.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = normalizedEmail(data.email)
        guard name.count >= 2 && name.count <= 80, validKUEmail(email),
              data.password == data.passwordConfirmation,
              data.password.utf8.count >= 12 && data.password.utf8.count <= 72 else {
            throw Abort(.badRequest, reason: "Enter a display name, valid @ku.edu email, and matching password (12–72 bytes).")
        }
        // Ensure mail can be sent before recording a user who could never verify.
        guard Environment.get("DEV_EMAIL_VERIFICATION") == "true" ||
                (Environment.get("RESEND_API_KEY") != nil && Environment.get("VERIFICATION_FROM_EMAIL") != nil) else {
            throw Abort(.serviceUnavailable, reason: "Email verification is not configured.")
        }
        guard try await Account.query(on: req.db).filter(\.$email == email).first() == nil else {
            throw Abort(.conflict, reason: "An account with this email already exists.")
        }
        let hash = try await req.password.async.hash(data.password)
        let account = Account(displayName: name, email: email, passwordHash: hash)
        do { try await account.create(on: req.db) }
        catch { throw Abort(.conflict, reason: "An account with this email already exists.") }
        let token = newToken()
        let credential = AuthCredential(userID: try account.requireID(), tokenHash: digest(token),
                                        kind: "verification", expiresAt: Date().addingTimeInterval(30 * 60))
        try await credential.create(on: req.db)
        do { try await sendVerification(req, email: email, token: token) }
        catch {
            // Allow retry of registration if delivery fails (do not strand a new account).
            try? await account.delete(on: req.db)
            throw error
        }
        return RegistrationResponse(message: "Check your KU email for a verification link before logging in.")
    }

    auth.get("verify") { req async throws -> Response in
        struct VerifyQuery: Content { let token: String }
        let token = try req.query.decode(VerifyQuery.self).token
        guard token.count >= 60,
              let credential = try await AuthCredential.query(on: req.db)
                .filter(\.$tokenHash == digest(token)).filter(\.$kind == "verification")
                .filter(\.$used == false).first(),
              credential.expiresAt > Date(),
              let account = try await Account.find(credential.userID, on: req.db) else {
            throw Abort(.badRequest, reason: "Verification link is invalid or expired.")
        }
        credential.used = true
        account.verified = true
        try await account.save(on: req.db)
        try await credential.save(on: req.db)
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.body = .init(string: "<html><body><h2>KU Marketplace email verified.</h2><p>Return to the app to log in.</p></body></html>")
        return response
    }

    auth.post("login") { req async throws -> LoginResponse in
        let data = try req.content.decode(LoginBody.self)
        let email = normalizedEmail(data.email)
        guard validKUEmail(email),
              let account = try await Account.query(on: req.db).filter(\.$email == email).first(),
              try await req.password.async.verify(data.password, created: account.passwordHash) else {
            throw Abort(.unauthorized, reason: "Incorrect email or password.")
        }
        guard account.verified else { throw Abort(.forbidden, reason: "Verify your KU email before logging in.") }
        let token = newToken()
        try await AuthCredential(userID: try account.requireID(), tokenHash: digest(token),
                                 kind: "session", expiresAt: Date().addingTimeInterval(7 * 24 * 3600))
            .create(on: req.db)
        return try LoginResponse(token: token, user: PublicUser(account))
    }

    auth.get("me") { req async throws -> PublicUser in
        let (account, _) = try await currentAccount(req)
        return try PublicUser(account)
    }

    auth.post("logout") { req async throws -> HTTPStatus in
        let (_, credential) = try await currentAccount(req)
        credential.used = true
        try await credential.save(on: req.db)
        return .noContent
    }
}
