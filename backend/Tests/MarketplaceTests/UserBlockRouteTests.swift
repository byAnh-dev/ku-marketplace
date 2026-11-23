@testable import Marketplace
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite struct UserBlockRouteTests {
    private func account(_ app: Application) async throws -> (id: UUID, token: String) {
        let user = Account(displayName: "KU student", email: "\(UUID())@ku.edu", passwordHash: "unused")
        user.verified = true
        try await user.create(on: app.db)
        let id = try user.requireID()
        let token = UUID().uuidString + UUID().uuidString
        try await AuthCredential(userID: id, tokenHash: sessionTokenDigest(token), kind: "session",
                                 expiresAt: Date().addingTimeInterval(3600)).create(on: app.db)
        return (id, token)
    }

    private func request(_ app: Application, _ method: HTTPMethod, _ path: String,
                         token: String? = nil) async throws -> TestingHTTPResponse {
        try await app.testing().sendRequest(method, "api/v1/" + path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            if method == .POST {
                try req.content.encode(["body": "Is this available?", "clientMessageId": UUID().uuidString])
            }
        })
    }

    @Test func oneBlockGovernsBothRolesAndAllListings() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: [])
        }) { app in
            let a = try await account(app), b = try await account(app), stranger = try await account(app)
            let catalog = Catalog(database: app.db)
            // Reverse their buyer/seller roles on the second pair of listings.
            for (id, seller) in [("bike", a), ("lamp", a), ("desk", b), ("chair", b)] {
                let listing = Listing(id: id, title: id, description: "Used", priceCents: 100, condition: "Good",
                                      category: "Home", sellerDisplayName: "KU student", pickupArea: "Campus", photoURLs: [])
                try await catalog.add(listing, ownerID: seller.id.uuidString)
            }
            let bike = ConversationRecord(listingID: "bike", buyerID: b.id, sellerID: a.id)
            let desk = ConversationRecord(listingID: "desk", buyerID: a.id, sellerID: b.id)
            try await bike.create(on: app.db)
            try await desk.create(on: app.db)
            let first = "conversations/\(try bike.requireID())", second = "conversations/\(try desk.requireID())"

            for method in [HTTPMethod.PUT, .DELETE] {
                #expect(try await request(app, method, first + "/block").status == .unauthorized)
                #expect(try await request(app, method, first + "/block", token: stranger.token).status == .notFound)
            }
            #expect(try await blockState(actor: a.id, peer: b.id, on: app.db).canMessage)
            let before = try await request(app, .POST, first + "/messages", token: b.token)
            try #require(before.status == .created)
            let block = try await request(app, .PUT, first + "/block", token: a.token)
            try #require(block.status == .ok)
            #expect(try block.content.decode(BlockState.self) == BlockState(blockedByMe: true, canMessage: false))
            let undo = try await request(app, .DELETE, second + "/block", token: b.token)
            #expect(try undo.content.decode(BlockState.self) == BlockState(blockedByMe: false, canMessage: false))

            for token in [a.token, b.token] {
                for path in [first, second] {
                    #expect(try await request(app, .POST, path + "/messages", token: token).status == .forbidden)
                    #expect(try await request(app, .GET, path + "/messages", token: token).status == .ok)
                }
            }
            for (id, token) in [("lamp", b.token), ("chair", a.token)] {
                #expect(try await request(app, .POST, "listings/\(id)/conversations", token: token).status == .forbidden)
            }
            #expect(try await request(app, .GET, first + "/messages", token: stranger.token).status == .notFound)
            #expect(try await ConversationRecord.query(on: app.db).count() == 2)
            let messages = try await MessageRecord.query(on: app.db).all()
            try #require(messages.count == 1)
            // Bodies are encrypted at rest now; the stored value must never be the plaintext.
            #expect(try MessageEncryption.decrypt(messages[0].body) == "Is this available?")
            #expect(messages[0].body != "Is this available?")
            #expect(messages[0].readAt == nil)
        }
    }
}
