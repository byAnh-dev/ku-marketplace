import Vapor
import Fluent
import FluentSQLiteDriver

@main
enum Server {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        do {
            let dbPath = Environment.get("DATABASE_PATH") ?? "marketplace.sqlite"
            app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)
            app.migrations.add(CreateMarketplaceUsers())
            try await app.autoMigrate()
            registerAuthRoutes(app)
            let catalog = Catalog()
            app.get("health") { _ in ["status": "ok"] }
            let listings = app.grouped("api", "v1", "listings")
            listings.get { req -> [Listing] in
                let query = try req.query.decode(SearchQuery.self)
                return catalog.search(query.q ?? "")
            }
            listings.get(":id") { req -> Listing in
                guard let id = req.parameters.get("id"), let listing = catalog.active(id) else {
                    throw Abort(.notFound, reason: "This listing is unavailable.")
                }
                return listing
            }
            try await app.execute()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

private struct SearchQuery: Decodable { let q: String? }
