import Fluent
import Foundation
import SQLKit

/// Storage fields are separate from the public Listing response.
final class ListingRecord: Model, @unchecked Sendable {
    static let schema = "listings"

    @ID(custom: "sequence", generatedBy: .database) var id: Int?
    @Field(key: "listing_id") var listingID: String
    @Field(key: "owner_id") var ownerID: String
    @Field(key: "status") var status: String
    @Field(key: "title") var title: String
    @Field(key: "description") var description: String
    @Field(key: "price_cents") var priceCents: Int
    @Field(key: "condition") var condition: String
    @Field(key: "category") var category: String
    @Field(key: "seller_display_name") var sellerDisplayName: String
    @Field(key: "pickup_area") var pickupArea: String
    @Field(key: "photo_urls") var photoURLs: [String]
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "revision") var revision: String?

    init() {}

    init(row: Catalog.Row) {
        self.listingID = row.listing.id
        self.ownerID = row.ownerID
        self.status = row.status.rawValue
        self.title = row.listing.title
        self.description = row.listing.description
        self.priceCents = row.listing.priceCents
        self.condition = row.listing.condition
        self.category = row.listing.category
        self.sellerDisplayName = row.listing.sellerDisplayName
        self.pickupArea = row.listing.pickupArea
        self.photoURLs = row.listing.photoURLs
        self.createdAt = Date()
    }

    var listing: Listing {
        Listing(id: listingID, title: title, description: description, priceCents: priceCents,
                condition: condition, category: category, sellerDisplayName: sellerDisplayName,
                pickupArea: pickupArea, photoURLs: photoURLs)
    }
}

struct CreateListings: AsyncMigration {
    let seedRows: [Catalog.Row]

    func prepare(on db: any Database) async throws {
        try await db.transaction { db in
            try await db.schema(ListingRecord.schema)
                .field("sequence", .int, .identifier(auto: true))
                .field("listing_id", .string, .required).unique(on: "listing_id")
                // Keep sample owners and real account UUID strings in their existing format.
                .field("owner_id", .string, .required)
                .field("status", .string, .required)
                .field("title", .string, .required)
                .field("description", .string, .required)
                .field("price_cents", .int, .required)
                .field("condition", .string, .required)
                .field("category", .string, .required)
                .field("seller_display_name", .string, .required)
                .field("pickup_area", .string, .required)
                .field("photo_urls", .json, .required)
                .field("created_at", .datetime, .required)
                .field("revision", .string)
                .ignoreExisting()
                .create()
            // Seed once as part of the migration. Reverse insertion preserves the current
            // sample order while later listings sort first by their database sequence.
            // A crash after this commit but before Fluent records migration history can
            // rerun prepare; existing rows must keep their details and photo links.
            for row in seedRows.reversed() {
                if try await ListingRecord.query(on: db).filter(\.$listingID == row.listing.id).first() == nil {
                    try await ListingRecord(row: row).create(on: db)
                }
            }
        }
    }

    func revert(on db: any Database) async throws {
        try await db.schema(ListingRecord.schema).delete()
    }
}

/// Existing Sprint 1 databases have no revision column. Null is the initial version.
struct AddListingRevisions: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        struct Column: Decodable { let name: String }
        let columns = try await sql.raw("PRAGMA table_info(listings)").all(decoding: Column.self)
        if !columns.contains(where: { $0.name == "revision" }) {
            try await db.schema(ListingRecord.schema).field("revision", .string).update()
        }
    }

    func revert(on db: any Database) async throws {
        try await db.schema(ListingRecord.schema).deleteField("revision").update()
    }
}
