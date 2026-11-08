# KU Marketplace — Authentication Setup and Testing Guide

This guide explains how to run the KU Marketplace application locally and test student registration, email verification, login, and logout.

**Tech Stack:** Swift/Vapor, SQLite, Docker, Expo/React Native, TypeScript

## 1. Prerequisites

Install the following:

- Docker Desktop (Linux containers enabled)
- Node.js 24 and npm
- VS Code
- Expo Go on your phone
- Expo account (for tunnel mode)

Verify the installations:

```powershell
docker --version
node --version
npm --version
```

Make sure Docker Desktop is running before starting the backend.

## 2. Start the Backend

Open the project root in VS Code and start a PowerShell terminal.

### Configure environment variables

Find your computer's IPv4 address:

```powershell
ipconfig
```

Under the Wi-Fi adapter, locate the IPv4 address.

Set the development environment variables:

```powershell
$env:DEV_EMAIL_VERIFICATION="true"
$env:PUBLIC_API_URL="http://YOUR_LOCAL_IP:8080"
```

Replace `YOUR_LOCAL_IP` with your computer's IPv4 address.

Development verification allows email verification links to be generated locally without sending actual emails.

### Start Docker

From the repository root, run:

```powershell
docker compose up --build
```

The first build may take longer because Swift dependencies must be downloaded and compiled.

Leave this terminal running.

### Verify the API

Open:

```text
http://localhost:8080/health
```

Expected response:

```json
{"status":"ok"}
```

If this appears, the backend is running successfully.

## 3. Start the Frontend

Open a second terminal in VS Code.

Navigate to the frontend directory:

```powershell
cd frontend
```

Install dependencies:

```powershell
npm ci
```

Ensure secure session storage is installed:

```powershell
npx expo install expo-secure-store
```

### Configure the API URL

Create or update `frontend/.env.local`:

```dotenv
EXPO_PUBLIC_API_URL=http://YOUR_LOCAL_IP:8080
```

Replace `YOUR_LOCAL_IP` with your computer's IPv4 address.

The phone and computer must be connected to the same trusted network, and the backend must be accessible from the phone.

### Launch Expo

If tunnel mode is required, install ngrok:

```powershell
npm install --global @expo/ngrok@4.1.0
```

Log in to Expo if necessary:

```powershell
npx expo login --no-browser
```

Start the app:

```powershell
npx expo start --tunnel --clear
```

Scan the QR code using Expo Go.

Alternatively, when direct local network connectivity works:

```powershell
npx expo start --lan --clear
```

**Note:** Expo Go must be compatible with the project's Expo SDK version. If necessary, check dependencies using `npx expo-doctor` and coordinate SDK upgrades with the team.

### Verify Connectivity

On your phone, open:

```text
http://YOUR_LOCAL_IP:8080/health
```

Expected response:

```json
{"status":"ok"}
```

Expo tunnel mode only handles the connection to the Expo development server. The backend API must still be reachable separately.

## 4. Student Registration

Open KU Marketplace in Expo Go.

1. Select **Student login / register**.
2. Open the registration form.
3. Enter a display name, KU email, password, and password confirmation.
4. Submit the registration form.

Example test credentials:

| Field | Example |
|---|---|
| Display Name | Test Student |
| KU Email | `teststudent123@ku.edu` |
| Password | `TestPassword123!` |
| Confirm Password | `TestPassword123!` |

Use a unique fictional email address for development testing.

The account is created in an unverified state.

### Registration Validation

Verify that the application rejects:

- Email addresses outside the approved KU domain
- Invalid email formats
- Passwords that fail validation
- Mismatched passwords
- Duplicate accounts

Unverified accounts should not be able to log in.

## 5. Email Verification

With development verification enabled, verification links are written to backend logs.

From the repository root, run:

```powershell
docker compose logs --tail=100 api
```

Locate the verification link associated with the registered email.

Example:

```text
http://YOUR_LOCAL_IP:8080/api/v1/auth/verify?token=...
```

Copy the complete URL and open it in a browser.

Expected response:

```text
KU Marketplace email verified.
Return to the app to log in.
```

Verification links are single-use and expire after 30 minutes.

