@testable import Marketplace
import Foundation
import Testing
import VaporTesting

/// Requirement 15: newest by default, price order on request, a stable tie
/// breaker, and ordering that survives filters and pages.
@Suite struct SortTests {
    private static func row(_ id: String, price: Int,
                            status: Catalog.Status = .active) -> Catalog.Row {
        Catalog.Row(ownerID: "sam", status: status, listing: Listing(
            id: id, title: "Fixture \(id)", description: "Sort fixture", priceCents: price,
            condition: "Good", category: "Textbooks", sellerDisplayName: "Sam",
            pickupArea: "Campus", photoURLs: []))
    }

    /// Declaration order is the newest-first order; the two 2500 rows force the id tie break.
    private static let seeds: [Catalog.Row] = [
        row("mid", price: 1000),
        row("tie-b", price: 2500),
        row("tie-a", price: 2500),
        row("low", price: 900),
        row("gone", price: 500, status: .sold)
    ]

    private func ids(_ app: Application, _ path: String) async throws -> [String] {
        let response = try await app.testing().sendRequest(.GET, "api/v1/listings\(path)")
        try #require(response.status == .ok, "\(path) returned \(response.status)")
        return try response.content.decode([Listing].self).map(\.id)
    }

    @Test func newestIsTheDefaultAndPriceOrdersBreakTiesOnTheID() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: Self.seeds)
        }) { app in
            let newest = try await ids(app, "")
            #expect(newest == ["mid", "tie-b", "tie-a", "low"])
            let explicitNewest = try await ids(app, "?sort=newest")
            #expect(explicitNewest == newest)

            let ascending = try await ids(app, "?sort=price_asc")
            #expect(ascending == ["low", "mid", "tie-a", "tie-b"])

            let descending = try await ids(app, "?sort=price_desc")
            #expect(descending == ["tie-b", "tie-a", "mid", "low"])

            // Inactive rows never sort into the feed.
            #expect(!ascending.contains("gone"))
        }
    }

    @Test func sortingCombinesWithKeywordFiltersAndPagination() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: Self.seeds)
        }) { app in
            let keyword = try await ids(app, "?q=fixture&sort=price_asc")
            #expect(keyword == ["low", "mid", "tie-a", "tie-b"])

            let filtered = try await ids(app, "?condition=Good&minPriceCents=900&maxPriceCents=2500&sort=price_desc")
            #expect(filtered == ["tie-b", "tie-a", "mid", "low"])

            // Pages must follow the same order, not the default one.
            let first = try await app.testing().sendRequest(.GET, "api/v1/listings?sort=price_asc&per=2")
            #expect(first.headers.first(name: "X-Has-More") == "true")
            let firstIDs = try first.content.decode([Listing].self).map(\.id)
            #expect(firstIDs == ["low", "mid"])

            let second = try await app.testing().sendRequest(.GET, "api/v1/listings?sort=price_asc&per=2&page=2")
            #expect(second.headers.first(name: "X-Has-More") == "false")
            let secondIDs = try second.content.decode([Listing].self).map(\.id)
            #expect(secondIDs == ["tie-a", "tie-b"])

            let empty = try await app.testing().sendRequest(.GET, "api/v1/listings?q=nothing&sort=price_desc")
            #expect(try empty.content.decode([Listing].self).isEmpty)
        }
    }

    @Test func unknownSortIsRejectedWithAFieldError() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: Self.seeds)
        }) { app in
            for value in ["oldest", "price", "asc", "1"] {
                let response = try await app.testing().sendRequest(.GET, "api/v1/listings?sort=\(value)")
                #expect(response.status == .unprocessableEntity, "sort=\(value) was accepted")
                let body = try response.content.decode(FieldErrorBody.self)
                #expect(body.fieldErrors["sort"] != nil)
            }
        }
    }
}
