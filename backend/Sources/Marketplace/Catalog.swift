import Vapor

struct Listing: Content {
    let id, title, description: String
    let priceCents: Int
    let condition, category, sellerDisplayName, pickupArea: String
    let photoURLs: [String] // Primary photo first; never include storage credentials.
}

struct Catalog: Sendable {
    enum Status: String, Codable, Sendable { case active, sold, reserved, deleted }
    struct Row: Sendable {
        let ownerID: String
        let status: Status
        let listing: Listing
    }
    private let rows: [Row]

    init(rows: [Row]? = nil) {
        self.rows = rows ?? Self.samples
    }

    private static let samples: [Row] = zip(["sam", "avery", "jo"], sampleListings).map {
        Row(ownerID: $0.0, status: $0.1.0, listing: $0.1.1)
    }
    private static let sampleListings: [(Status, Listing)] = [
        (.active, Listing(id: "desk-lamp", title: "Gooseneck desk lamp", description: "Warm light with a clamp base. Fits a dorm desk.", priceCents: 1200, condition: "Good", category: "Dorm essentials", sellerDisplayName: "Sam", pickupArea: "Daisy Hill", photoURLs: [])),
        (.active, Listing(id: "calculus", title: "Calculus textbook", description: "Used hardcover with a few penciled notes.", priceCents: 2500, condition: "Fair", category: "Books", sellerDisplayName: "Avery", pickupArea: "Wescoe Beach", photoURLs: [])),
        (.sold, Listing(id: "bike", title: "Campus bike", description: "Single speed commuter.", priceCents: 9000, condition: "Good", category: "Transportation", sellerDisplayName: "Jo", pickupArea: "Kansas Union", photoURLs: []))
    ]
    func search(_ query: String) -> [Listing] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.compactMap { row in
            guard row.status == .active else { return nil }
            let item = row.listing
            return term.isEmpty || item.title.lowercased().contains(term) || item.description.lowercased().contains(term) ? item : nil
        }
    }
    func active(_ id: String) -> Listing? {
        rows.first { $0.status == .active && $0.listing.id == id }?.listing
    }

    func owned(by ownerID: String) -> [OwnedListing] {
        rows.filter { $0.ownerID == ownerID && $0.status != .deleted }
            .map { OwnedListing(status: $0.status, listing: $0.listing) }
    }
}

struct OwnedListing: Content {
    let status: Catalog.Status
    let listing: Listing
}
