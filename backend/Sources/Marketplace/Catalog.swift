
import Foundation
import Fluent
import FluentSQL
import Vapor

struct Listing: Content {
    let id, title, description: String
    let priceCents: Int
    let condition, category, sellerDisplayName, pickupArea: String
    let photoURLs: [String] // Primary photo first; never include storage credentials.
    /// Posting time in UTC, ISO 8601. Editing a listing never changes it.
    var postedAt: String? = nil
}

struct Catalog: Sendable {
    enum Status: String, Codable, Sendable {
        case active, sold, reserved, deleted
    }

    struct Row: Sendable {
        let ownerID: String
        let status: Status
        let listing: Listing
    }

    let database: any Database

    /// One query builder carries the active-only rule, the keyword match and the
    /// filters, so the paginated feed and the unpaged lookup cannot drift apart.
    private func matches(
        _ term: String,
        _ filters: ListingFilters
    ) -> QueryBuilder<ListingRecord> {
        var request = ListingRecord.query(on: database)
            .filter(\.$status == Status.active.rawValue)

        if !term.isEmpty {
            request = request.group(.or) { group in
                group.filter(\.$title ~~ term)
                    .filter(\.$description ~~ term)
            }
        }

        if let category = filters.category {
            request = request.filter(\.$category == category)
        }
        if let condition = filters.condition {
            request = request.filter(\.$condition == condition)
        }
        if let minimum = filters.minPriceCents {
            request = request.filter(\.$priceCents >= minimum)
        }
        if let maximum = filters.maxPriceCents {
            request = request.filter(\.$priceCents <= maximum)
        }
        return request
    }

    /// Feed ordering. Prices compare numerically; the listing id breaks ties so
    /// pages stay stable when many rows share a price.
    enum Sort: String, Sendable, CaseIterable {
        case newest
        case priceAscending = "price_asc"
        case priceDescending = "price_desc"

