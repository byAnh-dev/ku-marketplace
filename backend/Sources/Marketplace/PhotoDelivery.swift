import Foundation
import PhotoDecoder
import Vapor

private struct ThumbnailQuery: Decodable {
    let width: Int?
}

/// Serves opt-in thumbnails while leaving the existing immutable file URLs
/// unchanged for clients that need the original normalized image.
struct PhotoDeliveryMiddleware: AsyncMiddleware {
    let publicDirectory: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let path = request.url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.count == 5, path[0] == "uploads", path[1] == "listings" else {
            return try await next.respond(to: request)
        }
        let query: ThumbnailQuery
        do {
            query = try request.query.decode(ThumbnailQuery.self)
        } catch {
            throw Abort(.badRequest, reason: "The thumbnail width must be an integer.")
        }
        guard let width = query.width else {
            let response = try await next.respond(to: request)
            addImmutableCacheHeader(to: response)
            return response
        }
        guard width >= 64, width <= 1024 else {
            throw Abort(.badRequest, reason: "The thumbnail width must be between 64 and 1024 pixels.")
        }
        guard isSafeComponent(path[2]), UUID(uuidString: path[3]) != nil,
              path[4].range(of: #"^\d+\.(jpg|png)$"#, options: .regularExpression) != nil else {
            throw Abort(.notFound)
        }

        let source = URL(fileURLWithPath: publicDirectory, isDirectory: true)
            .appendingPathComponent("uploads", isDirectory: true)
            .appendingPathComponent("listings", isDirectory: true)
            .appendingPathComponent(path[2], isDirectory: true)
            .appendingPathComponent(path[3], isDirectory: true)
            .appendingPathComponent(path[4], isDirectory: false)
        let thumbnail: Data
        do {
            thumbnail = try await request.application.threadPool.runIfActive(eventLoop: request.eventLoop) {
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                var output: UnsafeMutableRawPointer?
                var length = 0
                let result = data.withUnsafeBytes { bytes in
                    marketplace_resize_photo(bytes.baseAddress, bytes.count, Int32(width), &output, &length)
                }
                defer { marketplace_free_photo(output) }
                guard result == 0, let output else { throw Abort(.notFound) }
                return Data(bytes: output, count: length)
            }.get()
        } catch let failure as AbortError {
            throw failure
        } catch {
            throw Abort(.notFound)
        }
        let response = Response(status: .ok)
        response.headers.contentType = .jpeg
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
        response.body = .init(data: thumbnail)
        return response
    }

    private func addImmutableCacheHeader(to response: Response) {
        if response.status == .ok {
            response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
        }
    }

    private func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
