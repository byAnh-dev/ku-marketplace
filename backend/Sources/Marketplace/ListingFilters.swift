import Foundation

/// Validated feed filters.
///
/// Query values arrive as strings on purpose: a mistyped price or an unknown
/// condition must come back as a `422` field error the screen can show, not a
/// generic `400` from query decoding, and never as a silently empty feed.
struct ListingFilters: Sendable {
    let category: String?
    let condition: String?
    let minPriceCents: Int?
    let maxPriceCents: Int?

    /// No filters: every active listing, newest first.
    static let none = ListingFilters(validated: nil, nil, nil, nil)

    init(category: String?, condition: String?, minPriceCents: String?,
         maxPriceCents: String?) throws(ListingFieldErrors) {
        var fields: [String: String] = [:]
        let trimmed = { (value: String?) in value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

        let category = trimmed(category)
        if category.count > 50 { fields["category"] = "Category must be 50 characters or fewer." }

        let requestedCondition = trimmed(condition)
        let condition = Self.canonicalCondition(requestedCondition)
        if !requestedCondition.isEmpty && condition == nil {
            fields["condition"] = "Condition must be one of: \(ListingDraft.conditions.joined(separator: ", "))."
        }

        let minimum = Self.cents(trimmed(minPriceCents), label: "Minimum price",
                                 field: "minPriceCents", into: &fields)
        let maximum = Self.cents(trimmed(maxPriceCents), label: "Maximum price",
                                 field: "maxPriceCents", into: &fields)
        if let minimum, let maximum, minimum > maximum {
            fields["minPriceCents"] = "Minimum price must not be greater than the maximum."
        }

        guard fields.isEmpty else { throw ListingFieldErrors(fields: fields) }
        self.category = category.isEmpty ? nil : category
        self.condition = condition
        self.minPriceCents = minimum
        self.maxPriceCents = maximum
    }

    private init(validated category: String?, _ condition: String?, _ minPriceCents: Int?, _ maxPriceCents: Int?) {
        self.category = category
        self.condition = condition
        self.minPriceCents = minPriceCents
        self.maxPriceCents = maxPriceCents
    }

    /// Stored conditions are canonical labels, so the filter accepts any case.
    private static func canonicalCondition(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return ListingDraft.conditions.first { $0.lowercased() == value.lowercased() }
    }

    private static func cents(_ value: String, label: String, field: String,
                              into fields: inout [String: String]) -> Int? {
        guard !value.isEmpty else { return nil }
        guard let cents = Int(value), cents >= 0 else {
            fields[field] = "\(label) must be a whole number of cents."
            return nil
        }
        return cents
    }
}
