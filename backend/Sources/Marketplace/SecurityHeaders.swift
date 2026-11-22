
import Vapor

struct SecurityHeadersMiddleware: AsyncMiddleware {

    func respond(
        to request: Request,
        chainingTo next: AsyncResponder
    ) async throws -> Response {

        let response = try await next.respond(to: request)

        response.headers.replaceOrAdd(
            name: "X-Content-Type-Options",
            value: "nosniff"
        )

        response.headers.replaceOrAdd(
            name: "Referrer-Policy",
            value: "no-referrer"
        )

        response.headers.replaceOrAdd(
            name: "X-Frame-Options",
            value: "DENY"
        )

        if request.url.path.hasPrefix("/api/v1/") {
            response.headers.replaceOrAdd(
                name: .cacheControl,
                value: "no-store"
            )
        }

        // Only enable when the production deployment
        // actually enforces HTTPS.
        if Environment.get("DEPLOYED_HTTPS") == "true" {
            response.headers.replaceOrAdd(
                name: "Strict-Transport-Security",
                value: "max-age=31536000"
            )
        }

        return response
    }
}
