import Foundation
import Vapor

/// Multipart upload payload. Clients send each image under the field `photos[]`,
/// in display order: the first file becomes the listing's primary photo.
struct PhotoUploadBody: Content {
    let photos: [File]?
}

/// A photo set that passed validation, ready to be written to storage.
struct PhotoUpload {
    static let maxCount = 5
    static let maxBytes = 8 * 1024 * 1024
    let files: [(data: ByteBuffer, ext: String)]

    init(_ body: PhotoUploadBody) throws(ListingFieldErrors) {
        let photos = body.photos ?? []
        if photos.isEmpty { throw ListingFieldErrors(fields: ["photos": "Add at least one photo."]) }
        if photos.count > Self.maxCount {
            throw ListingFieldErrors(fields: ["photos": "Add up to \(Self.maxCount) photos."])
        }

        var files: [(data: ByteBuffer, ext: String)] = []
        for (index, photo) in photos.enumerated() {
            guard let ext = Self.imageExtension(photo.data) else {
                throw ListingFieldErrors(fields: ["photos": "Photo \(index + 1) must be a JPEG, PNG, or HEIC image."])
            }
            guard photo.data.readableBytes <= Self.maxBytes else {
                throw ListingFieldErrors(fields: ["photos": "Photo \(index + 1) must be 8 MB or smaller."])
            }
            files.append((photo.data, ext))
        }
        self.files = files
    }

    /// Picks the stored extension from the file's signature, not the client's
    /// filename, so a non-image can never be served under an image extension.
    private static func imageExtension(_ data: ByteBuffer) -> String? {
        let head = data.getBytes(at: data.readerIndex, length: min(12, data.readableBytes)) ?? []
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8),
           ["heic", "heix", "mif1"].contains(String(decoding: head[8..<12], as: UTF8.self)) { return "heic" }
        return nil
    }
}

/// Writes listing photos under `Public/uploads/listings/<id>/` and returns the
/// public URL paths in the same order. Each upload replaces the previous set.
/// ponytail: local disk only; swap for object storage when the project gets one.
struct PhotoStorage: Sendable {
    let publicDirectory: String // Vapor's publicDirectory, ends with "/".

    func replace(listingID: String, with upload: PhotoUpload, on req: Request) async throws -> [String] {
        let relativeFolder = "uploads/listings/\(listingID)/"
        let folder = publicDirectory + relativeFolder
        let manager = FileManager.default
        if manager.fileExists(atPath: folder) { try manager.removeItem(atPath: folder) }
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)

        var urls: [String] = []
        for (index, file) in upload.files.enumerated() {
            let name = "\(index)-\(UUID().uuidString.lowercased()).\(file.ext)"
            try await req.fileio.writeFile(file.data, at: folder + name)
            urls.append("/" + relativeFolder + name)
        }
        return urls
    }
}
