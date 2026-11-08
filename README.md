# KU Marketplace

An iOS-first marketplace for University of Kansas students. This Team 19 starter has a Swift/Vapor HTTP API in `backend/` and an Expo/React Native TypeScript app in `frontend/`. It runs without credentials or cloud services. The read-only catalog uses two active sample items and one sold item.

## Run locally

1. Install Docker Desktop with Linux containers (or Docker Engine with Compose) and Node.js 24 with npm. Start the Docker engine.
2. From the repo root, run `docker compose up --build`. The first Swift build downloads and compiles dependencies. Open <http://localhost:8080/health> and expect `{"status":"ok"}`. With a Swift 6.3 toolchain on macOS or Linux you can instead run `swift run Marketplace serve --hostname 0.0.0.0` from `backend/`.
3. In a second terminal, run `cd frontend`, then `npm ci`. For an iOS simulator on the API machine, leave the API URL unset. For the standard Android emulator the default is `http://10.0.2.2:8080`.
4. On a **physical phone**, copy `.env.example` to `.env.local` inside `frontend/` and replace the URL with `http://<computer-LAN-IP>:8080`. Connect both devices to the same trusted network and check that the phone can open the health URL. Restart Metro after changing the URL. Never put secrets in an `EXPO_PUBLIC_*` variable.
5. Run `npm start` and scan the QR code with an Expo Go client compatible with SDK 57. On a Mac with Xcode and an installed iOS simulator, press **i**; for a local native build use `npx expo run:ios`. On Windows use a physical device or Android emulator. To stop the API, run `docker compose down`.

## Try the starter

Open the marketplace, search for **DORM** (a word in the lamp description), open the lamp and return to your results. Clear search to restore all active items. Listings with no photos have a placeholder. Details load from the server when opened.

| Route | Result |
| --- | --- |
| `GET /health` | Service health |
| `GET /api/v1/listings?q=dorm` | Active listings; optional case-insensitive title/description search |
| `GET /api/v1/listings/desk-lamp` | One public listing, including integer price in USD cents, seller display name, general pickup area and ordered photo URLs |
| `GET /api/v1/listings/bike` | 404 for sold item; missing IDs also return 404 |

With the API running, run `node tests/api-smoke.mjs` from the root. Set `API_URL` if using a different host or port. In `frontend/`, run `npm run typecheck` and `npx expo export --platform ios` to check the TypeScript and bundle. GitHub Actions runs these checks and the API smoke test when the repository is pushed. A bundle export does not replace a simulator test.

## Sprint scope and next steps

The `sprint-1` backend adds guarded My Listings list/detail routes and search
regression tests. See [the backend integration contract](backend/README.md)
for response shapes and frontend handoff. My Listings requires the accounts
teammate's verified-session integration before it is usable outside tests.

The [Sprint 1 requirements](https://docs.google.com/document/d/1-CAXYMrqLGVpVqagoc3pTq0-hFtWgDgeiopG4IKuBoI/edit) list eight stories. The [initial architecture](https://docs.google.com/document/d/1yfwpq67uj-kCq9D3l9fatBFhQF8GssEcRgc2EJTU-5M/edit) describes a larger plan. This repository uses React Native in place of SwiftUI and follows the explicit sprint list for search (R7). The client only talks to the API.

| Requirements | Starter coverage / next work |
| --- | --- |
| R1–2: Browse and details | API and app wired to sample data; active-only feed, unavailable detail, gallery/placeholder, loading, empty and retry states. |
| R7: Search | Implemented against the sample catalog; preserve the query when returning from details. |
| R3–4: Accounts and sessions | Planned. Require exact `ku.edu` domain and mailbox proof via an expiring single-use link. Use a managed identity service or reviewed password hashing, securely store the session on-device, revoke it on logout. |
| R5, R8: Publish and My Listings | Planned. Add relational persistence, verified sessions, server-derived seller identity, client and server validation, and owner-only access for private listings and changes. |
| R6: Photo upload | Planned. Attach up to five ordered photos after listing creation. Check ownership, byte size, type and decodability before linking object storage keys. The first image is primary. |

Open team decisions: identity/email service, relational database, image storage and HTTPS host. No write or authentication endpoints are exposed yet. Before GTA handoff, deploy an HTTPS API, test the iOS simulator build against it, and record the Xcode, simulator and toolchain versions. Messaging, offers, favorites and moderation are outside this starter.

