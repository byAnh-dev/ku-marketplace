# Sprint 1 backend: accounts, listings, and publish

This backend serves the marketplace feed, publisher, My Listings, and KU student
accounts. Accounts and sessions are stored in SQLite through Fluent; listings
still live in one in-memory catalog, so published items are lost on restart.

## Accounts and sessions

- Registration accepts only an exact `@ku.edu` address, hashes the password with
  Bcrypt, and stores the account unverified. A failed send deletes the new
  account so a retry does not hit "email already exists".
- Verification emails a single-use link valid for 30 minutes. `GET
  /api/v1/auth/verify?token=...` marks the account verified and returns HTML for
  the browser the link opens in.
- Login returns a 7-day session token. Only its SHA-256 digest is stored, so a
  database leak does not leak live sessions. Unverified accounts get `403`.
- `SessionAuthenticator` runs on every request, resolves an `Authorization:
  Bearer <token>` session into `MarketplaceUser(id:displayName:verified:)`, and
  does nothing when no bearer token is present (no database work for public
  requests).
- Logout marks the credential used, revoking it immediately.

Set `DEV_EMAIL_VERIFICATION=true` locally to log the verification link instead of
sending mail. Without that flag or a `RESEND_API_KEY` plus
`VERIFICATION_FROM_EMAIL`, registration returns `503`.

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
| `POST /api/v1/auth/register` | `200`, "check your KU email" | `400` bad input; `409` email taken; `503` mail not configured |
| `GET /api/v1/auth/verify?token=` | `200` HTML confirmation | `400` invalid or expired link |
| `POST /api/v1/auth/login` | `200`, `{ token, user }` | `401` bad credentials; `403` unverified |
| `GET /api/v1/auth/me` | `200`, public user | `401` sign-in required |
| `POST /api/v1/auth/logout` | `204` | `401` sign-in required |
| `GET /api/v1/listings?q=dorm` | `200`, active listings matching title or description, ignoring case | |
| `GET /api/v1/listings/:id` | `200`, public active listing | `404` unavailable |
| `POST /api/v1/listings` | `201`, created listing plus `Location` | `401` sign-in required; `403` email not verified; `422` field errors; `400` malformed JSON |
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

## Publish contract

`POST /api/v1/listings` takes JSON. Only these fields are read; the id, seller,
and status are server-owned:

| Field | Rule |
| --- | --- |
| `title` | required after trimming, at most 120 characters |
| `description` | required after trimming, at most 2000 characters |
| `priceCents` | required integer, `1` to `10000000` ($0.01 to $100,000.00) |
| `category` | required after trimming, at most 50 characters |
| `condition` | required, one of `New`, `Like new`, `Good`, `Fair`, `Poor` (any case; stored canonicalized) |
| `pickupArea` | optional, at most 80 characters, defaults to `Campus` |

`422` returns every failing field at once so the form can highlight inputs:

```json
{ "message": "Check the highlighted fields.",
  "fieldErrors": { "title": "Title is required.", "priceCents": "Price must be between $0.01 and $100,000.00." } }
```

`401` means prompt for sign-in. `403` means the account exists but the KU email
is still unverified. A `201` returns the created listing with its server-minted
`id`, so navigate with `Location` or the body `id`. Photos are attached by the
separate photo-upload feature; `photoURLs` is empty at creation.

The frontend form must mirror these rules for instant feedback. The server
stays authoritative: never send `sellerDisplayName`, `ownerID`, `id`, or
`status`, and expect them to be ignored if sent.

## Account identity

`MarketplaceUser` in `Sources/Marketplace/Routes.swift` is the request principal
the guards resolve; `SessionAuthenticator` logs it in only after validating a
verified session, using the account's UUID string as `id` and its stored display
name:

```swift
request.auth.login(MarketplaceUser(id: id.uuidString,
                                   displayName: account.displayName,
                                   verified: true))
```

Never trust account IDs, display names, or the verified flag from headers, query
parameters, or unverified tokens. The publish route re-checks `verified` and
returns `403` when it is false. There is no development login bypass; only the
test target installs a fake authenticated user.

Sample listings stay owned by the string IDs `sam`, `avery`, and `jo`, which no
real account can match, so a signed-in student sees only what they published.

## Verification

From the repo root run `docker build --target test -t marketplace-tests ./backend`.
Alternatively run `swift test` inside `backend/` with a compatible toolchain.
Tests cover unauthorized/forged identity, owner isolation, owned details, empty
lists, deleted items, mixed-case title/description search, clear, no matches,
live feed ordering, publish auth (`401`/`403`), per-field validation, and
server-derived seller association.
They use [VaporTesting](https://docs.vapor.codes/advanced/testing/).

With the API running, `node tests/api-smoke.mjs` checks the public API and denial
of unverified credentials. CI runs both checks.
