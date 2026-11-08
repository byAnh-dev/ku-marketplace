# Tasks 3 and 7 — KU Marketplace accounts

## What is implemented

- Registration using display name, `@ku.edu` email, password and confirmation.
- Passwords stored only as bcrypt hashes; email normalized to lowercase; unique index on email.
- One-time 30-minute verification links; no session issued before verification.
- Login, authenticated `/me`, and logout with revocable, seven-day bearer sessions.
- Session token is stored as SHA-256 digest in SQLite, not raw token.
- Mobile login/registration screens and secure native token storage using `expo-secure-store`.
- Existing public catalog and browsing remain functional without login.

## Installation (run before commit/push)

From the `frontend/` directory, run **`npx expo install expo-secure-store`**. This updates both `package.json` and `package-lock.json` to the SDK-57-compatible version. Run `npm run typecheck` and `npx expo export --platform ios` after installation. Commit the modified dependency files. This ZIP cannot pre-generate the lockfile because the npm registry was unreachable in the preparation environment.

From repo root, to test locally, set `DEV_EMAIL_VERIFICATION=true` and `PUBLIC_API_URL=http://localhost:8080` in a root-level `.env` file (ignored by Git), then run `docker compose up --build`. Use `docker compose logs -f api` to see the one-time verification URL after registration. **Development mode prints verification tokens to server logs. Never enable it on a public or shared deployment.** `PUBLIC_API_URL` must be a URL the browser can reach; for phone testing use your computer's LAN IP. For the Expo mobile API URL, follow `frontend/.env.example`.

For actual email delivery, unset `DEV_EMAIL_VERIFICATION` and configure `RESEND_API_KEY`, `VERIFICATION_FROM_EMAIL` (a sender validated in Resend), and your public HTTPS `PUBLIC_API_URL`. The provider, sender domain, and HTTPS endpoint must be configured by the team. Never put provider API keys into `EXPO_PUBLIC_*` variables.

User data persists in a Docker named volume `marketplace-data`; `docker compose down -v` removes it.

## Endpoint contract

`POST /api/v1/auth/register`: JSON `{ "displayName":"Test Student", "email":"test@ku.edu", "password":"strongpassword123", "passwordConfirmation":"strongpassword123" }`. Returns a verification reminder.

`GET /api/v1/auth/verify?token=<token>`: one-time email link, renders confirmation HTML.

`POST /api/v1/auth/login`: JSON `{ "email":"test@ku.edu", "password":"strongpassword123" }`. Returns `{ "token": "...", "user": { "id": "...", "displayName": "...", "email": "...", "verified": true } }`.

`GET /api/v1/auth/me`: `Authorization: Bearer <token>`. Returns current verified user's profile.

`POST /api/v1/auth/logout`: `Authorization: Bearer <token>`. Revokes this session (204); the client then deletes the local token.

## Integration for Tasks 1 and 5

The listings teammate should use **the authenticated identity obtained server-side** from the bearer session; never accept a `sellerId` supplied by the mobile app. Currently the auth lookup is private in `AuthRoutes.swift`, so extract `currentUser(_:)` into a shared internal authentication service before hooking up the protected listing routes. The existing catalog is still public and sample-only.

## Security follow-ups before public launch

- Configure HTTPS, secure email provider, and a verified sender; disable development verification logging.
- Implement per-IP and per-account login/registration throttling, abuse protection, audit events, password reset and verification resend, and transactional verification consumption.
- Consider replacing local SQLite with team-selected production database for multi-instance hosting.
- Resolve exact KU-approved domains and the team's Google OAuth-versus-password decision; current implementation follows Sprint 1 email/password acceptance criteria, **not Google OAuth**.
- Add automated auth endpoint tests (including parallel verification, session expiration and logout) and a real-device login/logout walkthrough before merging.

## Git usage

On your own branch: `git switch -c feature/auth-registration-login`, then after installing dependency and running tests: `git add backend frontend/App.tsx frontend/src/AuthScreen.tsx frontend/src/auth.ts compose.yaml AUTH_IMPLEMENTATION.md` (also stage frontend/package*.json), `git commit -m "Implement KU registration verification and secure sessions"`, `git push -u origin feature/auth-registration-login`.

Basic negative-path smoke checks: with API running, execute `node tests/auth-smoke.mjs` at repo root. This does not cover positive registration/verification end to end.
