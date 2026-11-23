@testable import Marketplace
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

// The external email provider is the only substitute. Account creation, token
// rotation, password login, verification and cooldown checks use real SQLite.
@Suite struct VerificationTests {
    private let password = "Verification-test-password-2026"
    private struct EmailBody: Content { let email: String }
    private struct ResendBody: Decodable { let message: String; let retryAfterSeconds: Int }
    private struct CooldownBody: Decodable { let reason: String; let retryAfterSeconds: Int }

    private actor Mailbox {
        struct Message: Sendable { let email: String; let token: String }
        private var messages: [Message] = []
        private var fail = false
        private var hold = false
        private var pending: CheckedContinuation<Void, Never>?
        private var timedOut = false
        func send(email: String, token: String) async throws {
            messages.append(Message(email: email, token: token))
            if hold { await withCheckedContinuation { pending = $0 } }
            if fail { throw Abort(.serviceUnavailable, reason: "The test email provider is unavailable.") }
        }
        func setFailure(_ value: Bool) { fail = value }
        func received() -> [Message] { messages }
        func holdDelivery() { hold = true }
        func isWaiting() -> Bool { pending != nil }
        func release(timedOut: Bool = false) {
            hold = false
            self.timedOut = self.timedOut || timedOut
            pending?.resume()
            pending = nil
        }
        func wasReleasedByTimeout() -> Bool { timedOut }
    }

    private func configure(_ app: Application, mailbox: Mailbox, path: String? = nil) async throws {
        app.verificationEmailSender = VerificationEmailSender { _, email, token in
            try await mailbox.send(email: email, token: token)
        }
        try await configureApplication(app, databasePath: path, seedListings: [])
    }

    private func register(_ app: Application, email: String) async throws -> Account {
        let response = try await app.testing().sendRequest(.POST, "api/v1/auth/register", beforeRequest: { req in
            try req.content.encode(RegisterBody(displayName: "Verification student", email: email,
                                                password: password, passwordConfirmation: password))
        })
        try #require(response.status == .ok)
        return try #require(try await Account.query(on: app.db).filter(\.$email == email).first())
    }

    private func resend(_ app: Application, email: String) async throws -> TestingHTTPResponse {
        try await app.testing().sendRequest(.POST, "api/v1/auth/resend-verification", beforeRequest: { req in
            try req.content.encode(EmailBody(email: email))
        })
    }

    private func verify(_ app: Application, token: String) async throws -> TestingHTTPResponse {
        try await app.testing().sendRequest(.GET, "api/v1/auth/verify?token=\(token)")
    }

    private func age(_ app: Application, token: String, expired: Bool = false) async throws {
        let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let record = try #require(try await AuthCredential.query(on: app.db).filter(\.$tokenHash == digest).first())
        // Advance the fixture's issued time beyond the 60-second cooldown. The
        // documented verification lifetime is 30 minutes; no process clock changes.
        record.expiresAt = Date().addingTimeInterval(expired ? -1 : 30 * 60 - 61)
        try await record.save(on: app.db)
    }

    private func expectCooldown(_ response: TestingHTTPResponse) throws {
        #expect(response.status == .tooManyRequests)
        let body = try response.content.decode(CooldownBody.self)
        #expect((1...60).contains(body.retryAfterSeconds))
        #expect(!body.reason.isEmpty)
        #expect(response.headers.first(name: "Retry-After") == String(body.retryAfterSeconds))
    }

