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

    /// Active listings only, newest first. Filtering and pagination happen in the database.
    func search(_ query: String) async throws -> [Listing] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var request = ListingRecord.query(on: database)
            .filter(\.$status == Status.active.rawValue)
        if !term.isEmpty {
            request = request.group(.or) { group in
                group.filter(\.$title ~~ term).filter(\.$description ~~ term)
            }
        }
        return try await request.sort(\.$id, .descending).all().map(\.listing)
    }

    struct SearchPage: Sendable {
        let items: [Listing]
        let page: Int
        let per: Int
        let hasMore: Bool
    }

    func search(_ query: String, page: Int, per: Int) async throws -> SearchPage {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safePage = max(page, 1)
        let safePer = min(max(per, 1), 50)
        let offset = (safePage - 1) * safePer
        var request = ListingRecord.query(on: database)
            .filter(\.$status == Status.active.rawValue)
        if !term.isEmpty {
            request = request.group(.or) { group in
                group.filter(\.$title ~~ term).filter(\.$description ~~ term)
            }
        }
        let records = try await request
            .sort(\.$id, .descending)
            .range(offset..<(offset + safePer + 1))
            .all()
        let hasMore = records.count > safePer
        return SearchPage(items: records.prefix(safePer).map(\.listing), page: safePage, per: safePer, hasMore: hasMore)
    }

    func active(_ id: String) async throws -> Listing? {
        try await ListingRecord.query(on: database).filter(\.$listingID == id)
            .filter(\.$status == Status.active.rawValue).first()?.listing
    }

    func owned(by ownerID: String) async throws -> [OwnedListing] {
        let records = try await ListingRecord.query(on: database).filter(\.$ownerID == ownerID)
            .filter(\.$status != Status.deleted.rawValue).sort(\.$id, .descending).all()
        return try records.map { try ownedListing(from: $0) }
    }

    /// Returns one non-deleted listing the caller owns.
    func owned(listingID: String, by ownerID: String) async throws -> OwnedListing? {
        guard let record = try await ListingRecord.query(on: database)
            .filter(\.$listingID == listingID).filter(\.$ownerID == ownerID)
            .filter(\.$status != Status.deleted.rawValue).first() else { return nil }
        return try ownedListing(from: record)
    }

    private func ownedListing(from record: ListingRecord) throws -> OwnedListing {
        guard let status = Status(rawValue: record.status) else {
            throw Abort(.internalServerError, reason: "Stored listing status is invalid.")
        }
        return OwnedListing(status: status, listing: record.listing, revision: record.revision ?? "initial")
    }

    /// Only the publish route calls this: after validation, with seller fields
    /// taken from the authenticated account. Newest listings surface first.
    func add(_ listing: Listing, ownerID: String) async throws {
        try await ListingRecord(row: Row(ownerID: ownerID, status: .active, listing: listing)).create(on: database)
    }

    /// Take SQLite's write lock before checking the version so simultaneous saves
    /// cannot both accept the same revision. Only editable fields are written.
    func edit(_ draft: ListingDraft, listingID: String, ownerID: String, revision: String) async throws -> OwnedListing {
        try await database.transaction { db in
            try await ListingRecord.query(on: db).filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID).filter(\.$status == Status.active.rawValue)
                .set(\.$status, to: Status.active.rawValue).update()
            guard let record = try await ListingRecord.query(on: db).filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID).first(), record.status != Status.deleted.rawValue else {
                throw Abort(.notFound, reason: "This listing is unavailable.")
            }
            guard record.status == Status.active.rawValue else {
                throw Abort(.conflict, reason: "This listing is no longer active. Reload to see its current status.")
            }
            guard revision == (record.revision ?? "initial") else {
                throw Abort(.conflict, reason: "This listing has changed. Reload before editing again.")
            }
            record.title = draft.title
            record.description = draft.description
            record.priceCents = draft.priceCents
            record.category = draft.category
            record.condition = draft.condition
            let nextRevision = UUID().uuidString
            record.revision = nextRevision
            try await record.update(on: db)
            return OwnedListing(status: .active, listing: record.listing, revision: nextRevision)
        }
    }

    /// Status changes serialize with edits and photo uploads. Repeating the same
    /// action is safe after a lost response; a stale different action must reload.
    func changeStatus(_ target: Status, listingID: String, ownerID: String, revision: String) async throws -> OwnedListing {
        guard target == .sold || target == .deleted else { throw Abort(.badRequest) }
        return try await database.transaction { db in
            try await ListingRecord.query(on: db).filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID).set(\.$ownerID, to: ownerID).update()
            guard let record = try await ListingRecord.query(on: db).filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID).first() else {
                throw Abort(.notFound, reason: "This listing is unavailable.")
            }
            if record.status == target.rawValue {
                return OwnedListing(status: target, listing: record.listing, revision: record.revision ?? "initial")
            }
            guard record.status != Status.deleted.rawValue else { throw Abort(.notFound, reason: "This listing is unavailable.") }
            guard revision == (record.revision ?? "initial") else {
                throw Abort(.conflict, reason: "This listing has changed. Reload your listings before trying again.")
            }
            guard target == .deleted || record.status == Status.active.rawValue || record.status == Status.reserved.rawValue else {
                throw Abort(.conflict, reason: "This listing cannot be marked sold. Reload your listings.")
            }
            let nextRevision = UUID().uuidString
            record.status = target.rawValue
            record.revision = nextRevision
            try await record.update(on: db)
            return OwnedListing(status: target, listing: record.listing, revision: nextRevision)
        }
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
    let revision: String
}
