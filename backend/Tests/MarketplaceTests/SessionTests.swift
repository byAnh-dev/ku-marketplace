@testable import Marketplace
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

// These tests use SQLite accounts, password verification, HTTP login, and the
// production session authenticator. No test middleware installs an identity.
@Suite struct SessionTests {
    private let password = "Session-test-password-2026"

    private struct Draft: Content {
        var title = "Session test lamp"
        var description = "A lamp published with a real session."
        var priceCents = 1500
        var category = "Home"
        var condition = "Good"
        var ownerID = "forged-owner"
        var sellerDisplayName = "Forged seller"
    }

    private func account(_ app: Application, email: String, verified: Bool = true) async throws -> MarketplaceUser {
        let hash = try await app.password.async.hash(password)
        let user = MarketplaceUser(displayName: "Same display name", email: email, passwordHash: hash)
        user.verified = verified
        try await user.create(on: app.db)
        return user
    }

    private func login(_ app: Application, email: String) async throws -> String {
        let response = try await app.testing().sendRequest(.POST, "api/v1/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: email, password: password))
        })
        try #require(response.status == .ok)
        return try response.content.decode(LoginResponse.self).token
    }

    // Independent fixture construction lets invalid credential kinds, expiry,
    // and revocation exercise the database boundary without bypassing it.
    private func credential(_ app: Application, user: MarketplaceUser, kind: String = "session",
                            expiresAt: Date = Date().addingTimeInterval(3600), used: Bool = false) async throws -> String {
        let token = UUID().uuidString + UUID().uuidString
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let record = AuthCredential(userID: try user.requireID(), tokenHash: hash, kind: kind, expiresAt: expiresAt)
        record.used = used
        try await record.create(on: app.db)
        return token
    }

    private func expectDenied(_ app: Application, token: String?, detailID: String = "existing") async throws {
        let paths: [(HTTPMethod, String)] = [
            (.POST, "api/v1/listings"),
            (.GET, "api/v1/me/listings"),
            (.GET, "api/v1/me/listings/\(detailID)"),
            (.GET, "api/v1/auth/me")
        ]
        for (method, path) in paths {
            let response = try await app.testing().sendRequest(method, path, beforeRequest: { req in
                if let token { req.headers.bearerAuthorization = .init(token: token) }
                req.headers.add(name: "X-User-ID", value: "forged-owner")
                if method == .POST { try req.content.encode(Draft()) }
            })
            #expect(response.status == .unauthorized)
        }
    }

    @Test func realLoginPublishesWithUUIDOwnerAndIsolation() async throws {
        let catalog = Catalog(rows: [])
        try await withApp(configure: { app in
            try await configureApplication(app, catalog: catalog)
        }) { app in
            let alice = try await account(app, email: "alice@ku.edu")
            let bob = try await account(app, email: "bob@ku.edu")
            let aliceID = try alice.requireID().uuidString
            let bobID = try bob.requireID().uuidString
            let aliceToken = try await login(app, email: alice.email)
            let bobToken = try await login(app, email: bob.email)

            let published = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: aliceToken)
                req.headers.add(name: "X-User-ID", value: bobID)
                try req.content.encode(Draft(ownerID: bobID))
            })
            try #require(published.status == .created)
            let listing = try published.content.decode(Listing.self)
            #expect(listing.sellerDisplayName == alice.displayName)
            #expect(catalog.owned(by: aliceID).map { $0.listing.id } == [listing.id])
            #expect(catalog.owned(by: bobID).isEmpty)

            let own = try await app.testing().sendRequest(.GET, "api/v1/me/listings?ownerID=\(bobID)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: aliceToken)
            })
            #expect(own.status == .ok)
            #expect(try own.content.decode([OwnedListing].self).map { $0.listing.id } == [listing.id])
            let ownDetail = try await app.testing().sendRequest(.GET, "api/v1/me/listings/\(listing.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: aliceToken)
            })
            #expect(ownDetail.status == .ok)

            let other = try await app.testing().sendRequest(.GET, "api/v1/me/listings", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: bobToken)
            })
            #expect(other.status == .ok)
            #expect(try other.content.decode([OwnedListing].self).isEmpty)
            let otherDetail = try await app.testing().sendRequest(.GET, "api/v1/me/listings/\(listing.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: bobToken)
            })
            #expect(otherDetail.status == .notFound)

            // Public browse/detail stay public, even with an unusable token.
            for path in ["api/v1/listings", "api/v1/listings/\(listing.id)"] {
                let response = try await app.testing().sendRequest(.GET, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: "invalid")
                })
                #expect(response.status == .ok)
            }
        }
    }

    @Test func invalidSessionsCannotReadOwnedListingsOrPublish() async throws {
        let catalog = Catalog(rows: [])
        try await withApp(configure: { app in
            try await configureApplication(app, catalog: catalog)
        }) { app in
            let verified = try await account(app, email: "verified@ku.edu")
            let unverified = try await account(app, email: "unverified@ku.edu", verified: false)
            let expired = try await credential(app, user: verified, expiresAt: Date().addingTimeInterval(-1))
            let expiresNow = try await credential(app, user: verified, expiresAt: Date())
            let revoked = try await credential(app, user: verified, used: true)
            let verificationLink = try await credential(app, user: verified, kind: "verification")
            let unverifiedSession = try await credential(app, user: unverified)
            let forged = String(repeating: "f", count: 72)

            for token in [nil, "short", forged, expired, expiresNow, revoked, verificationLink, unverifiedSession] as [String?] {
                try await expectDenied(app, token: token)
            }
            #expect(catalog.search("").isEmpty)
        }
    }

    @Test func logoutRevokesOnlyThePresentedSession() async throws {
        let catalog = Catalog(rows: [])
        try await withApp(configure: { app in
            try await configureApplication(app, catalog: catalog)
        }) { app in
            let user = try await account(app, email: "logout@ku.edu")
            let first = try await login(app, email: user.email)
            let second = try await login(app, email: user.email)
            let published = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: first)
                try req.content.encode(Draft())
            })
            try #require(published.status == .created)
            let listing = try published.content.decode(Listing.self)
            let logout = try await app.testing().sendRequest(.POST, "api/v1/auth/logout", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: first)
            })
            #expect(logout.status == .noContent)
            try await expectDenied(app, token: first, detailID: listing.id)
            #expect(catalog.search("").count == 1)

            let stillSignedIn = try await app.testing().sendRequest(.GET, "api/v1/me/listings", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: second)
            })
            #expect(stillSignedIn.status == .ok)
            #expect(try stillSignedIn.content.decode([OwnedListing].self).map { $0.listing.id } == [listing.id])
            let anotherListing = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: second)
                try req.content.encode(Draft())
            })
            #expect(anotherListing.status == .created)
        }
    }

    @Test func loginRejectsWrongPasswordAndUnverifiedAccountsWithoutCreatingSessions() async throws {
        try await withApp(configure: { app in
            try await configureApplication(app, catalog: Catalog(rows: []))
        }) { app in
            let verified = try await account(app, email: "password@ku.edu")
            let unverified = try await account(app, email: "pending@ku.edu", verified: false)
            let wrongPassword = try await app.testing().sendRequest(.POST, "api/v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginBody(email: verified.email, password: "Incorrect-password"))
            })
            #expect(wrongPassword.status == .unauthorized)
            let pending = try await app.testing().sendRequest(.POST, "api/v1/auth/login", beforeRequest: { req in
                try req.content.encode(LoginBody(email: unverified.email, password: password))
            })
            #expect(pending.status == .forbidden)
            #expect(try await AuthCredential.query(on: app.db).count() == 0)
        }
    }

    @Test func accountVerificationIsRecheckedForAnExistingSession() async throws {
        let catalog = Catalog(rows: [])
        try await withApp(configure: { app in
            try await configureApplication(app, catalog: catalog)
        }) { app in
            let user = try await account(app, email: "recheck@ku.edu")
            let token = try await login(app, email: user.email)
            let before = try await app.testing().sendRequest(.GET, "api/v1/me/listings", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            })
            #expect(before.status == .ok)
            user.verified = false
            try await user.save(on: app.db)
            try await expectDenied(app, token: token)
            #expect(catalog.search("").isEmpty)
        }
    }
}
