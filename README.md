# KU Marketplace

An iOS-first marketplace for University of Kansas students. This Team 19 starter has a Swift/Vapor HTTP API in `backend/` and an Expo/React Native TypeScript app in `frontend/`. Public browsing runs without credentials or cloud services. The catalog starts with two active sample items and one sold item.

## Run locally

1. Install Docker Desktop with Linux containers (or Docker Engine with Compose) and Node.js 24 with npm. Start the Docker engine.
2. From the repo root, run `docker compose up --build`. The first Swift build downloads and compiles dependencies. Open <http://localhost:8080/health> and expect `{"status":"ok"}`. With a Swift 6.3 toolchain on macOS or Linux you can instead run `swift run Marketplace serve --hostname 0.0.0.0` from `backend/`.
3. In a second terminal, run `cd frontend`, then `npm ci`. For an iOS simulator on the API machine, leave the API URL unset. For the standard Android emulator the default is `http://10.0.2.2:8080`.
4. On a **physical phone**, copy `.env.example` to `.env.local` inside `frontend/` and replace the URL with `http://<computer-LAN-IP>:8080`. Connect both devices to the same trusted network and check that the phone can open the health URL. Restart Metro after changing the URL. Never put secrets in an `EXPO_PUBLIC_*` variable.
5. Run `npm start` and scan the QR code with an Expo Go client compatible with SDK 58. On a Mac with Xcode and an installed iOS simulator, press **i**; for a local native build use `npx expo run:ios`. On Windows use a physical device or Android emulator. To stop the API, run `docker compose down`.

## Try the starter

Open the marketplace, search for **DORM** (a word in the lamp description), open the lamp and return to your results. Clear search to restore all active items. Listings with no photos have a placeholder. Details load from the server when opened.

Choose **Student login / register** to create an account with a KU email address.
Open the email verification link within 30 minutes, then return to the app and
log in. Registration does not sign you in automatically. Email delivery needs
the provider configuration in [backend/README.md](backend/README.md). For local
fictional accounts, enable `DEV_EMAIL_VERIFICATION=true` on the backend and use
the link from its logs.

The app stores only the session token in Expo SecureStore and checks it with
`GET /api/v1/auth/me` when it starts. Expired or revoked sessions return to the
login option. Temporary connection failures keep the token and show **Retry
session**; public browsing remains available. **Log out** revokes the session
on the server before removing it from the device. If logout cannot reach the
server, reconnect and retry. An already expired or revoked token can be removed
locally without another successful revocation.

Run `npm test` in `frontend/` for the client protocol and rendered component
tests. These run the real React components and account client with substituted
native controls, device storage and HTTP responses. They do not replace testing
SecureStore and interaction on an iOS or Android device.

| Route | Result |
| --- | --- |
| `GET /health` | Service health |
| `GET /api/v1/listings?q=dorm` | Active listings; optional case-insensitive title/description search |
| `GET /api/v1/listings/desk-lamp` | One public listing, including integer price in USD cents, seller display name, general pickup area and ordered photo URLs |
| `POST /api/v1/listings` | Creates an active listing for the signed-in verified seller; `401` without a valid verified session, `422` with per-field errors |
| `GET /api/v1/listings/bike` | 404 for sold item; missing IDs also return 404 |

With the API running, run `node tests/api-smoke.mjs` from the root. Set `API_URL` if using a different host or port. In `frontend/`, run `npm run typecheck` and `npx expo export --platform ios` to check the TypeScript and bundle. GitHub Actions runs these checks and the API smoke test when the repository is pushed. A bundle export does not replace a simulator test.

## Sprint scope and next steps

The `sprint-1` backend connects SQLite-backed account sessions to publishing
and My Listings. See [the backend integration contract](backend/README.md)
for response shapes, email configuration and frontend handoff. Accounts and
sessions persist; listings still live in memory.

The [Sprint 1 requirements](https://docs.google.com/document/d/1-CAXYMrqLGVpVqagoc3pTq0-hFtWgDgeiopG4IKuBoI/edit) list eight stories. The [initial architecture](https://docs.google.com/document/d/1yfwpq67uj-kCq9D3l9fatBFhQF8GssEcRgc2EJTU-5M/edit) describes a larger plan. This repository uses React Native in place of SwiftUI and follows the explicit sprint list for search (R7). The client only talks to the API.

| Requirements | Starter coverage / next work |
| --- | --- |
| R1–2: Browse and details | API and app wired to sample data; active-only feed, unavailable detail, gallery/placeholder, loading, empty and retry states. |
| R7: Search | Implemented against the sample catalog; preserve the query when returning from details. |
| R3–4: Accounts and sessions | Registration, verification instructions, password login, session restoration and logout connected in the app. SQLite-backed sessions authorize protected listing routes. Native tokens use SecureStore; real email requires provider configuration. |
| R5, R8: Publish and My Listings | Backend publishing, server validation, session-derived seller identity and owner-only reads implemented. Creation/My Listings screens, client validation and persistent listing storage remain. |
| R6: Photo upload | Planned. Attach up to five ordered photos after listing creation. Check ownership, byte size, type and decodability before linking object storage keys. The first image is primary. |

SQLite stores accounts and sessions. The backend includes a Resend email adapter;
configure it as described in the backend README, or use development-only logged
verification links with fictional accounts. Image storage and the HTTPS host
remain open decisions. Before GTA handoff, deploy an HTTPS API, test the iOS
simulator build against it, and record the Xcode, simulator and toolchain
versions. Messaging, offers, favorites and moderation are outside this starter.

