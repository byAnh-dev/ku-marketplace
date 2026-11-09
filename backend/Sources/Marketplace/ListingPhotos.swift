import Foundation
import PhotoDecoder
import Vapor

/// Multipart files arrive in display order. The first file is the cover photo.
struct PhotoUploadBody: Content {
    let photos: [File]?
}

struct PhotoUpload: Sendable {
    static let maxCount = 5
    static let maxBytes = 8 * 1024 * 1024
    let files: [(data: Data, ext: String)]

    // Called on the application thread pool, since decoding is CPU-bound.
    init(_ body: PhotoUploadBody) throws {
        let photos = body.photos ?? []
        guard !photos.isEmpty else { throw ListingFieldErrors(fields: ["photos": "Add at least one photo."]) }
        guard photos.count <= Self.maxCount else {
            throw ListingFieldErrors(fields: ["photos": "Add up to \(Self.maxCount) photos."])
        }
        var decoded: [(data: Data, ext: String)] = []
        for (index, photo) in photos.enumerated() {
            guard photo.data.readableBytes <= Self.maxBytes else {
                throw ListingFieldErrors(fields: ["photos": "Photo \(index + 1) must be 8 MB or smaller."])
            }
            let input = Data(photo.data.readableBytesView)
            var output: UnsafeMutableRawPointer?
            var length = 0
            var format: Int32 = 0
            let result = input.withUnsafeBytes { bytes in
                marketplace_decode_photo(bytes.baseAddress, bytes.count, &output, &length, &format)
            }
            defer { marketplace_free_photo(output) }
            if result == 3 { throw Abort(.internalServerError, reason: "Photo processing is unavailable.") }
            if result == 2 {
                throw ListingFieldErrors(fields: ["photos": "Photo \(index + 1) must be 20 megapixels or smaller."])
            }
            guard result == 0, let output else {
                throw ListingFieldErrors(fields: ["photos": "Photo \(index + 1) must be a valid JPEG, PNG, or HEIC image."])
            }
            guard length <= Self.maxBytes else {
                throw ListingFieldErrors(fields: ["photos": "Photo \(index + 1) is too large after processing. Choose a smaller image."])
            }
            decoded.append((Data(bytes: output, count: length), format == 1 ? "png" : "jpg"))
        }
        self.files = decoded
    }
}

struct PhotoStorage: Sendable {
    let publicDirectory: String

    func replace(listingID: String, ownerID: String, with upload: PhotoUpload,
                 catalog: Catalog, on req: Request) async throws -> Listing {
        let urls = try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
            try self.store(listingID: listingID, upload: upload)
        }.get()
        let replacement: (listing: Listing, previousPhotoURLs: [String])
        do {
            guard let saved = try await catalog.replacePhotos(urls, listingID: listingID, ownerID: ownerID) else {
                throw Abort(.notFound, reason: "This listing is unavailable.")
            }
            replacement = saved
        } catch {
            // The database still references the old set. Remove only this failed upload.
            try? await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
                self.removeGenerations(urls, listingID: listingID, logger: req.logger)
            }.get()
            throw error
        }
        // The database transaction has committed. Cleanup failure must not undo or
        // report failure for a successfully published replacement.
        try? await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
            self.removeGenerations(replacement.previousPhotoURLs, listingID: listingID, logger: req.logger)
        }.get()
        return replacement.listing
    }

    private func store(listingID: String, upload: PhotoUpload) throws -> [String] {
        guard !listingID.isEmpty, listingID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw Abort(.notFound)
        }
        let manager = FileManager.default
        let root = URL(fileURLWithPath: publicDirectory, isDirectory: true)
        let generation = UUID().uuidString.lowercased()
        let pending = root.appendingPathComponent("uploads/.staging/\(generation)", isDirectory: true)
        let relative = "uploads/listings/\(listingID)/\(generation)/"
        let destination = root.appendingPathComponent(relative, isDirectory: true)
        var ready = false
        defer {
            try? manager.removeItem(at: pending)
            if !ready { try? manager.removeItem(at: destination) }
        }

        try manager.createDirectory(at: pending, withIntermediateDirectories: true)
        var urls: [String] = []
        for (index, file) in upload.files.enumerated() {
            let filename = "\(index).\(file.ext)"
            try file.data.write(to: pending.appendingPathComponent(filename), options: .atomic)
            urls.append("/" + relative + filename)
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: pending, to: destination)
        ready = true
        return urls
    }

    private func removeGenerations(_ urls: [String], listingID: String, logger: Logger) {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: publicDirectory, isDirectory: true)
        // The committed transaction returns exactly the displaced version, so
        // concurrent cleanup cannot delete the version currently in the database.
        let prefix = "/uploads/listings/\(listingID)/"
        let generations = Set(urls.compactMap { path -> String? in
            guard path.hasPrefix(prefix) else { return nil }
            let pieces = path.dropFirst(prefix.count).split(separator: "/")
            guard pieces.count == 2, UUID(uuidString: String(pieces[0])) != nil else { return nil }
            return String(pieces[0])
        })
        for old in generations {
            do { try manager.removeItem(at: root.appendingPathComponent("uploads/listings/\(listingID)/\(old)")) }
            catch { logger.warning("Could not remove a superseded listing photo set.") }
        }
    }
}
