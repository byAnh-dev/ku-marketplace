import Vapor

struct Listing: Content {
    let id, title, description: String
    let priceCents: Int
    let condition, category, sellerDisplayName, pickupArea: String
    let photoURLs: [String] // Primary photo first; never include storage credentials.
}

struct Catalog: Sendable {
    enum Status { case active, sold, reserved, deleted }
    private let rows: [(Status, Listing)] = [
        (.active, Listing(id: "desk-lamp", title: "Gooseneck desk lamp", description: "Warm light with a clamp base. Fits a dorm desk.", priceCents: 1200, condition: "Good", category: "Dorm essentials", sellerDisplayName: "Sam", pickupArea: "Daisy Hill", photoURLs: [])),
        (.active, Listing(id: "calculus", title: "Calculus textbook", description: "Used hardcover with a few penciled notes.", priceCents: 2500, condition: "Fair", category: "Books", sellerDisplayName: "Avery", pickupArea: "Wescoe Beach", photoURLs: [])),
        (.sold, Listing(id: "bike", title: "Campus bike", description: "Single speed commuter.", priceCents: 9000, condition: "Good", category: "Transportation", sellerDisplayName: "Jo", pickupArea: "Kansas Union", photoURLs: []))
    ]
    func search(_ query: String) -> [Listing] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.compactMap { status, item in
            guard status == .active else { return nil }
            return term.isEmpty || item.title.lowercased().contains(term) || item.description.lowercased().contains(term) ? item : nil
        }
    }
    func active(_ id: String) -> Listing? {
        rows.first { $0.0 == .active && $0.1.id == id }?.1
    }
}
