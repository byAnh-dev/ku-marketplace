@testable import Marketplace
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

// These scenarios come from the upload contract, independently of storage code.
// Sessions, multipart decoding, image decoding, disk writes, and public reads are real.
@Suite struct PhotoTests {
    private let password = "Photo-test-password-2026"
    // Independently encoded with Windows System.Drawing: red 2x1 PNG, green 1x2 JPEG.
    private static let png = Array(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAOSURBVBhXY/jPwPAfhAER9wP9lTZx2QAAAABJRU5ErkJggg==")!)
    private static let jpeg = Array(Data(base64Encoded: "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAACAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDu6KKK/h8/ziP/2Q==")!)

    // A real 32x24 black HEIC, independently generated with the libvips HEIF encoder.
    private static let heic = Array(Data(base64Encoded: "AAAAHGZ0eXBoZWljAAAAAG1pZjFoZWljbWlhZgAAAaptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABwaWN0AAAAAAAAAAAAAAAAAAAAAA5waXRtAAAAAAABAAAANGlsb2MAAAAAREAAAgABAAAAAAHOAAEAAAAAAAAAKwACAAAAAAH5AAEAAAAAAAAAvgAAADhpaW5mAAAAAAACAAAAFWluZmUCAAAAAAEAAGh2YzEAAAAAFWluZmUCAAABAAIAAEV4aWYAAAAA6WlwcnAAAADKaXBjbwAAAHZodmNDAQNwAAAAAAAAAAAAHvAA/P34+AAADwMgAAEAGEABDAH//wNwAAADAJAAAAMAAAMAHroCQCEAAQAqQgEBA3AAAAMAkAAAAwAAAwAeoCCBBZbqrprm4CGgwIAAAAMAgAAAAwCEIgABAAZEAcFzwYkAAAAUaXNwZQAAAAAAAABAAAAAQAAAAChjbGFwAAAAIAAAAAEAAAAYAAAAAf///+AAAAAC////2AAAAAIAAAAQcGl4aQAAAAADCAgIAAAAF2lwbWEAAAAAAAAAAQABBIECgwQAAAAaaXJlZgAAAAAAAAAOY2RzYwACAAEAAQAAAPFtZGF0AAAAJygBrxMhMZb4TlCn//1nhc0MlUxauU+lc90KUJNyfrj+8oeTxWKC4AAAAAZFeGlmAABJSSoACAAAAAYAEgEDAAEAAAABAAAAGgEFAAEAAABWAAAAGwEFAAEAAABeAAAAKAEDAAEAAAACAAAAEwIDAAEAAAABAAAAaYcEAAEAAABmAAAAAAAAADhjAADoAwAAOGMAAOgDAAAGAACQBwAEAAAAMDIxMAGRBwAEAAAAAQIDAACgBwAEAAAAMDEwMAGgAwABAAAA//8AAAKgBAABAAAAIAAAAAOgBAABAAAAGAAAAAAAAAA=")!)

    private func account(_ app: Application, email: String, id: UUID? = nil) async throws -> (Account, String) {
        let user = Account(displayName: "Photo owner", email: email, passwordHash: try await app.password.async.hash(password))
        if let id { user.id = id }
        user.verified = true
        try await user.create(on: app.db)
        let response = try await app.testing().sendRequest(.POST, "api/v1/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: email, password: password))
        })
        try #require(response.status == .ok)
        return (user, try response.content.decode(LoginResponse.self).token)
    }

