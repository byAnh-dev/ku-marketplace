import Vapor

/// The external delivery boundary can be replaced in tests; tokens and SQLite stay real.
struct VerificationEmailSender: Sendable {
    let send: @Sendable (Request, String, String) async throws -> Void

    init(_ send: @escaping @Sendable (Request, String, String) async throws -> Void) {
        self.send = send
    }

    static let live = VerificationEmailSender { req, email, token in
        let base = Environment.get("PUBLIC_API_URL") ?? "http://localhost:8080"
        guard var components = URLComponents(string: base + "/api/v1/auth/verify") else {
            throw Abort(.internalServerError)
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let link = components.url?.absoluteString else { throw Abort(.internalServerError) }
        if Environment.get("DEV_EMAIL_VERIFICATION") == "true" {
            req.logger.warning("DEVELOPMENT verification link for \(email): \(link)")
            return
        }
        guard let key = Environment.get("RESEND_API_KEY"),
              let sender = Environment.get("VERIFICATION_FROM_EMAIL"),
              !key.isEmpty, !sender.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Email verification is not configured.")
        }
        struct Mail: Content {
            let from: String
            let to: [String]
            let subject: String
            let text: String
        }
        do {
            let response = try await req.client.post(URI(string: "https://api.resend.com/emails")) { outgoing in
                outgoing.timeout = .seconds(10)
                outgoing.headers.bearerAuthorization = BearerAuthorization(token: key)
                outgoing.headers.contentType = .json
                try outgoing.content.encode(Mail(from: sender, to: [email], subject: "Verify your KU Marketplace email",
                                                  text: "Open this one-time link within 30 minutes: \(link)"))
            }
            guard response.status == .ok || response.status == .created || response.status == .accepted else {
                req.logger.error("Verification email provider rejected request (HTTP \(response.status.code))")
                throw Abort(.serviceUnavailable)
            }
        } catch {
            throw Abort(.serviceUnavailable, reason: "Verification email could not be delivered. Please try again later.")
        }
    }
}

extension Application {
    private struct VerificationEmailKey: StorageKey { typealias Value = VerificationEmailSender }

    var verificationEmailSender: VerificationEmailSender {
        get { storage[VerificationEmailKey.self] ?? .live }
        set { storage[VerificationEmailKey.self] = newValue }
    }

    var canSendVerificationEmail: Bool {
        storage[VerificationEmailKey.self] != nil || Environment.get("DEV_EMAIL_VERIFICATION") == "true" ||
            (!(Environment.get("RESEND_API_KEY") ?? "").isEmpty && !(Environment.get("VERIFICATION_FROM_EMAIL") ?? "").isEmpty)
    }
}
