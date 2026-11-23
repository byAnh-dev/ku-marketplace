@testable import Marketplace
import Foundation
import Testing
import VaporTesting

/// Requirement 31: the posting date is public and stable, while edits and status
/// changes only move the owner-visible last-edited stamp.
@Suite struct ListingDateTests {
    private let password = "Listing-dates-password-2026"

    private func account(_ app: Application, email: String) async throws -> String {
        let account = Account(displayName: "Date Owner", email: email,
                              passwordHash: try await app.password.async.hash(password))
        account.verified = true
        try await account.create(on: app.db)
        let login = try await app.testing().sendRequest(.POST, "api/v1/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: email, password: password))
        })
        try #require(login.status == .ok)
        return try login.content.decode(LoginResponse.self).token
    }

    private func publish(_ app: Application, token: String) async throws -> Listing {
        let response = try await app.testing().sendRequest(.POST, "api/v1/listings", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateListingBody(
                title: "Dated listing", description: "Has a posting date.",
                priceCents: 1500, category: "Textbooks", condition: "Good", pickupArea: nil))
        })
        try #require(response.status == .created)
        return try response.content.decode(Listing.self)
    }

    private func owned(_ app: Application, id: String, token: String) async throws -> OwnedListing {
        let response = try await app.testing().sendRequest(.GET, "api/v1/me/listings/\(id)",
                                                          headers: ["Authorization": "Bearer \(token)"])
        try #require(response.status == .ok)
        return try response.content.decode(OwnedListing.self)
    }

    private func edit(_ app: Application, id: String, token: String, revision: String,
                      title: String) async throws -> TestingHTTPResponse {
        try await app.testing().sendRequest(.PATCH, "api/v1/listings/\(id)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.headers.add(name: .ifMatch, value: revision)
            try req.content.encode(CreateListingBody(
                title: title, description: "Still the same listing.",
                priceCents: 1500, category: "Textbooks", condition: "Good", pickupArea: nil))
        })
    }

    @Test func publishedListingCarriesAParsablePostingDate() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: [])
        }) { app in
            let token = try await account(app, email: "dates@ku.edu")
            let listing = try await publish(app, token: token)
            let postedAt = try #require(listing.postedAt)
            #expect(ISO8601DateFormatter().date(from: postedAt) != nil)

            // The public feed and details route expose the same value.
            let feed = try await app.testing().sendRequest(.GET, "api/v1/listings")
            let fromFeed = try #require(try feed.content.decode([Listing].self).first)
            #expect(fromFeed.postedAt == postedAt)

            let detail = try await app.testing().sendRequest(.GET, "api/v1/listings/\(listing.id)")
            #expect(try detail.content.decode(Listing.self).postedAt == postedAt)

            // A brand new listing has never been edited.
            let fresh = try await owned(app, id: listing.id, token: token)
            #expect(fresh.editedAt == nil)
        }
    }

    @Test func editingKeepsThePostingDateAndStampsTheEdit() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: [])
        }) { app in
            let token = try await account(app, email: "editor@ku.edu")
            let listing = try await publish(app, token: token)
            let postedAt = try #require(listing.postedAt)
            let before = try await owned(app, id: listing.id, token: token)

            let edited = try await edit(app, id: listing.id, token: token, revision: before.revision,
                                        title: "Dated listing, renamed")
            #expect(edited.status == .ok)
            let updated = try edited.content.decode(OwnedListing.self)

            #expect(updated.listing.postedAt == postedAt, "editing moved the posting date")
            #expect(updated.listing.title == "Dated listing, renamed")
            let editedAt = try #require(updated.editedAt)
            #expect(ISO8601DateFormatter().date(from: editedAt) != nil)
            #expect(updated.revision != before.revision)

            // Re-reading the owner view returns the same pair of timestamps.
            let reread = try await owned(app, id: listing.id, token: token)
            #expect(reread.listing.postedAt == postedAt)
            #expect(reread.editedAt == editedAt)
        }
    }

    @Test func markingSoldKeepsThePostingDateAndReportsSoldToTheOwner() async throws {
        try await withApp(configure: { app in
            _ = try await configureApplication(app, seedListings: [])
        }) { app in
            let token = try await account(app, email: "seller@ku.edu")
            let listing = try await publish(app, token: token)
            let postedAt = try #require(listing.postedAt)
            let before = try await owned(app, id: listing.id, token: token)

            let sold = try await app.testing().sendRequest(.POST, "api/v1/listings/\(listing.id)/sold", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.add(name: .ifMatch, value: before.revision)
            })
            try #require(sold.status == .ok)
            let result = try sold.content.decode(OwnedListing.self)

            #expect(result.status == .sold)
            #expect(result.listing.postedAt == postedAt)
            #expect(result.editedAt != nil)

            // Sold rows leave the public feed but stay in the owner view.
            let feed = try await app.testing().sendRequest(.GET, "api/v1/listings")
            #expect(try feed.content.decode([Listing].self).isEmpty)
            let mine = try await app.testing().sendRequest(.GET, "api/v1/me/listings",
                                                          headers: ["Authorization": "Bearer \(token)"])
            let entries = try mine.content.decode([OwnedListing].self)
            #expect(entries.map { $0.status } == [.sold])
            #expect(entries.first?.listing.postedAt == postedAt)
        }
    }
}