**Important:** Development verification links should never be shared publicly or committed to the repository.

## 6. Login and Logout

### Login

After verifying the account:

1. Open the login screen.
2. Enter the registered KU email and password.
3. Select **Log in**.

The application authenticates the user and securely stores the session token using Expo SecureStore.

### Session Persistence

To verify session persistence:

1. Log in successfully.
2. Close Expo Go.
3. Reopen the application.

The user should remain authenticated while the session is valid.

### Logout

Select **Log out**.

The application clears the locally stored session and requests server-side session revocation.

After logout, authenticated endpoints should reject the previous session token.

### Additional Checks

- Incorrect passwords must be rejected.
- Unverified accounts must not receive authenticated sessions.
- Protected endpoints must reject missing or invalid tokens.
- A revoked session must not remain usable.

## 7. Authentication API

| Method | Endpoint | Description |
|---|---|---|
| POST | `/api/v1/auth/register` | Register a student account |
| GET | `/api/v1/auth/verify?token=...` | Verify email ownership |
| POST | `/api/v1/auth/login` | Authenticate user |
| GET | `/api/v1/auth/me` | Retrieve authenticated user |
| POST | `/api/v1/auth/logout` | Revoke current session |

The backend uses SQLite for account and session persistence, bcrypt for password hashing, and bearer tokens for authenticated requests.

## 8. Run Tests

Keep the backend running.

From the repository root:

```powershell
node tests/api-smoke.mjs
node tests/auth-smoke.mjs
```

These validate the marketplace API and authentication error-handling behavior.

From the `frontend` directory:

```powershell
npm run typecheck
npx expo-doctor
```

To verify the iOS JavaScript bundle:

```powershell
npx expo export --platform ios
```

Automated checks should be supplemented with manual registration, verification, login, and logout testing on a physical device.

## 9. Troubleshooting

| Issue | Solution |
|---|---|
| Docker connection refused | Ensure the backend has finished building and started |
| `/` returns `Not Found` | Use `/health` to test the API |
| Expo cannot connect | Check Wi-Fi or use tunnel mode |
| ngrok installation error | Install `@expo/ngrok` |
| Expo login fails to open browser | Use `npx expo login --no-browser` |
| Expo SDK mismatch | Align project dependencies with Expo Go |
| Missing `expo-secure-store` | Run `npx expo install expo-secure-store` |
| App cannot reach API | Verify `.env.local`, local IP, and firewall settings |
| Verification link missing | Confirm development verification is enabled |
| Email already registered | Use another fictional test email |

To confirm the Docker configuration:

```powershell
docker compose exec api printenv DEV_EMAIL_VERIFICATION
```

Expected output:

```text
true
```

## 10. Stop and Restart

To stop Expo, press `Ctrl + C` in its terminal.

To stop the backend, run from the repository root:

```powershell
docker compose down
```

This preserves the SQLite database stored in the Docker volume.

Avoid `docker compose down -v` unless you intentionally want to delete the development database.

For future sessions, restart Docker Desktop, check your current IP address, configure the environment variables, and start the backend and frontend again.

## 11. Security Notes

Development email verification must not be enabled in production.

Before deployment:

- Configure a real email delivery service.
- Use HTTPS for API communication.
- Add rate limiting for authentication endpoints.
- Confirm approved university email domains.
- Test session expiration and revocation.
- Review authentication and data-storage security.

Never commit passwords, API keys, session tokens, verification links, or local environment files such as `.env` and `.env.local`.

---

## Quick Start Reference

**Terminal 1 — Backend (repository root)**

```powershell
$env:DEV_EMAIL_VERIFICATION="true"
$env:PUBLIC_API_URL="http://YOUR_LOCAL_IP:8080"
docker compose up --build
```

**Terminal 2 — Frontend (`frontend/`)**

```powershell
npm ci
npx expo start --tunnel --clear
```

**Terminal 3 — Logs and Tests (repository root)**

```powershell
docker compose logs --tail=100 api
node tests/api-smoke.mjs
node tests/auth-smoke.mjs
```

**Final verification:** Confirm registration, email verification, login, session persistence, and logout work successfully before deploying or merging changes.