        init?(queryValue: String) {
            switch queryValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "", "newest": self = .newest
            case "price_asc": self = .priceAscending
            case "price_desc": self = .priceDescending
            default: return nil
            }
        }
    }

    private func ordered(
        _ request: QueryBuilder<ListingRecord>,
        by sort: Sort
    ) -> QueryBuilder<ListingRecord> {
        switch sort {
        case .newest:
            return request
                .sort(\.$id, .descending)
                .sort(\.$listingID, .descending)
        case .priceAscending:
            return request
                .sort(\.$priceCents, .ascending)
                .sort(\.$listingID, .ascending)
        case .priceDescending:
            return request
                .sort(\.$priceCents, .descending)
                .sort(\.$listingID, .descending)
        }
    }

    /// Active listings only, newest first. Filtering and pagination happen in the database.
    func search(
        _ query: String,
        filters: ListingFilters = .none,
        sort: Sort = .newest
    ) async throws -> [Listing] {
        let term = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()

        return try await ordered(matches(term, filters), by: sort)
            .all()
            .map(\.listing)
    }

    struct SearchPage: Sendable {
        let items: [Listing]
        let page: Int
        let per: Int
        let hasMore: Bool
    }

    func search(
        _ query: String,
        page: Int,
        per: Int,
        filters: ListingFilters = .none,
        sort: Sort = .newest
    ) async throws -> SearchPage {
        let term = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()

        let safePage = max(page, 1)
        let safePer = min(max(per, 1), 50)
        let offset = (safePage - 1) * safePer

        let records = try await ordered(matches(term, filters), by: sort)
            .range(offset..<(offset + safePer + 1))
            .all()

        return SearchPage(
            items: records.prefix(safePer).map(\.listing),
            page: safePage,
            per: safePer,
            hasMore: records.count > safePer
        )
    }

    func active(_ id: String) async throws -> Listing? {
        try await ListingRecord.query(on: database)
            .filter(\.$listingID == id)
            .filter(\.$status == Status.active.rawValue)
            .first()?.listing
    }

    func owned(by ownerID: String) async throws -> [OwnedListing] {
        let records = try await ListingRecord.query(on: database)
            .filter(\.$ownerID == ownerID)
            .filter(\.$status != Status.deleted.rawValue)
            .sort(\.$id, .descending)
            .all()

        return try records.map {
            try ownedListing(from: $0)
        }
    }

    func owned(
        listingID: String,
        by ownerID: String
    ) async throws -> OwnedListing? {
        guard let record = try await ListingRecord.query(on: database)
            .filter(\.$listingID == listingID)
            .filter(\.$ownerID == ownerID)
            .filter(\.$status != Status.deleted.rawValue)
            .first()
        else {
            return nil
        }

        return try ownedListing(from: record)
    }

    private func ownedListing(
        from record: ListingRecord
    ) throws -> OwnedListing {
        guard let status = Status(rawValue: record.status) else {
            throw Abort(
                .internalServerError,
                reason: "Stored listing status is invalid."
            )
        }

        return OwnedListing(
            status: status,
            listing: record.listing,
            revision: record.revision ?? "initial",
            editedAt: record.editedAt
        )
    }

    // Five new listings per rolling ten minutes.
    // A transaction serializes the quota check with the insert.
    func add(_ listing: Listing, ownerID: String) async throws {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else {
                throw Abort(.internalServerError)
            }

            // Obtain SQLite's writer lock before counting.
            try await sql.raw(
                "UPDATE listings SET status = status WHERE 0"
            ).run()

            let now = Date()
            let cutoff = now.addingTimeInterval(-600)

            let recent = try await ListingRecord.query(on: db)
                .filter(\.$ownerID == ownerID)
                .filter(\.$createdAt > cutoff)
                .filter(\.$createdAt <= now)
                .sort(\.$createdAt, .ascending)
                .range(0..<5)
                .all()

            if recent.count >= 5,
               let oldest = recent.first {
                let seconds = max(
                    1,
                    Int(ceil(
                        oldest.createdAt
                            .addingTimeInterval(600)
                            .timeIntervalSince(now)
                    ))
                )

                throw Abort(
                    .tooManyRequests,
                    headers: [
                        "Retry-After": String(seconds)
                    ],
                    reason: "Maximum five listings per ten minutes. Try again in \(seconds) seconds."
                )
            }

            let record = ListingRecord(
                row: Row(
                    ownerID: ownerID,
                    status: .active,
                    listing: listing
                )
            )

            try await record.create(on: db)
        }
    }

    func edit(
        _ draft: ListingDraft,
        listingID: String,
        ownerID: String,
        revision: String
    ) async throws -> OwnedListing {
        try await database.transaction { db in
            try await ListingRecord.query(on: db)
                .filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID)
                .filter(\.$status == Status.active.rawValue)
                .set(\.$status, to: Status.active.rawValue)
                .update()

            guard let record = try await ListingRecord.query(on: db)
                .filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID)
                .first(),
                  record.status != Status.deleted.rawValue
            else {
                throw Abort(
                    .notFound,
                    reason: "This listing is unavailable."
                )
            }

            guard record.status == Status.active.rawValue else {
                throw Abort(
                    .conflict,
                    reason: "This listing is no longer active. Reload to see its current status."
                )
            }

            guard revision == (record.revision ?? "initial") else {
                throw Abort(
                    .conflict,
                    reason: "This listing has changed. Reload before editing again."
                )
            }

            record.title = draft.title
            record.description = draft.description
            record.priceCents = draft.priceCents
            record.category = draft.category
            record.condition = draft.condition

            let nextRevision = UUID().uuidString
            record.revision = nextRevision
            record.updatedAt = Date()

            try await record.update(on: db)

            return OwnedListing(
                status: .active,
                listing: record.listing,
                revision: nextRevision,
                editedAt: record.editedAt
            )
        }
    }

    func changeStatus(
        _ target: Status,
        listingID: String,
        ownerID: String,
        revision: String
    ) async throws -> OwnedListing {
        guard target == .sold || target == .deleted else {
            throw Abort(.badRequest)
        }

        return try await database.transaction { db in
            try await ListingRecord.query(on: db)
                .filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID)
                .set(\.$ownerID, to: ownerID)
                .update()

            guard let record = try await ListingRecord.query(on: db)
                .filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID)
                .first()
            else {
                throw Abort(
                    .notFound,
                    reason: "This listing is unavailable."
                )
            }

            if record.status == target.rawValue {
                return OwnedListing(
                    status: target,
                    listing: record.listing,
                    revision: record.revision ?? "initial",
                    editedAt: record.editedAt
                )
            }

            guard record.status != Status.deleted.rawValue else {
                throw Abort(
                    .notFound,
                    reason: "This listing is unavailable."
                )
            }

            guard revision == (record.revision ?? "initial") else {
                throw Abort(
                    .conflict,
                    reason: "This listing has changed. Reload your listings before trying again."
                )
            }

            guard target == .deleted ||
                record.status == Status.active.rawValue ||
                record.status == Status.reserved.rawValue
            else {
                throw Abort(
                    .conflict,
                    reason: "This listing cannot be marked sold. Reload your listings."
                )
            }

            let nextRevision = UUID().uuidString

            record.status = target.rawValue
            record.revision = nextRevision
            record.updatedAt = Date()

            try await record.update(on: db)

            return OwnedListing(
                status: target,
                listing: record.listing,
                revision: nextRevision,
                editedAt: record.editedAt
            )
        }
    }

    func replacePhotos(
        _ urls: [String],
        listingID: String,
        ownerID: String
    ) async throws -> (
        listing: Listing,
        previousPhotoURLs: [String]
    )? {
        try await database.transaction { db in
            try await ListingRecord.query(on: db)
                .filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID)
                .filter(\.$status == Status.active.rawValue)
                .set(\.$status, to: Status.active.rawValue)
                .update()

            guard let record = try await ListingRecord.query(on: db)
                .filter(\.$listingID == listingID)
                .filter(\.$ownerID == ownerID)
                .filter(\.$status == Status.active.rawValue)
                .first()
            else {
                return nil
            }

            let previous = record.photoURLs
            record.photoURLs = urls

            try await record.update(on: db)

            return (record.listing, previous)
        }
    }

    static let samples: [Row] = zip(
        ["sam", "avery", "jo"],
        sampleListings
    ).map {
        Row(
            ownerID: $0.0,
            status: $0.1.0,
            listing: $0.1.1
        )
    }

    private static let sampleListings: [(Status, Listing)] = [
        (
            .active,
            Listing(
                id: "desk-lamp",
                title: "Gooseneck desk lamp",
                description: "Warm light with a clamp base. Fits a dorm desk.",
                priceCents: 1200,
                condition: "Good",
                category: "Dorm essentials",
                sellerDisplayName: "Sam",
                pickupArea: "Daisy Hill",
                photoURLs: []
            )
        ),
        (
            .active,
            Listing(
                id: "calculus",
                title: "Calculus textbook",
                description: "Used hardcover with a few penciled notes.",
                priceCents: 2500,
                condition: "Fair",
                category: "Books",
                sellerDisplayName: "Avery",
                pickupArea: "Wescoe Beach",
                photoURLs: []
            )
        ),
        (
            .sold,
            Listing(
                id: "bike",
                title: "Campus bike",
                description: "Single speed commuter.",
                priceCents: 9000,
                condition: "Good",
                category: "Transportation",
                sellerDisplayName: "Jo",
                pickupArea: "Kansas Union",
                photoURLs: []
            )
        )
    ]
}

struct OwnedListing: Content {
    let status: Catalog.Status
    let listing: Listing
    let revision: String
    /// Last time the owner changed this listing; nil until the first change.
    var editedAt: String? = nil
}
