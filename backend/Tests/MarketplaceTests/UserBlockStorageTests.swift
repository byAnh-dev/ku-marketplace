@testable import Marketplace
import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import VaporTesting

@Suite struct UserBlockStorageTests {
    @Test func directedBlocksPersistAndOnlyTheirOwnerCanClearThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("r23.sqlite").path
        let buyer = UUID(), seller = UUID(), other = UUID()
        let closed = BlockState(blockedByMe: true, canMessage: false)
        let peerBlocked = BlockState(blockedByMe: false, canMessage: false)
        let open = BlockState(blockedByMe: false, canMessage: true)

        func configure(_ app: Application) async throws {
            app.databases.use(.sqlite(.file(database)), as: .sqlite)
            app.migrations.add(CreateMarketplaceUsers())
            app.migrations.add(CreateUserBlocks())
            try await app.autoMigrate()
        }

        try await withApp(configure: configure) { app in
            for id in [buyer, seller, other] {
                let user = Account(displayName: "Participant", email: "\(id)@ku.edu", passwordHash: "unused")
                user.id = id
                try await user.create(on: app.db)
            }
            async let first = setUserBlock(true, actor: buyer, peer: seller, on: app.db)
            async let retry = setUserBlock(true, actor: buyer, peer: seller, on: app.db)
            let results = try await [first, retry]
            #expect(results == [closed, closed])
            #expect(try await setUserBlock(false, actor: seller, peer: buyer, on: app.db) == peerBlocked)
            #expect(try await blockState(actor: seller, peer: other, on: app.db) == open)
            #expect(try await setUserBlock(true, actor: seller, peer: buyer, on: app.db) == closed)
        }

        try await withApp(configure: configure) { app in
            #expect(try await blockState(actor: seller, peer: buyer, on: app.db) == closed)
            #expect(try await setUserBlock(false, actor: buyer, peer: seller, on: app.db) == peerBlocked)
            #expect(try await setUserBlock(false, actor: buyer, peer: seller, on: app.db) == peerBlocked)
            #expect(try await setUserBlock(false, actor: seller, peer: buyer, on: app.db) == open)
            #expect(try await blockState(actor: buyer, peer: seller, on: app.db) == open)
            await #expect(throws: (any Error).self) {
                try await setUserBlock(true, actor: buyer, peer: buyer, on: app.db)
            }
        }
    }
}
