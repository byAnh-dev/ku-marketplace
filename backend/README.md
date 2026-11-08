# Sprint 1: My Listings and search

This backend slice supports My Listings and public search. It still uses an
in-memory sample catalog. Session verification and persistent listing creation
belong to the separate accounts/publish features.

## Public feed

`GET /api/v1/listings` and `GET /api/v1/listings/:id` read one in-memory listing
store seeded with the sample rows, so rows added at runtime (by the publish
endpoint later in this sprint) appear without a restart. Added rows surface
ahead of the sample rows; within a batch the newest is first.

- `photoURLs` is ordered: index 0 is the primary card photo. An empty array
  means the client renders its placeholder.
- Sold, reserved, and deleted rows never appear in the feed or on the public
  details route. Only My Listings shows them.
- `200 []` means no active listings; show the empty state. A `404` from the
  public details route means the card is stale; refresh the feed.

## Frontend contract

| Request | Success | Other responses |
| --- | --- | --- |
| `GET /api/v1/listings?q=dorm` | `200`, active listings matching title or description, ignoring case | |
| `GET /api/v1/listings/:id` | `200`, public active listing | `404` unavailable |
| `GET /api/v1/me/listings` | `200`, array of owned entries | `401` sign-in required |
| `GET /api/v1/me/listings/:id` | `200`, owned entry | `401` sign-in required; `404` missing, deleted, or owned by someone else |

An owned entry is `{ "status": "active", "listing": { ... } }`. Its `listing`
has the same fields as a public listing, including `id`. My Listings includes
active, reserved, and sold items, and excludes deleted items. Ownership uses a
stable account ID, never a display name. Owner IDs are not exposed publicly.

- Open details using `entry.listing.id` with the owned detail route so sold and
  reserved items can still be viewed.
- `200 []` from My Listings means show the empty state and Create Listing action.
- Create Listing navigates to the frontend creation form; the separate publish
  feature supplies its write endpoint.
- `401` means prompt for sign-in, not show an empty state.
- Search trims surrounding whitespace and matches substrings. Clear it by
  omitting `q` or sending `q=`; both return all active listings.
- `200 []` for a nonempty search means show no results. Display errors separately.
  URL-encode search values.

## Accounts teammate integration

`MarketplaceUser` in `Sources/Marketplace/Routes.swift` is the authentication
boundary. Register the verified-session authenticator before the protected
route guard and, only after validating the session, call:

```swift
request.auth.login(MarketplaceUser(id: verifiedAccountID))
```

The ID must match the listing's stored `ownerID`. Sample IDs are `sam`, `avery`,
and `jo`. Never trust account IDs from headers, query parameters, or unverified
tokens. The running server returns `401` for all My Listings requests until
the accounts feature is integrated. There is no development login bypass.
Only the test target installs a fake authenticated user.

## Verification

From the repo root run `docker build --target test -t marketplace-tests ./backend`.
Alternatively run `swift test` inside `backend/` with a compatible toolchain.
Tests cover unauthorized/forged identity, owner isolation, owned details, empty
lists, deleted items, mixed-case title/description search, clear, and no matches.
They use [VaporTesting](https://docs.vapor.codes/advanced/testing/).

With the API running, `node tests/api-smoke.mjs` checks the public API and denial
of unverified credentials. CI runs both checks.
