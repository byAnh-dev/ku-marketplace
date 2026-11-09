import Foundation
import Fluent
import Vapor

struct Listing: Content {
    let id, title, description: String
    let priceCents: Int
    let condition, category, sellerDisplayName, pickupArea: String
    let photoURLs: [String] // Primary photo first; never include storage credentials.
}

/// All listing routes read the same database, including after an application restart.
struct Catalog: Sendable {
    enum Status: String, Codable, Sendable { case active, sold, reserved, deleted }
    struct Row: Sendable {
        let ownerID: String
        let status: Status
        let listing: Listing
    }

    let database: any Database

    /// Active listings only, newest first. A blank query means every active item.
    func search(_ query: String) async throws -> [Listing] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let records = try await ListingRecord.query(on: database)
            .filter(\.$status == Status.active.rawValue).sort(\.$id, .descending).all()
        // Preserve Swift's existing Unicode case folding and literal substring search.
        return records.compactMap { record in
            let item = record.listing
            return term.isEmpty || item.title.lowercased().contains(term) || item.description.lowercased().contains(term) ? item : nil
        }
    }

    func active(_ id: String) async throws -> Listing? {
        try await ListingRecord.query(on: database).filter(\.$listingID == id)
            .filter(\.$status == Status.active.rawValue).first()?.listing
    }

    func owned(by ownerID: String) async throws -> [OwnedListing] {
        let records = try await ListingRecord.query(on: database).filter(\.$ownerID == ownerID)
            .filter(\.$status != Status.deleted.rawValue).sort(\.$id, .descending).all()
        return try records.map { record in
            guard let status = Status(rawValue: record.status) else {
                throw Abort(.internalServerError, reason: "Stored listing status is invalid.")
            }
            return OwnedListing(status: status, listing: record.listing)
        }
    }

    /// Only the publish route calls this: after validation, with seller fields
    /// taken from the authenticated account. Newest listings surface first.
    func add(_ listing: Listing, ownerID: String) async throws {
        try await ListingRecord(row: Row(ownerID: ownerID, status: .active, listing: listing)).create(on: database)
    }

    /// Replaces the photo set of an active listing the caller owns. `urls` must
    /// already be in display order: the first one is the primary photo.
    /// Returns the displaced URLs only after the transaction commits, for safe file cleanup.
    /// Returns nil when the listing is missing, not active, or owned by someone else.
    func replacePhotos(_ urls: [String], listingID: String, ownerID: String) async throws -> (listing: Listing, previousPhotoURLs: [String])? {
        try await database.transaction { db in
            // The first statement obtains SQLite's write lock before reading the old
            // URLs. A deferred read-then-write transaction can otherwise fail to upgrade
            // its lock or read a version another uploader is about to replace.
            try await ListingRecord.query(on: db).filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID).filter(\.$status == Status.active.rawValue)
                .set(\.$status, to: Status.active.rawValue).update()
            guard let record = try await ListingRecord.query(on: db).filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID).filter(\.$status == Status.active.rawValue).first() else { return nil }
            let previous = record.photoURLs
            record.photoURLs = urls
            try await record.update(on: db)
            return (record.listing, previous)
        }
    }

    static let samples: [Row] = zip(["sam", "avery", "jo"], sampleListings).map {
        Row(ownerID: $0.0, status: $0.1.0, listing: $0.1.1)
    }
    private static let sampleListings: [(Status, Listing)] = [
        (.active, Listing(id: "desk-lamp", title: "Gooseneck desk lamp", description: "Warm light with a clamp base. Fits a dorm desk.", priceCents: 1200, condition: "Good", category: "Dorm essentials", sellerDisplayName: "Sam", pickupArea: "Daisy Hill", photoURLs: [])),
        (.active, Listing(id: "calculus", title: "Calculus textbook", description: "Used hardcover with a few penciled notes.", priceCents: 2500, condition: "Fair", category: "Books", sellerDisplayName: "Avery", pickupArea: "Wescoe Beach", photoURLs: [])),
        (.sold, Listing(id: "bike", title: "Campus bike", description: "Single speed commuter.", priceCents: 9000, condition: "Good", category: "Transportation", sellerDisplayName: "Jo", pickupArea: "Kansas Union", photoURLs: []))
    ]
}

struct OwnedListing: Content {
    let status: Catalog.Status
    let listing: Listing
}
