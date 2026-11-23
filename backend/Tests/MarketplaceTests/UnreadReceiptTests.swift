@testable import Marketplace
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite struct UnreadReceiptTests {
    private struct Summary: Content {
        struct Thread: Content {
            let conversationId: UUID
            let unreadCount: Int
        }
        let total: Int
        let threads: [Thread]
    }

    private func account(_ app: Application) async throws -> UUID {
        let record = Account(displayName: "Reader", email: "\(UUID())@ku.edu", passwordHash: "fixture")
        record.verified = true
        try await record.create(on: app.db)
        return try record.requireID()
    }

    private func session(_ app: Application, for id: UUID) async throws -> String {
        let token = UUID().uuidString + UUID().uuidString
        try await AuthCredential(userID: id, tokenHash: sessionTokenDigest(token), kind: "session",
                                 expiresAt: Date().addingTimeInterval(3600)).create(on: app.db)
        return token
    }

    private func thread(_ app: Application, buyer: UUID, seller: UUID) async throws -> UUID {
        let listing = Listing(id: UUID().uuidString, title: "Desk", description: "Small desk", priceCents: 2400,
                              condition: "Good", category: "Furniture", sellerDisplayName: "Seller",
                              pickupArea: "Campus", photoURLs: [])
        try await Catalog(database: app.db).add(listing, ownerID: seller.uuidString)
        let record = ConversationRecord(listingID: listing.id, buyerID: buyer, sellerID: seller)
        try await record.create(on: app.db)
        return try record.requireID()
    }

    private func message(_ app: Application, thread: UUID, from sender: UUID, to recipient: UUID) async throws -> Int {
        let record = MessageRecord(conversationID: thread, senderID: sender, recipientID: recipient,
                                   clientMessageID: UUID(), body: "Can we meet at the library?")
        try await record.create(on: app.db)
        return try record.requireID()
    }

    private func summary(_ app: Application, _ token: String) async throws -> Summary {
        let response = try await app.testing().sendRequest(.GET, "/api/v1/me/unread") { req in
            req.headers.bearerAuthorization = .init(token: token)
        }
        try #require(response.status == .ok)
        return try response.content.decode(Summary.self)
    }

    private func mark(_ app: Application, _ token: String, _ thread: UUID, _ ids: [Int]) async throws -> HTTPStatus {
        let response = try await app.testing().sendRequest(.POST, "/api/v1/conversations/\(thread)/read") { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(["sequences": ids])
        }
        return response.status
    }

    @Test func invalidBatchesCannotChangeEitherAccountsCounts() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: [])
        }) { app in
            let buyer = try await account(app), seller = try await account(app), outsider = try await account(app)
            let buyerToken = try await session(app, for: buyer), sellerToken = try await session(app, for: seller)
            let outsiderToken = try await session(app, for: outsider)
            let a = try await thread(app, buyer: buyer, seller: seller)
            let b = try await thread(app, buyer: buyer, seller: seller)
            let incoming = try await message(app, thread: a, from: seller, to: buyer)
            let outgoing = try await message(app, thread: a, from: buyer, to: seller)
            let elsewhere = try await message(app, thread: b, from: seller, to: buyer)

            #expect(try await app.testing().sendRequest(.GET, "/api/v1/me/unread").status == .unauthorized)
            #expect(try await mark(app, outsiderToken, a, [incoming]) == .notFound)
            for invalid in [[incoming, outgoing], [incoming, elsewhere], [incoming, Int.max], [], Array(1...101)] {
                #expect(try await mark(app, buyerToken, a, invalid) == .unprocessableEntity)
            }
            let counts = try await summary(app, buyerToken)
            #expect(counts.total == 2)
            #expect(Dictionary(uniqueKeysWithValues: counts.threads.map { ($0.conversationId, $0.unreadCount) })
                == [a: 1, b: 1])
            #expect(try await summary(app, outsiderToken).total == 0)
            #expect(try await summary(app, sellerToken).total == 1)
        }
    }

    @Test func twoSessionsMarkDisplayedMessagesWhileAnotherArrivesAndSurviveRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unread-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var savedToken = ""
        try await withApp(configure: { app in
            _ = try await configureApplication(app, databasePath: url.path, seedListings: [])
        }) { app in
            let buyer = try await account(app), seller = try await account(app)
            let phone = try await session(app, for: buyer), tablet = try await session(app, for: buyer)
            savedToken = phone
            let id = try await thread(app, buyer: buyer, seller: seller)
            let olderPage = try await message(app, thread: id, from: seller, to: buyer)
            let first = try await message(app, thread: id, from: seller, to: buyer)
            let second = try await message(app, thread: id, from: seller, to: buyer)
            async let marked = mark(app, phone, id, [first, second])
            async let overlapping = mark(app, tablet, id, [second])
            async let arrival = message(app, thread: id, from: seller, to: buyer)
            let (phoneStatus, tabletStatus, third) = try await (marked, overlapping, arrival)
            #expect(phoneStatus == .noContent && tabletStatus == .noContent)
            #expect(try await summary(app, tablet).total == 2)
            let firstRead = try #require(try await MessageRecord.find(first, on: app.db)?.readAt)
            #expect(try await mark(app, tablet, id, [second, first, second]) == .noContent)
            #expect(try await MessageRecord.find(first, on: app.db)?.readAt == firstRead)
            #expect(try await MessageRecord.find(olderPage, on: app.db)?.readAt == nil)
            #expect(try await MessageRecord.find(third, on: app.db)?.readAt == nil)
            #expect(try await mark(app, phone, id, [olderPage]) == .noContent)
        }
        try await withApp(configure: { app in
            _ = try await configureApplication(app, databasePath: url.path, seedListings: [])
        }) { app in
            let counts = try await summary(app, savedToken)
            #expect(counts.total == 1)
            #expect(counts.threads.map(\.unreadCount) == [1])
        }
    }
}
