import Fluent
import FluentSQLiteDriver
import Vapor

private struct APIResponseCacheMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        if request.url.path.hasPrefix("/api/v1/") {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        }
        return response
    }
}

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
    app.middleware.use(APIResponseCacheMiddleware(), at: .beginning)
    app.migrations.add(CreateMarketplaceUsers())
    app.migrations.add(CreateListings(seedRows: seedListings))
    app.migrations.add(AddListingRevisions())
    app.migrations.add(CreateMarketplaceIndexes())
    app.migrations.add(CreateMessaging())
    try await app.autoMigrate()
    registerAuthRoutes(app)
    let catalog = Catalog(database: app.db)
    configureRoutes(app, catalog: catalog)
    return catalog
}
