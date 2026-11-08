import Foundation
import Vapor

/// Publish payload. Every field is optional here so a missing value becomes a
/// field error (`422`) instead of a decode failure (`400`). Seller identity and
/// the listing id are never accepted from the client.
struct CreateListingBody: Content {
    let title: String?
    let description: String?
    let priceCents: Int?
    let category: String?
    let condition: String?
    let pickupArea: String?
}

/// Field-level failures, rendered by the route as `422` with a field map so the
/// form can highlight inputs instead of showing one generic message.
struct ListingFieldErrors: Error {
    let fields: [String: String]
}

struct FieldErrorBody: Content {
    let message: String
    let fieldErrors: [String: String]
}

/// A publish payload that passed validation, with text trimmed and the
/// condition normalized to its canonical label.
struct ListingDraft {
    let title, description, category, condition, pickupArea: String
    let priceCents: Int

    /// Lowest and highest accepted price, in cents ($0.01 to $100,000.00).
    static let priceRange = 1...10_000_000
    static let conditions = ["New", "Like new", "Good", "Fair", "Poor"]

    init(_ body: CreateListingBody) throws(ListingFieldErrors) {
        var fields: [String: String] = [:]
        let trimmed = { (value: String?) in value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

        let title = trimmed(body.title)
        if title.isEmpty { fields["title"] = "Title is required." }
        else if title.count > 120 { fields["title"] = "Title must be 120 characters or fewer." }

        let description = trimmed(body.description)
        if description.isEmpty { fields["description"] = "Description is required." }
        else if description.count > 2000 { fields["description"] = "Description must be 2000 characters or fewer." }

        let category = trimmed(body.category)
        if category.isEmpty { fields["category"] = "Category is required." }
        else if category.count > 50 { fields["category"] = "Category must be 50 characters or fewer." }

        let condition = Self.conditions.first { $0.lowercased() == trimmed(body.condition).lowercased() }
        if condition == nil {
            fields["condition"] = "Condition must be one of: \(Self.conditions.joined(separator: ", "))."
        }

        let priceCents = body.priceCents
        if priceCents == nil { fields["priceCents"] = "Price is required." }
        else if !Self.priceRange.contains(priceCents ?? 0) {
            fields["priceCents"] = "Price must be between $0.01 and $100,000.00."
        }

        let pickupArea = trimmed(body.pickupArea)
        if pickupArea.count > 80 { fields["pickupArea"] = "Pickup area must be 80 characters or fewer." }

        guard fields.isEmpty, let condition, let priceCents else {
            throw ListingFieldErrors(fields: fields)
        }

        self.title = title
        self.description = description
        self.category = category
        self.condition = condition
        self.priceCents = priceCents
        self.pickupArea = pickupArea.isEmpty ? "Campus" : pickupArea
    }
}
