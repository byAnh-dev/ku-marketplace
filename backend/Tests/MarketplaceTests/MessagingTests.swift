@testable import Marketplace
import Fluent
import FluentSQL
import Foundation
import Testing
import VaporTesting

// Exercise the public JSON contract through the same routes and session middleware as the app.
@Suite struct MessagingTests {
    private struct Member: Sendable {
        let id = UUID()
        let token = UUID().uuidString + UUID().uuidString

        func register(in app: Application, verified: Bool = true) async throws {
            let user = Account(displayName: "Student", email: "\(id)@ku.edu", passwordHash: "test fixture")
            user.id = id
            user.verified = verified
            try await user.create(on: app.db)
            try await AuthCredential(userID: id, tokenHash: sessionTokenDigest(token), kind: "session",
                                     expiresAt: Date().addingTimeInterval(3600)).create(on: app.db)
        }
    }

    private struct Message: Content, Equatable {
        let sequence: Int
        let body: String
        let senderId: UUID
        let recipientId: UUID
        let clientMessageId: UUID
        let createdAt: Date
    }
    private struct Sent: Content { let conversationId: UUID; let message: Message }
    private struct Page: Content {
        let items: [Message]
        let hasOlder, hasNewer, canMessage: Bool
    }
    private struct Summary: Content { let id: UUID; let canMessage: Bool }
    private struct Unread: Content { let total: Int }

    private func listing(_ app: Application, _ id: String, seller: Member) async throws {
        let item = Listing(id: id, title: "Desk lamp", description: "Clip-on lamp", priceCents: 500,
                           condition: "Good", category: "Home", sellerDisplayName: "Student",
                           pickupArea: "Campus", photoURLs: [])
        try await Catalog(database: app.db).add(item, ownerID: seller.id.uuidString)
    }

    private func request(_ app: Application, _ method: HTTPMethod, _ path: String, as member: Member?,
                         fields: [String: String]? = nil, revision: String? = nil) async throws -> TestingHTTPResponse {
        try await app.testing().sendRequest(method, "api/v1/" + path, beforeRequest: { req in
            if let member { req.headers.bearerAuthorization = .init(token: member.token) }
            if let revision { req.headers.add(name: .ifMatch, value: revision) }
            if let fields { try req.content.encode(fields) }
        })
    }

    private func send(_ app: Application, _ path: String, as member: Member, _ body: String,
                      key: UUID = UUID()) async throws -> TestingHTTPResponse {
        try await request(app, .POST, path, as: member, fields: ["body": body, "clientMessageId": key.uuidString])
    }

    private func inbox(_ app: Application, _ member: Member) async throws -> [Summary] {
        let response = try await request(app, .GET, "conversations", as: member)
        try #require(response.status == .ok)
        return try response.content.decode([Summary].self)
    }

    private func page(_ app: Application, _ thread: UUID, _ member: Member, _ query: String = "") async throws -> Page {
        let response = try await request(app, .GET, "conversations/\(thread)/messages\(query)", as: member)
        try #require(response.status == .ok)
        return try response.content.decode(Page.self)
    }

    private func databaseDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("messaging-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func privateMessagesValidateParticipantsTextAndExclusivePageBoundaries() async throws {
        try await withApp(configure: { app in try await configureApplication(app) }) { app in
            let seller = Member(), buyer = Member(), stranger = Member(), pending = Member()
            for member in [seller, buyer, stranger] { try await member.register(in: app) }
            try await pending.register(in: app, verified: false)
            try await listing(app, "lamp", seller: seller)
            let start = "listings/lamp/conversations"
            #expect(try await request(app, .GET, "conversations", as: nil).status == .unauthorized)
            #expect(try await send(app, start, as: pending, "Hi").status == .unauthorized)
            #expect(try await send(app, start, as: seller, "Hi").status == .forbidden)
            #expect(try await send(app, "listings/desk-lamp/conversations", as: buyer, "Hi").status == .conflict)
            for body in ["", " \n ", String(repeating: "a", count: 1001)] {
                #expect(try await send(app, start, as: buyer, body).status == .unprocessableEntity)
            }
            #expect(try await inbox(app, seller).isEmpty)

            let earliest = Date().addingTimeInterval(-1) // Wire timestamps may omit fractional seconds.
            let firstKey = UUID()
            let opened = try await send(app, start, as: buyer, "?", key: firstKey)
            try #require(opened.status == .created)
            let first = try opened.content.decode(Sent.self)
            #expect(first.message.clientMessageId == firstKey)
            #expect(first.message.senderId == buyer.id && first.message.recipientId == seller.id)
            #expect(first.message.createdAt >= earliest && first.message.createdAt <= Date().addingTimeInterval(1))
            let path = "conversations/\(first.conversationId)/messages"
            #expect(try await request(app, .GET, path, as: stranger).status == .notFound)
            #expect(try await send(app, path, as: stranger, "Hi").status == .notFound)
            #expect(try await inbox(app, stranger).isEmpty)
            let other = try await send(app, start, as: stranger, "For pickup?")
            try #require(other.status == .created)
            #expect(try other.content.decode(Sent.self).conversationId != first.conversationId)

            let longest = String(repeating: "a", count: 1000)
            let reply = try await send(app, path, as: seller, longest)
            try #require(reply.status == .created)
            let second = try reply.content.decode(Sent.self)
            #expect(second.message.body == longest && second.message.senderId == seller.id)
            let newest = try await page(app, first.conversationId, buyer, "?limit=1")
            #expect(newest.items == [second.message] && newest.hasOlder)
            let next = try await send(app, start, as: buyer, "Thanks")
            try #require(next.status == .created)
            let third = try next.content.decode(Sent.self)
            #expect(third.conversationId == first.conversationId)
            let older = try await page(app, first.conversationId, buyer, "?before=\(second.message.sequence)&limit=1")
            #expect(older.items == [first.message] && !older.hasOlder)
            let fresh = try await page(app, first.conversationId, buyer, "?after=\(first.message.sequence)&limit=1")
            #expect(fresh.items == [second.message] && fresh.hasNewer)
            let all = try await page(app, first.conversationId, seller)
            #expect(all.items == [first.message, second.message, third.message])
            #expect(try await inbox(app, buyer).map(\.id) == [first.conversationId])
        }
    }

