import Fluent
import FluentSQLiteDriver
import Vapor

@main
enum Server {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        do {
            let dbPath = Environment.get("DATABASE_PATH") ?? "marketplace.sqlite"
            app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)
            app.migrations.add(CreateAccounts())
            try await app.autoMigrate()
            // Resolves a session bearer token into MarketplaceUser for the guarded routes.
            app.middleware.use(SessionAuthenticator())
            registerAuthRoutes(app)
            configureRoutes(app)
            try await app.execute()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
