@testable import Marketplace
import Foundation
import Testing
import VaporTesting

/// Requirement 8: filters combine with the keyword, return active items only,
/// include both price boundaries, and reject a bad range instead of guessing.
@Suite struct FilterTests {
    private static func row(_ id: String, title: String = "Filter fixture", price: Int, category: String,
                     condition: String, status: Catalog.Status = .active) -> Catalog.Row {
        Catalog.Row(ownerID: "sam", status: status, listing: Listing(
            id: id, title: title, description: "Filter fixture description", priceCents: price,
            condition: condition, category: category, sellerDisplayName: "Sam",
            pickupArea: "Campus", photoURLs: []))
    }

    private static let seeds: [Catalog.Row] = [
        Self.row("book-10", title: "Calculus textbook", price: 1000, category: "Textbooks", condition: "Good"),
        Self.row("book-20", title: "Physics textbook", price: 2000, category: "Textbooks", condition: "Good"),
        Self.row("book-25", title: "Chemistry textbook", price: 2500, category: "Textbooks", condition: "Good"),
        Self.row("book-fair", title: "History textbook", price: 1500, category: "Textbooks", condition: "Fair"),
        Self.row("lamp-30", title: "Desk lamp", price: 3000, category: "Dorm & Living", condition: "Good"),
        Self.row("book-sold", title: "Sold textbook", price: 1500, category: "Textbooks", condition: "Good", status: .sold),
        Self.row("book-reserved", title: "Reserved textbook", price: 1500, category: "Textbooks", condition: "Good", status: .reserved),
        Self.row("book-deleted", title: "Deleted textbook", price: 1500, category: "Textbooks", condition: "Good", status: .deleted)
    ]

    /// Seeded rows keep their declaration order in the feed, newest-first by sequence.
    private func feed(_ app: Application, _ path: String) async throws -> [String] {
        let response = try await app.testing().sendRequest(.GET, "api/v1/listings\(path)")
        try #require(response.status == .ok, "\(path) returned \(response.status)")
        return try response.content.decode([Listing].self).map(\.id)
    }

    @Test func categoryConditionAndInclusivePriceBounds() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: Self.seeds)
        }) { app in
            // Both boundaries included; other conditions, categories, and inactive rows excluded.
            let bounded = try await feed(app, "?category=Textbooks&condition=Good&minPriceCents=1000&maxPriceCents=2000")
            #expect(bounded == ["book-10", "book-20"])

            let fair = try await feed(app, "?condition=Fair")
            #expect(fair == ["book-fair"])

            let dorm = try await feed(app, "?category=Dorm%20%26%20Living")
            #expect(dorm == ["lamp-30"])

            // An exact category match must not leak into a similar label.
            let similar = try await feed(app, "?category=Book")
            #expect(similar.isEmpty)
        }
    }

    @Test func filtersCombineWithKeywordAndPagination() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: Self.seeds)
        }) { app in
            let physics = try await feed(app, "?q=physics&category=Textbooks&condition=Good")
            #expect(physics == ["book-20"])

            let textbooks = try await feed(app, "?q=textbook&condition=Good&minPriceCents=1000")
            #expect(textbooks == ["book-10", "book-20", "book-25"])

            let first = try await app.testing().sendRequest(.GET, "api/v1/listings?category=Textbooks&per=2")
            #expect(first.headers.first(name: "X-Page") == "1")
            #expect(first.headers.first(name: "X-Page-Size") == "2")
            #expect(first.headers.first(name: "X-Has-More") == "true")
            let firstIDs = try first.content.decode([Listing].self).map(\.id)
            #expect(firstIDs == ["book-10", "book-20"])

            let second = try await app.testing().sendRequest(.GET, "api/v1/listings?category=Textbooks&per=2&page=2")
            #expect(second.headers.first(name: "X-Has-More") == "false")
            let secondIDs = try second.content.decode([Listing].self).map(\.id)
            #expect(secondIDs == ["book-25", "book-fair"])
        }
    }

    @Test func invalidFiltersAreRejectedWithFieldErrors() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: Self.seeds)
        }) { app in
            for (path, field) in [
                ("?minPriceCents=2000&maxPriceCents=1000", "minPriceCents"),
                ("?minPriceCents=abc", "minPriceCents"),
                ("?maxPriceCents=-5", "maxPriceCents"),
                ("?condition=Mint", "condition")
            ] {
                let response = try await app.testing().sendRequest(.GET, "api/v1/listings\(path)")
                #expect(response.status == .unprocessableEntity, "\(path) was accepted")
                let body = try response.content.decode(FieldErrorBody.self)
                #expect(body.fieldErrors[field] != nil, "\(path) did not report \(field)")
            }

            // Several independent mistakes come back together so the panel can mark both inputs.
            let combined = try await app.testing().sendRequest(.GET, "api/v1/listings?minPriceCents=abc&condition=Mint")
            let combinedBody = try combined.content.decode(FieldErrorBody.self)
            #expect(Set(combinedBody.fieldErrors.keys) == ["minPriceCents", "condition"])

            let unknownCondition = try await app.testing().sendRequest(.GET, "api/v1/listings?condition=Mint")
            let unknownBody = try unknownCondition.content.decode(FieldErrorBody.self)
            #expect(Set(unknownBody.fieldErrors.keys) == ["condition"])
        }
    }

    @Test func conditionFilterIgnoresCaseAndBlankValuesAreIgnored() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: Self.seeds)
        }) { app in
            let mixedCase = try await feed(app, "?condition=gOoD&category=%20Textbooks%20")
            #expect(mixedCase == ["book-10", "book-20", "book-25"])

            let blank = try await feed(app, "?category=&condition=&minPriceCents=&maxPriceCents=")
            #expect(blank == ["book-10", "book-20", "book-25", "book-fair", "lamp-30"])
        }
    }
}