    private func publish(_ app: Application, token: String) async throws -> Listing {
        let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateListingBody(title: "Photo test desk", description: "Desk with ordered photos.",
                                                    priceCents: 2500, category: "Furniture", condition: "Good", pickupArea: "Campus"))
        })
        try #require(response.status == .created)
        return try response.content.decode(Listing.self)
    }

    private func upload(_ app: Application, id: String, files: [[UInt8]], token: String?, malformed: Bool = false) async throws -> TestingHTTPResponse {
        let boundary = "photo-tests-\(UUID().uuidString)"
        var body = ByteBuffer()
        if files.isEmpty && !malformed {
            body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nNo photos selected\r\n")
        }
        for (index, bytes) in files.enumerated() {
            // Deliberately label every file JPEG. The decoder must use actual image data.
            body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"photos[]\"; filename=\"photo-\(index).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            body.writeBytes(bytes)
            body.writeString("\r\n")
        }
        body.writeString("--\(boundary)--\r\n")
        return try await app.testing().sendRequest(.POST, "api/v1/listings/\(id)/photos", beforeRequest: { req in
            req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            req.body = body
        })
    }

    private func withPhotoApp(seedListings: [Catalog.Row] = [],
                              _ body: (Application, Catalog, String) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-tests-\(UUID().uuidString)").path + "/"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try await withApp(configure: { app in
            app.directory = DirectoryConfiguration(workingDirectory: directory)
            _ = try await configureApplication(app, seedListings: seedListings)
        }) { app in
            try await body(app, Catalog(database: app.db), directory + "Public/")
        }
    }

    private func servedBytes(_ app: Application, urls: [String]) async throws -> [[UInt8]] {
        var result: [[UInt8]] = []
        for url in urls {
            #expect(url.hasPrefix("/uploads/listings/"))
            let response = try await app.testing().sendRequest(.GET, String(url.dropFirst()))
            try #require(response.status == .ok)
            #expect(response.body.readableBytes > 50)
            result.append(Array(response.body.readableBytesView))
        }
        return result
    }

    @Test func realOwnerUploadsOrderedImagesAndReplacesTheSet() async throws {
        try await withPhotoApp { app, catalog, _ in
            let (_, token) = try await account(app, email: "photos@ku.edu")
            let listing = try await publish(app, token: token)
            let first = try await upload(app, id: listing.id, files: [Self.png, Self.jpeg], token: token)
            try #require(first.status == .ok)
            let urls = try first.content.decode(Listing.self).photoURLs
            try #require(urls.count == 2)
            let bytes = try await servedBytes(app, urls: urls)
            // Distinct formats establish the order independently of generated filenames.
            #expect(bytes[0].starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
            #expect(bytes[1].starts(with: [0xff, 0xd8, 0xff]))
            let detail = try await app.testing().sendRequest(.GET, "api/v1/listings/\(listing.id)")
            #expect(try detail.content.decode(Listing.self).photoURLs == urls)
            #expect(try await catalog.active(listing.id)?.photoURLs == urls)

            let replacement = try await upload(app, id: listing.id, files: [Self.jpeg], token: token)
            try #require(replacement.status == .ok)
            let updated = try replacement.content.decode(Listing.self).photoURLs
            #expect(updated.count == 1)
            #expect(updated != urls)
            _ = try await servedBytes(app, urls: updated)
            #expect(try await catalog.active(listing.id)?.photoURLs == updated)
            for old in urls {
                #expect(try await app.testing().sendRequest(.GET, String(old.dropFirst())).status == .notFound)
            }

            let heicReplacement = try await upload(app, id: listing.id, files: [Self.heic], token: token)
            try #require(heicReplacement.status == .ok)
            let normalizedURLs = try heicReplacement.content.decode(Listing.self).photoURLs
            try #require(normalizedURLs.count == 1)
            #expect(normalizedURLs[0].hasSuffix(".jpg"))
            let normalizedBytes = try await servedBytes(app, urls: normalizedURLs)
            #expect(normalizedBytes[0].starts(with: [0xff, 0xd8, 0xff]))
            #expect(try await catalog.active(listing.id)?.photoURLs == normalizedURLs)
        }
    }

    @Test func unauthorizedAndInvalidUploadsPreserveExistingPhotos() async throws {
        let ownerID = UUID()
        let sold = Listing(id: "sold", title: "Sold desk", description: "Already sold.", priceCents: 2500,
                           condition: "Good", category: "Furniture", sellerDisplayName: "Photo owner", pickupArea: "Campus", photoURLs: [])
        try await withPhotoApp(seedListings: [.init(ownerID: ownerID.uuidString, status: .sold, listing: sold)]) { app, catalog, _ in
            let (owner, token) = try await account(app, email: "owner@ku.edu", id: ownerID)
            let (_, strangerToken) = try await account(app, email: "stranger@ku.edu")
            let listing = try await publish(app, token: token)
            let first = try await upload(app, id: listing.id, files: [Self.png], token: token)
            try #require(first.status == .ok)
            let urls = try first.content.decode(Listing.self).photoURLs
            let originalBytes = try await servedBytes(app, urls: urls)

            let expired = UUID().uuidString + UUID().uuidString
            let hash = SHA256.hash(data: Data(expired.utf8)).map { String(format: "%02x", $0) }.joined()
            try await AuthCredential(userID: ownerID, tokenHash: hash, kind: "session", expiresAt: Date().addingTimeInterval(-1)).create(on: app.db)
            for denied in [nil, "short", String(repeating: "x", count: 72), expired] as [String?] {
                #expect(try await upload(app, id: listing.id, files: [Self.jpeg], token: denied).status == .unauthorized)
            }
            #expect(try await upload(app, id: listing.id, files: [Self.jpeg], token: strangerToken).status == .notFound)
            #expect(try await upload(app, id: "missing", files: [Self.jpeg], token: token).status == .notFound)
            #expect(try await upload(app, id: sold.id, files: [Self.jpeg], token: token).status == .notFound)
            owner.verified = false
            try await owner.save(on: app.db)
            #expect(try await upload(app, id: listing.id, files: [Self.jpeg], token: token).status == .unauthorized)
            owner.verified = true
            try await owner.save(on: app.db)

            let malformed = try await upload(app, id: listing.id, files: [], token: token, malformed: true)
            #expect(malformed.status == .badRequest)
            #expect(try await catalog.active(listing.id)?.photoURLs == urls)

            let oversized = Self.png + [UInt8](repeating: 0, count: 8 * 1024 * 1024 + 1 - Self.png.count)
            let invalid: [[[UInt8]]] = [[], Array(repeating: Self.png, count: 6), [oversized],
                                       [[0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]], [Array(Self.png.prefix(33))], [Array("<html>not an image</html>".utf8)]]
            for files in invalid {
                let response = try await upload(app, id: listing.id, files: files, token: token)
                try #require(response.status == .unprocessableEntity)
                #expect(try response.content.decode(FieldErrorBody.self).fieldErrors["photos"] != nil)
                #expect(try await catalog.active(listing.id)?.photoURLs == urls)
            }
            #expect(try await servedBytes(app, urls: urls) == originalBytes)
        }
    }

    @Test func diskFailureDoesNotRemovePreviouslyPublishedPhotos() async throws {
        try await withPhotoApp { app, catalog, publicDirectory in
            let (_, token) = try await account(app, email: "disk@ku.edu")
            let listing = try await publish(app, token: token)
            let first = try await upload(app, id: listing.id, files: [Self.png], token: token)
            try #require(first.status == .ok)
            let urls = try first.content.decode(Listing.self).photoURLs
            let originalBytes = try await servedBytes(app, urls: urls)

            // An actual filesystem conflict prevents staging the next set. No I/O mock.
            let staging = publicDirectory + "uploads/.staging"
            if FileManager.default.fileExists(atPath: staging) { try FileManager.default.removeItem(atPath: staging) }
            try Data("not a directory".utf8).write(to: URL(fileURLWithPath: staging))
            let failure = try await upload(app, id: listing.id, files: [Self.jpeg, Self.png], token: token)
            #expect(failure.status == .internalServerError)
            #expect(try await catalog.active(listing.id)?.photoURLs == urls)
            #expect(try await servedBytes(app, urls: urls) == originalBytes)
        }
    }

    @Test func concurrentReplacementsLeaveOneCompleteReadableSet() async throws {
        try await withPhotoApp { app, catalog, _ in
            let (_, token) = try await account(app, email: "concurrent@ku.edu")
            let listing = try await publish(app, token: token)
            async let one = upload(app, id: listing.id, files: [Self.png], token: token)
            async let two = upload(app, id: listing.id, files: [Self.jpeg, Self.png], token: token)
            async let three = upload(app, id: listing.id, files: [Self.png, Self.jpeg, Self.png], token: token)
            let responses = try await [one, two, three]
            var acceptedSets: [[String]] = []
            for response in responses {
                try #require(response.status == .ok)
                acceptedSets.append(try response.content.decode(Listing.self).photoURLs)
            }
            let current = try #require(try await catalog.active(listing.id)?.photoURLs)
            #expect(acceptedSets.contains(current))
            #expect(Set(current).count == current.count)
            _ = try await servedBytes(app, urls: current)
            let detail = try await app.testing().sendRequest(.GET, "api/v1/listings/\(listing.id)")
            #expect(try detail.content.decode(Listing.self).photoURLs == current)
        }
    }
}