    @Test func concurrentFirstContactAndAccountWideQuotaUseCommittedMessages() async throws {
        let directory = try databaseDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("market.sqlite").path
        try await withApp(configure: { app in try await configureApplication(app, databasePath: database) }) { app in
            let seller = Member(), buyer = Member()
            for member in [buyer, seller] { try await member.register(in: app) }
            for id in ["one", "two", "three"] { try await listing(app, id, seller: seller) }
            let start = "listings/one/conversations", key = UUID()
            async let tap = send(app, start, as: buyer, "One", key: key)
            async let retry = send(app, start, as: buyer, "One", key: key)
            let responses = try await [tap, retry]
            #expect(responses.map { $0.status.code }.sorted() == [200, 201])
            let pair = try responses.map { try $0.content.decode(Sent.self) }
            #expect(pair[0].conversationId == pair[1].conversationId && pair[0].message == pair[1].message)
            #expect(try await send(app, start, as: buyer, "Different", key: key).status == .conflict)
            #expect(try await send(app, "listings/two/conversations", as: buyer, "One", key: key).status == .conflict)
            #expect(try await inbox(app, seller).count == 1)
            let path = "conversations/\(pair[0].conversationId)/messages"
            for _ in 0..<6 { #expect(try await send(app, path, as: buyer, "Another").status == .created) }
            async let newContact = send(app, "listings/two/conversations", as: buyer, "Second listing")
            async let simultaneous = send(app, "listings/two/conversations", as: buyer, "Also this one")
            let contacts = try await [newContact, simultaneous]
            try #require(contacts.allSatisfy { $0.status == .created })
            let other = try contacts[0].content.decode(Sent.self)
            let sameThread = try contacts[1].content.decode(Sent.self)
            #expect(other.conversationId == sameThread.conversationId && other.message.sequence != sameThread.message.sequence)
            let otherPath = "conversations/\(other.conversationId)/messages"

            async let a = send(app, path, as: buyer, "Ten?")
            async let b = send(app, otherPath, as: buyer, "Ten?")
            let raced = try await [a, b]
            #expect(raced.map { $0.status.code }.sorted() == [201, 429])
            let denied = try #require(raced.first { $0.status == .tooManyRequests })
            let seconds = try #require(denied.headers.first(name: "Retry-After").flatMap(Int.init))
            #expect((1...60).contains(seconds))
            #expect(try await send(app, "listings/three/conversations", as: buyer, "Over limit").status == .tooManyRequests)
            #expect(try await inbox(app, buyer).count == 2)
            #expect(try await send(app, start, as: buyer, "One", key: key).status == .ok)
            #expect(try await send(app, path, as: seller, "I can still reply").status == .created)
            let unread = try await request(app, .GET, "me/unread", as: seller)
            #expect(try unread.content.decode(Unread.self).total == 10)

            // Age one committed fixture beyond the rolling window without delaying the test suite.
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("""
                UPDATE messages SET created_at = \(bind: Date().addingTimeInterval(-61))
                WHERE sequence = \(bind: pair[0].message.sequence)
                """).run()
            #expect(try await send(app, otherPath, as: buyer, "A slot opened").status == .created)
            #expect(try await send(app, otherPath, as: buyer, "Full again").status == .tooManyRequests)
        }
    }

    @Test func racingBlockAndSendHaveOneCommittedOutcome() async throws {
        let directory = try databaseDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withApp(configure: { app in
            try await configureApplication(app, databasePath: directory.appendingPathComponent("race.sqlite").path)
        }) { app in
            let buyer = Member(), seller = Member()
            try await buyer.register(in: app)
            try await seller.register(in: app)
            try await listing(app, "desk", seller: seller)
            try await listing(app, "chair", seller: seller)
            let start = try await send(app, "listings/desk/conversations", as: buyer, "Desk")
            let thread = try start.content.decode(Sent.self).conversationId
            let blockPath = "conversations/\(thread)/block"
            var expectedUnread = 1
            for target in ["conversations/\(thread)/messages", "listings/chair/conversations"] {
                let key = UUID()
                async let blocking = request(app, .PUT, blockPath, as: seller)
                async let sending = send(app, target, as: buyer, "Race", key: key)
                let (block, sent) = try await (blocking, sending)
                try #require(block.status == .ok)
                try #require(sent.status == .created || sent.status == .forbidden)
                let committed = sent.status == .created
                if committed { expectedUnread += 1 }
                #expect(try await send(app, target, as: buyer, "Race", key: key).status == (committed ? .ok : .forbidden))
                #expect(try await send(app, target, as: buyer, "After block").status == .forbidden)
                let unread = try await request(app, .GET, "me/unread", as: seller)
                #expect(try unread.content.decode(Unread.self).total == expectedUnread)
                let expectedThreads = target.hasPrefix("listings/") && committed ? 2 : 1
                #expect(try await inbox(app, buyer).count == expectedThreads)
                #expect(try await request(app, .DELETE, blockPath, as: seller).status == .ok)
            }
        }
    }

    @Test func retryAndReadOnlyHistorySurviveBlocksListingClosureAndRestart() async throws {
        let directory = try databaseDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("market.sqlite").path
        let seller = Member(), buyer = Member()
        let listingIDs = ["sold-lamp", "deleted-chair"]
        let keys = [UUID(), UUID()]
        var saved: [Sent] = []
        try await withApp(configure: { app in try await configureApplication(app, databasePath: database) }) { app in
            try await seller.register(in: app)
            try await buyer.register(in: app)
            for (index, id) in listingIDs.enumerated() {
                try await listing(app, id, seller: seller)
                let response = try await send(app, "listings/\(id)/conversations", as: buyer, "Available?", key: keys[index])
                try #require(response.status == .created)
                saved.append(try response.content.decode(Sent.self))
            }
            let blocked = try await request(app, .PUT, "conversations/\(saved[0].conversationId)/block", as: seller)
            try #require(blocked.status == .ok)
            let otherPath = "conversations/\(saved[1].conversationId)/messages"
            #expect(try await send(app, otherPath, as: buyer, "Fresh").status == .forbidden)
            #expect(try await send(app, otherPath, as: seller, "Fresh").status == .forbidden)
            try await listing(app, "third", seller: seller)
            #expect(try await send(app, "listings/third/conversations", as: buyer, "New thread").status == .forbidden)
            let original = try await send(app, "listings/deleted-chair/conversations", as: buyer, "Available?", key: keys[1])
            try #require(original.status == .ok)
            #expect(try original.content.decode(Sent.self).message == saved[1].message)
            let unread = try await request(app, .GET, "me/unread", as: seller)
            #expect(try unread.content.decode(Unread.self).total == 2)
            let unblocked = try await request(app, .DELETE, "conversations/\(saved[0].conversationId)/block", as: seller)
            try #require(unblocked.status == .ok)
            let sale = try await request(app, .POST, "listings/sold-lamp/sold", as: seller, revision: "initial")
            let removal = try await request(app, .DELETE, "listings/deleted-chair", as: seller, revision: "initial")
            try #require(sale.status == .ok && removal.status == .ok)
        }

        let originals = saved
        try await withApp(configure: { app in try await configureApplication(app, databasePath: database) }) { app in
            for viewer in [seller, buyer] {
                let summaries = try await inbox(app, viewer)
                #expect(Set(summaries.map(\.id)) == Set(originals.map(\.conversationId)))
                #expect(summaries.allSatisfy { !$0.canMessage })
                for sent in originals {
                    let history = try await page(app, sent.conversationId, viewer)
                    #expect(history.items == [sent.message] && !history.canMessage)
                    #expect(try await send(app, "conversations/\(sent.conversationId)/messages", as: viewer, "Fresh").status == .conflict)
                }
            }
            for (i, id) in listingIDs.enumerated() {
                let replay = try await send(app, "listings/\(id)/conversations", as: buyer, "Available?", key: keys[i])
                try #require(replay.status == .ok)
                #expect(try replay.content.decode(Sent.self).message == originals[i].message)
            }
        }
    }
}
