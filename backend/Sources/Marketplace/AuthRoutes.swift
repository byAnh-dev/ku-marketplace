import Fluent
import Vapor

private func newToken() -> String { UUID().uuidString + UUID().uuidString }
private func normalizedEmail(_ input: String) -> String { input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
private func validKUEmail(_ email: String) -> Bool {
    let parts = email.split(separator: "@", omittingEmptySubsequences: false)
    return parts.count == 2 && !parts[0].isEmpty && parts[0].count <= 64 && parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._%+-".contains($0)) } && parts[1] == "ku.edu"
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
        // Ensure mail can be sent before recording a user who cannot verify.
        guard req.application.canSendVerificationEmail else {
            throw Abort(.serviceUnavailable, reason: "Email verification is not configured.")
        }
        guard try await Account.query(on: req.db).filter(\.$email == email).first() == nil else {
            throw Abort(.conflict, reason: "An account with this email already exists.")
        }
        let hash = try await req.password.async.hash(data.password)
        let user = Account(displayName: name, email: email, passwordHash: hash)
        do { try await user.create(on: req.db) }
        catch { throw Abort(.conflict, reason: "An account with this email already exists.") }
        let token = newToken()
        let credential = AuthCredential(userID: try user.requireID(), tokenHash: sessionTokenDigest(token), kind: "verification", expiresAt: Date().addingTimeInterval(VerificationTokens.lifetime))
        try await credential.create(on: req.db)
        do { try await req.application.verificationEmailSender.send(req, email, token) }
        catch {
            // Allow retry of registration if delivery fails (do not strand a new account).
            try? await user.delete(on: req.db)
            throw error
        }
        return RegistrationResponse(message: "Check your KU email for a verification link before logging in.")
    }

    auth.post("resend-verification") { req async throws -> Response in
        struct Body: Content { let email: String }
        struct Accepted: Content { let message: String; let retryAfterSeconds: Int }
        struct Cooldown: Content { let reason: String; let retryAfterSeconds: Int }
        let email = normalizedEmail(try req.content.decode(Body.self).email)
        guard validKUEmail(email) else { throw Abort(.badRequest, reason: "Use your @ku.edu email address.") }
        let token = newToken()
        let reservation = try await VerificationTokens.reserve(email: email, token: token, on: req.db)
        switch reservation {
        case .notNeeded:
            break
        case .wait(let remaining):
            let response = Response(status: .tooManyRequests)
            response.headers.replaceOrAdd(name: .retryAfter, value: String(remaining))
            try response.content.encode(Cooldown(reason: "Please wait before requesting another verification email.", retryAfterSeconds: remaining))
            return response
        case .pending(let userID, let credentialID):
            do {
                // Delivery runs outside the SQLite transaction, so a slow provider does
                // not block account or listing writes. Pending tokens cannot verify.
                try await req.application.verificationEmailSender.send(req, email, token)
                try await VerificationTokens.complete(userID: userID, credentialID: credentialID, on: req.db)
            } catch {
                try? await VerificationTokens.fail(credentialID: credentialID, on: req.db)
                throw Abort(.serviceUnavailable, reason: "Verification email could not be delivered. Please try again later.")
            }
        }
        let response = Response(status: .ok)
        try response.content.encode(Accepted(message: "If this account needs verification, a new link has been sent. Check your KU email.",
                                             retryAfterSeconds: Int(VerificationTokens.cooldown)))
        return response
    }

    auth.get("verify") { req async throws -> Response in
        struct VerifyQuery: Content { let token: String }
        let token = try req.query.decode(VerifyQuery.self).token
        try await VerificationTokens.verify(token: token, on: req.db)
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.body = .init(string: "<html><body><h2>KU Marketplace email verified.</h2><p>Return to the app to log in.</p></body></html>")
        return response
    }

    auth.post("login") { req async throws -> LoginResponse in
        let data = try req.content.decode(LoginBody.self)
        let email = normalizedEmail(data.email)
        guard validKUEmail(email), let user = try await Account.query(on: req.db).filter(\.$email == email).first(),
              try await req.password.async.verify(data.password, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Incorrect email or password.")
        }
        guard user.verified else { throw Abort(.forbidden, reason: "Verify your KU email before logging in.") }
        let token = newToken()
        try await AuthCredential(userID: try user.requireID(), tokenHash: sessionTokenDigest(token), kind: "session", expiresAt: Date().addingTimeInterval(7 * 24 * 3600)).create(on: req.db)
        return try LoginResponse(token: token, user: PublicUser(user))
    }
    auth.get("me") { req async throws -> PublicUser in
        let (user, _) = try await currentSession(req)
        return try PublicUser(user)
    }
    auth.post("logout") { req async throws -> HTTPStatus in
        let (_, credential) = try await currentSession(req)
        credential.used = true
        try await credential.save(on: req.db)
        return .noContent
    }
}
