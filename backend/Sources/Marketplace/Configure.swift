import Fluent
import FluentSQLiteDriver
import Vapor

@discardableResult
func configureApplication(_ app: Application, databasePath: String? = nil,
                          seedListings: [Catalog.Row] = Catalog.samples) async throws -> Catalog {
    if let databasePath {
        app.databases.use(.sqlite(.file(databasePath)), as: .sqlite)
    } else if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        let path = Environment.get("DATABASE_PATH") ?? "marketplace.sqlite"
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
    }
    app.migrations.add(CreateMarketplaceUsers())
    app.migrations.add(CreateListings(seedRows: seedListings))
    try await app.autoMigrate()
    registerAuthRoutes(app)
    let catalog = Catalog(database: app.db)
    configureRoutes(app, catalog: catalog)
    return catalog
}