    @Test func expiredLinkCanBeReplacedWithoutChangingTheAccountOrPassword() async throws {
        let mailbox = Mailbox()
        try await withApp(configure: { app in try await configure(app, mailbox: mailbox) }) { app in
            let account = try await register(app, email: "expired@ku.edu")
            let accountID = try account.requireID()
            let passwordHash = account.passwordHash
            let original = try #require(await mailbox.received().first)
            try expectCooldown(try await resend(app, email: account.email))
            #expect(await mailbox.received().count == 1)
            try await age(app, token: original.token, expired: true)
            #expect(try await verify(app, token: original.token).status == .badRequest)

            let resent = try await resend(app, email: "  EXPIRED@KU.EDU  ")
            try #require(resent.status == .ok)
            let body = try resent.content.decode(ResendBody.self)
            #expect(body.retryAfterSeconds == 60)
            #expect(!body.message.isEmpty)
            let messages = await mailbox.received()
            try #require(messages.count == 2)
            #expect(messages[1].email == account.email)
            #expect(messages[1].token != original.token)
            #expect(try await verify(app, token: original.token).status == .badRequest)
            #expect(try await verify(app, token: messages[1].token).status == .ok)
            #expect(try await verify(app, token: messages[1].token).status == .badRequest)

            let stored = try #require(try await Account.find(accountID, on: app.db))
            #expect(stored.verified)
            #expect(stored.passwordHash == passwordHash)
            #expect(try await Account.query(on: app.db).count() == 1)
            let login = try await app.testing().sendRequest(.POST, "api/v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginBody(email: account.email, password: password))
            })
            #expect(login.status == .ok)
            #expect(try login.content.decode(LoginResponse.self).user.id == accountID)
        }
    }

    @Test func successfulResendInvalidatesAnOlderLinkThatHasNotExpired() async throws {
        let mailbox = Mailbox()
        try await withApp(configure: { app in try await configure(app, mailbox: mailbox) }) { app in
            let account = try await register(app, email: "replace@ku.edu")
            let original = try #require(await mailbox.received().first)
            try await age(app, token: original.token)
            #expect(try await resend(app, email: account.email).status == .ok)
            let latest = try #require(await mailbox.received().last)
            #expect(latest.token != original.token)
            #expect(try await verify(app, token: original.token).status == .badRequest)
            #expect(try await Account.find(account.id, on: app.db)?.verified == false)
            #expect(try await verify(app, token: latest.token).status == .ok)
        }
    }

    @Test func deliveryFailureKeepsTheOldLinkAndAccountAndEnforcesCooldown() async throws {
        let mailbox = Mailbox()
        try await withApp(configure: { app in try await configure(app, mailbox: mailbox) }) { app in
            let account = try await register(app, email: "delivery@ku.edu")
            let original = try #require(await mailbox.received().first)
            try await age(app, token: original.token)
            await mailbox.setFailure(true)
            #expect(try await resend(app, email: account.email).status == .serviceUnavailable)
            let messages = await mailbox.received()
            try #require(messages.count == 2)
            try expectCooldown(try await resend(app, email: account.email))
            #expect(await mailbox.received().count == 2)
            let stored = try #require(try await Account.find(account.id, on: app.db))
            #expect(stored.passwordHash == account.passwordHash)
            #expect(!stored.verified)
            #expect(try await verify(app, token: messages[1].token).status == .badRequest)
            #expect(try await verify(app, token: original.token).status == .ok)
        }
    }

    @Test func concurrentResendsIssueOnlyOneReplacementEmail() async throws {
        let mailbox = Mailbox()
        try await withApp(configure: { app in try await configure(app, mailbox: mailbox) }) { app in
            let account = try await register(app, email: "parallel@ku.edu")
            let original = try #require(await mailbox.received().first)
            try await age(app, token: original.token)
            async let first = resend(app, email: account.email)
            async let second = resend(app, email: account.email)
            let responses = try await [first, second]
            #expect(responses.filter { $0.status == .ok }.count == 1)
            let denied = try #require(responses.first { $0.status == .tooManyRequests })
            try expectCooldown(denied)
            let messages = await mailbox.received()
            try #require(messages.count == 2)
            #expect(try await verify(app, token: original.token).status == .badRequest)
            #expect(try await verify(app, token: messages[1].token).status == .ok)
        }
    }

    @Test func unknownAndVerifiedAccountsHaveTheSameResponseWithoutSendingEmail() async throws {
        let mailbox = Mailbox()
        try await withApp(configure: { app in try await configure(app, mailbox: mailbox) }) { app in
            let account = try await register(app, email: "verified@ku.edu")
            let token = try #require(await mailbox.received().first?.token)
            #expect(try await verify(app, token: token).status == .ok)
            let known = try await resend(app, email: account.email)
            let unknown = try await resend(app, email: "unknown@ku.edu")
            #expect(known.status == .ok)
            #expect(unknown.status == known.status)
            let a = try known.content.decode(ResendBody.self)
            let b = try unknown.content.decode(ResendBody.self)
            #expect(a.message == b.message)
            #expect(a.retryAfterSeconds == b.retryAfterSeconds)
            #expect(await mailbox.received().count == 1)
            #expect(try await Account.query(on: app.db).count() == 1)
            for invalid in ["", "student@example.com", "student@notku.edu", "not-an-email"] {
                #expect(try await resend(app, email: invalid).status == .badRequest)
            }
            #expect(await mailbox.received().count == 1)
        }
    }

    @Test func verificationCanFinishWhileResendDeliveryIsPending() async throws {
        let mailbox = Mailbox()
        try await withApp(configure: { app in try await configure(app, mailbox: mailbox) }) { app in
            let account = try await register(app, email: "pending@ku.edu")
            let original = try #require(await mailbox.received().first)
            try await age(app, token: original.token)
            await mailbox.holdDelivery()
            let sending = Task { try await resend(app, email: account.email) }
            // Unblock even a broken implementation that holds its DB transaction
            // across delivery. That defect fails this test instead of hanging it.
            let watchdog = Task {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                await mailbox.release(timedOut: true)
            }
            do {
                // A loaded CI runner can take seconds to schedule the resend task;
                // one second of polling made this fail at random, not on a defect.
                for _ in 0..<900 {
                    if await mailbox.isWaiting() { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try #require(await mailbox.isWaiting())
                let pending = try #require(await mailbox.received().last)
                #expect(pending.token != original.token)
                #expect(try await verify(app, token: pending.token).status == .badRequest)
                #expect(try await verify(app, token: original.token).status == .ok)
                let login = try await app.testing().sendRequest(.POST, "api/v1/auth/login", beforeRequest: { req in
                    try req.content.encode(LoginBody(email: account.email, password: password))
                })
                try #require(login.status == .ok)
                let session = try login.content.decode(LoginResponse.self)
                #expect(session.user.id == account.id)
                #expect(await mailbox.wasReleasedByTimeout() == false)
                await mailbox.release()
                watchdog.cancel()
                #expect(try await sending.value.status == .ok)
                // Late delivery must not activate a token for an already verified
                // account, invalidate the session, or make the old link reusable.
                #expect(try await verify(app, token: pending.token).status == .badRequest)
                #expect(try await verify(app, token: original.token).status == .badRequest)
                let profile = try await app.testing().sendRequest(.GET, "api/v1/auth/me", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: session.token)
                })
                #expect(profile.status == .ok)
                #expect(try profile.content.decode(PublicUser.self).id == session.user.id)
            } catch {
                await mailbox.release()
                watchdog.cancel()
                _ = try? await sending.value
                throw error
            }
        }
    }

    @Test func resendCooldownSurvivesClosingAndReopeningSQLite() async throws {
        let mailbox = Mailbox()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("verification-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("marketplace.sqlite").path
        try await withApp(configure: { app in try await configure(app, mailbox: mailbox, path: path) }) { app in
            let account = try await register(app, email: "restart@ku.edu")
            let original = try #require(await mailbox.received().first)
            try await age(app, token: original.token)
            #expect(try await resend(app, email: account.email).status == .ok)
        }
        try await withApp(configure: { app in try await configure(app, mailbox: mailbox, path: path) }) { app in
            try expectCooldown(try await resend(app, email: "restart@ku.edu"))
            let messages = await mailbox.received()
            try #require(messages.count == 2)
            #expect(try await verify(app, token: messages[0].token).status == .badRequest)
            #expect(try await verify(app, token: messages[1].token).status == .ok)
        }
    }
}
