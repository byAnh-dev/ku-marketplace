import Fluent
import FluentSQLiteDriver
import Vapor

func configureApplication(_ app: Application, catalog: Catalog = Catalog()) async throws {
    if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        let path = Environment.get("DATABASE_PATH") ?? "marketplace.sqlite"
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
    }
    app.migrations.add(CreateMarketplaceUsers())
    try await app.autoMigrate()
    registerAuthRoutes(app)
    configureRoutes(app, catalog: catalog)
}
