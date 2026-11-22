
import Foundation
import PhotoDecoder
import Vapor

struct PhotoUploadBody: Content {
    let photos: [File]?
}

struct PhotoUpload: Sendable {
    static let maxCount = 10
    static let maxBytes = 5 * 1024 * 1024

    let files: [(data: Data, ext: String)]

    init(_ body: PhotoUploadBody) throws {
        let photos = body.photos ?? []

        guard !photos.isEmpty else {
            throw ListingFieldErrors(
                fields: ["photos": "Add at least one photo."]
            )
        }

        guard photos.count <= Self.maxCount else {
            throw ListingFieldErrors(
                fields: ["photos": "Add up to 10 photos."]
            )
        }

        let pngSignature: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A
        ]

        var decoded: [(data: Data, ext: String)] = []

        for (index, photo) in photos.enumerated() {
            let number = index + 1

            guard photo.data.readableBytes > 0,
                  photo.data.readableBytes <= Self.maxBytes
            else {
                throw ListingFieldErrors(
                    fields: [
                        "photos": "Photo \(number) must be 5 MiB or smaller."
                    ]
                )
            }

            let input = Data(photo.data.readableBytesView)

            let isJPEG = input.count >= 3 &&
                input[0] == 0xFF &&
                input[1] == 0xD8 &&
                input[2] == 0xFF

            let isPNG = input.count >= 8 &&
                Array(input.prefix(8)) == pngSignature

            guard isJPEG || isPNG else {
                throw ListingFieldErrors(
                    fields: [
                        "photos": "Photo \(number) must be a JPEG or PNG image."
                    ]
                )
            }

            var output: UnsafeMutableRawPointer?
            var length = 0
            var format: Int32 = 0

            let result = input.withUnsafeBytes { bytes in
                marketplace_decode_photo(
                    bytes.baseAddress,
                    bytes.count,
                    &output,
                    &length,
                    &format
                )
            }

            defer {
                marketplace_free_photo(output)
            }

            if result == 3 {
                throw Abort(
                    .internalServerError,
                    reason: "Photo processing is unavailable."
                )
            }

            if result == 2 {
                throw ListingFieldErrors(
                    fields: [
                        "photos": "Photo \(number) must be 20 megapixels or smaller."
                    ]
                )
            }

            guard result == 0, let output else {
                throw ListingFieldErrors(
                    fields: [
                        "photos": "Photo \(number) is corrupt or invalid."
                    ]
                )
            }

            guard length > 0 && length <= Self.maxBytes else {
                throw ListingFieldErrors(
                    fields: [
                        "photos": "Photo \(number) exceeds 5 MiB after processing."
                    ]
                )
            }

            decoded.append(
                (
                    Data(bytes: output, count: length),
                    format == 1 ? "png" : "jpg"
                )
            )
        }

        self.files = decoded
    }
}

struct PhotoStorage: Sendable {
    let publicDirectory: String

    func prepareForPublish(
        _ photos: [File],
        listingID: String,
        on req: Request
    ) async throws -> [String] {
        guard !photos.isEmpty else {
            return []
        }

        return try await req.application.threadPool
            .runIfActive(eventLoop: req.eventLoop) {
                let upload = try PhotoUpload(
                    PhotoUploadBody(photos: photos)
                )

                return try self.store(
                    listingID: listingID,
                    upload: upload
                )
            }
            .get()
    }

    func replace(
        listingID: String,
        ownerID: String,
        with upload: PhotoUpload,
        catalog: Catalog,
        on req: Request
    ) async throws -> Listing {

        let urls = try await req.application.threadPool
            .runIfActive(eventLoop: req.eventLoop) {
                try self.store(
                    listingID: listingID,
                    upload: upload
                )
            }
            .get()

        let replacement: (
            listing: Listing,
            previousPhotoURLs: [String]
        )

        do {
            guard let saved = try await catalog.replacePhotos(
                urls,
                listingID: listingID,
                ownerID: ownerID
            ) else {
                throw Abort(
                    .notFound,
                    reason: "This listing is unavailable."
                )
            }

            replacement = saved
        } catch {
            await discard(
                urls,
                listingID: listingID,
                on: req
            )
            throw error
        }

        await discard(
            replacement.previousPhotoURLs,
            listingID: listingID,
            on: req
        )

        return replacement.listing
    }

    func discard(
        _ urls: [String],
        listingID: String,
        on req: Request
    ) async {
        guard !urls.isEmpty else {
            return
        }

        try? await req.application.threadPool
            .runIfActive(eventLoop: req.eventLoop) {
                self.removeGenerations(
                    urls,
                    listingID: listingID,
                    logger: req.logger
                )
            }
            .get()
    }

    private func store(
        listingID: String,
        upload: PhotoUpload
    ) throws -> [String] {

        guard !listingID.isEmpty,
              listingID.allSatisfy({
                  $0.isASCII &&
                  (
                      $0.isLetter ||
                      $0.isNumber ||
                      $0 == "-" ||
                      $0 == "_"
                  )
              }) else {
            throw Abort(.notFound)
        }

        let manager = FileManager.default

        let root = URL(
            fileURLWithPath: publicDirectory,
            isDirectory: true
        )

        let generation = UUID().uuidString.lowercased()

        let pending = manager.temporaryDirectory
            .appendingPathComponent(
                "ku-marketplace-\(generation)",
                isDirectory: true
            )

        let relative =
            "uploads/listings/\(listingID)/\(generation)/"

        let destination = root.appendingPathComponent(
            relative,
            isDirectory: true
        )

        var ready = false

        defer {
            try? manager.removeItem(at: pending)

            if !ready {
                try? manager.removeItem(at: destination)
            }
        }

        try manager.createDirectory(
            at: pending,
            withIntermediateDirectories: true
        )

        var urls: [String] = []

        for (index, file) in upload.files.enumerated() {
            let filename = "\(index).\(file.ext)"

            try file.data.write(
                to: pending.appendingPathComponent(filename),
                options: .atomic
            )

            urls.append(
                "/" + relative + filename
            )
        }

        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try manager.moveItem(
            at: pending,
            to: destination
        )

        ready = true
        return urls
    }

    private func removeGenerations(
        _ urls: [String],
        listingID: String,
        logger: Logger
    ) {
        let manager = FileManager.default

        let root = URL(
            fileURLWithPath: publicDirectory,
            isDirectory: true
        )

        let prefix = "/uploads/listings/\(listingID)/"

        let generations = Set(
            urls.compactMap { path -> String? in
                guard path.hasPrefix(prefix) else {
                    return nil
                }

                let pieces = path
                    .dropFirst(prefix.count)
                    .split(separator: "/")

                guard pieces.count == 2,
                      UUID(uuidString: String(pieces[0])) != nil
                else {
                    return nil
                }

                return String(pieces[0])
            }
        )

        for old in generations {
            do {
                try manager.removeItem(
                    at: root.appendingPathComponent(
                        "uploads/listings/\(listingID)/\(old)"
                    )
                )
            } catch {
                logger.warning(
                    "Could not remove a superseded listing photo set."
                )
            }
        }
    }
}
