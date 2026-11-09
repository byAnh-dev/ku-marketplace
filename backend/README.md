# Sprint 1: My Listings and search

This backend supports accounts, sessions, publishing, My Listings and public
search. Accounts and credentials persist in SQLite. Listings still use an
in-memory catalog and are lost when the backend restarts.

## Public feed

`GET /api/v1/listings` and `GET /api/v1/listings/:id` read one in-memory listing
store seeded with the sample rows, so rows added at runtime (by the publish
endpoint) appear without a restart. Added rows surface
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
| `POST /api/v1/listings` | `201`, created listing plus `Location` | `401` missing or invalid session; `422` field errors; `400` malformed JSON |
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

`401` means the session is missing, invalid, expired, revoked, or belongs to an
unverified account. Login itself returns `403` for an unverified account.
A `201` returns the created listing with its server-minted
`id`, so navigate with `Location` or the body `id`. Photos are attached by the
separate photo-upload feature; `photoURLs` is empty at creation.

The frontend form must mirror these rules for instant feedback. The server
stays authoritative: never send `sellerDisplayName`, `ownerID`, `id`, or
`status`, and expect them to be ignored if sent.

## Session authentication

`configureApplication` configures SQLite, applies the account migrations, and
registers auth and listing routes. The Docker volume preserves accounts and
credentials across container restarts. Tests use a separate in-memory SQLite
database for each application.

The account API provides `POST /api/v1/auth/register`, `GET /api/v1/auth/verify`,
`POST /api/v1/auth/login`, `GET /api/v1/auth/me`, and `POST /api/v1/auth/logout`.
Registration requires an exact `ku.edu` email address and a matching password
of 12–72 UTF-8 bytes. Email verification links expire after 30 minutes. Login
requires a verified account and returns a session token valid for seven days.

Send `Authorization: Bearer <session token>` to publish or read My Listings.
`SessionAuthenticator` runs before the listing guards. It uses `currentSession`
to check the token hash, session kind, expiry, revocation and current account
verification in SQLite. Auth profile and logout use the same validator.
Missing or invalid credentials return `401`. Verification-link tokens cannot
authorize listing requests. Logout revokes the presented session; other
sessions for that account remain valid. Public browse and details do not
require authentication.

After validation, the authenticator creates `AuthenticatedMarketplaceUser`
from the stored `MarketplaceUser`. Its String ID comes from
`try account.requireID().uuidString`; publishing stores that exact value as
`ownerID`. The client cannot choose the seller ID or verification state.
Sample owners such as `sam` are fixtures, not real login accounts.

For real email delivery, set `RESEND_API_KEY`, `VERIFICATION_FROM_EMAIL`, and
`PUBLIC_API_URL` to the deployed HTTPS API URL. For local testing with fictional
accounts only, set `DEV_EMAIL_VERIFICATION=true` before starting Compose. This
prints verification links to backend logs instead of sending email. Keep this
mode disabled for real accounts. The default is disabled.

The frontend now includes registration, verification instructions, login,
session restoration and logout. The publish and My Listings screens remain
future work.

## Verification

From the repo root run `docker build --target test -t marketplace-tests ./backend`.
Alternatively run `swift test` inside `backend/` with a compatible toolchain.
Tests cover unauthorized/forged identity, owner isolation, owned details, empty
lists, deleted items, mixed-case title/description search, clear, no matches,
live feed ordering, publish auth (`401`/`403`), per-field validation, and
server-derived seller association. `SessionTests` exercises real SQLite
credentials, password login, UUID ownership, account isolation, expiry,
revocation, wrong token kinds, unverified accounts, and logout. These tests do
not install the fake identity helper used by the isolated listing tests.
They use [VaporTesting](https://docs.vapor.codes/advanced/testing/).

With the API running, `node tests/api-smoke.mjs` checks the public API and denial
of unverified credentials. `node tests/auth-smoke.mjs` checks auth error paths.
CI runs the Swift tests and both smoke scripts. Email delivery requires a
separate provider check.
