import Foundation
import Vapor

struct Listing: Content {
    let id, title, description: String
    let priceCents: Int
    let condition, category, sellerDisplayName, pickupArea: String
    let photoURLs: [String] // Primary photo first; never include storage credentials.
}

/// One process-wide listing store shared by the read feed, owned listings, and
/// the publish endpoint, so a created listing is discoverable immediately.
/// ponytail: in-memory and lost on restart; move the rows into a Fluent model when
/// the accounts feature brings a database. Method signatures stay the same.
final class Catalog: @unchecked Sendable {
    enum Status: String, Codable, Sendable { case active, sold, reserved, deleted }
    struct Row: Sendable {
        let ownerID: String
        let status: Status
        let listing: Listing
    }

    private let lock = NSLock()
    private var rows: [Row]

    init(rows: [Row]? = nil) {
        self.rows = rows ?? Self.samples
    }

    /// Active listings only, newest first. A blank query means every active item.
    func search(_ query: String) -> [Listing] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshot().compactMap { row in
            guard row.status == .active else { return nil }
            let item = row.listing
            return term.isEmpty || item.title.lowercased().contains(term) || item.description.lowercased().contains(term) ? item : nil
        }
    }

    func active(_ id: String) -> Listing? {
        snapshot().first { $0.status == .active && $0.listing.id == id }?.listing
    }

    func owned(by ownerID: String) -> [OwnedListing] {
        snapshot().filter { $0.ownerID == ownerID && $0.status != .deleted }
            .map { OwnedListing(status: $0.status, listing: $0.listing) }
    }

    /// Only the publish route calls this: after validation, with seller fields
    /// taken from the authenticated account. Newest listings surface first.
    func add(_ listing: Listing, ownerID: String) {
        lock.lock()
        defer { lock.unlock() }
        rows.insert(Row(ownerID: ownerID, status: .active, listing: listing), at: 0)
    }

    private func snapshot() -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    private static let samples: [Row] = zip(["sam", "avery", "jo"], sampleListings).map {
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
