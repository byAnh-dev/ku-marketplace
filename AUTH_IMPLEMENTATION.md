# KU Marketplace — Authentication Setup & Testing Guide

**Project:** Team 19 — KU Marketplace  
**Features:** Requirement 3 (Student Registration and Email Verification) and Requirement 4 (Secure Login and Logout)  
**Technology:** Swift/Vapor, SQLite, Docker, Expo/React Native, TypeScript  
**Development environment:** Windows, VS Code, PowerShell, physical iPhone with Expo Go

This guide explains how to run the KU Marketplace application locally and test the complete authentication workflow, including registration, email verification, login, session persistence, and logout.

Development email verification is intended for local testing only.

---

## 1. Prerequisites

Before running the project, install:

- **Docker Desktop** — Runs the Swift/Vapor backend.
- **Node.js 24 and npm** — Runs the React Native frontend.
- **Visual Studio Code** — Development environment.
- **Expo Go** — Runs the application on a physical iPhone.
- **Expo account** — Required for the tunnel workflow used during testing.

Ensure Docker Desktop is running with Linux containers enabled.

Verify the installations in PowerShell:

```powershell
docker --version
node --version
npm --version
```

## 2. Project Structure

The repository should contain the following files:

```text
sprint-1/
├── backend/
│   ├── Package.swift
│   ├── Dockerfile
│   └── Sources/
│       └── Marketplace/
│           ├── AuthModels.swift
│           ├── AuthRoutes.swift
│           ├── Catalog.swift
│           └── Server.swift
├── frontend/
│   ├── src/
│   │   ├── auth.ts
│   │   ├── AuthScreen.tsx
│   │   └── api.ts
│   ├── App.tsx
│   ├── package.json
│   ├── package-lock.json
│   └── .env.local
├── tests/
│   ├── api-smoke.mjs
│   └── auth-smoke.mjs
├── compose.yaml
├── .gitignore
└── AUTH_IMPLEMENTATION.md
```

The `.env.local` file is created locally and must not be committed to GitHub.

## 3. Start the Backend

### Step 1: Open the project

Open the project root in VS Code.

In Terminal 1, navigate to the repository:

```powershell
cd C:\Users\shaya\OneDrive\Desktop\sprint-1
```

Other developers should replace this path with their own repository location.

### Step 2: Find your computer's IP address

Open PowerShell and run:

```powershell
ipconfig
```

Under the Wi-Fi adapter, find the IPv4 address.

For example, the address used during development was:

```text
192.168.40.77
```

This address may change depending on the network.

The computer and phone must be able to communicate over the same trusted local network.

### Step 3: Configure development email verification

In the same PowerShell terminal that will start Docker, run:

```powershell
$env:DEV_EMAIL_VERIFICATION="true"
$env:PUBLIC_API_URL="http://192.168.40.77:8080"
```

Replace the IP address with your computer's current IPv4 address.

These variables enable local email verification and configure the address used in verification links.

**Important:** PowerShell uses `$env:VARIABLE="value"`. Running `DEV_EMAIL_VERIFICATION=true` by itself will produce a command-not-found error.

### Step 4: Verify Docker Compose configuration

The repository's `compose.yaml` should contain the backend service configuration:

```yaml
services:
  api:
    build: ./backend
    ports:
      - "${API_PORT:-8080}:8080"
    environment:
      DATABASE_PATH: /data/marketplace.sqlite
      DEV_EMAIL_VERIFICATION: ${DEV_EMAIL_VERIFICATION:-false}
      PUBLIC_API_URL: ${PUBLIC_API_URL:-http://localhost:8080}
      RESEND_API_KEY: ${RESEND_API_KEY:-}
      VERIFICATION_FROM_EMAIL: ${VERIFICATION_FROM_EMAIL:-}
    volumes:
      - marketplace-data:/data

volumes:
  marketplace-data:
```

If this configuration is already present, no modifications are necessary.

### Step 5: Start Docker

Make sure Docker Desktop is running.

Execute:

```powershell
docker compose up --build
```

The first build downloads and compiles the Swift dependencies and may show hundreds of compilation messages.

This is expected.

After successful compilation, the backend should report something similar to:

```text
[ NOTICE ] Server started on http://0.0.0.0:8080
```

Leave Terminal 1 running.

### Step 6: Verify the backend

On your computer, open:

http://localhost:8080/health

Expected response:

```json
{"status":"ok"}
```

If you open `http://localhost:8080/` instead, the server may return:

```json
{"reason":"Not Found","error":true}
```

This is normal because the API does not define a homepage at `/`.

### Step 7: Verify phone connectivity

On your iPhone, open Safari and visit:

```text
http://192.168.40.77:8080/health
```

Replace the IP address with your computer's actual IPv4 address.

Expected response:

```json
{"status":"ok"}
```

If the URL cannot be opened on the phone, check the Wi-Fi network, Windows Firewall, and local network isolation.

Expo tunnel mode does not automatically expose the backend API.

## 4. Start the Frontend

### Step 1: Open a second terminal

Keep Terminal 1 running.

In Terminal 2:

```powershell
cd C:\Users\shaya\OneDrive\Desktop\sprint-1\frontend
```

Install the dependencies:

```powershell
npm ci
```

Ensure secure session storage is installed:

```powershell
npx expo install expo-secure-store
```

Check TypeScript:

```powershell
npm run typecheck
```

The command should finish without TypeScript errors.

### Step 2: Configure the API URL

Inside `frontend/`, create a file named:

```text
.env.local
```

Add:

```dotenv
EXPO_PUBLIC_API_URL=http://192.168.40.77:8080
```

Replace the IP address with your computer's current IPv4 address.

This tells the mobile application where to find the Swift/Vapor API.

Do not commit `.env.local` to GitHub.

### Step 3: Check Expo SDK compatibility

The original starter project used Expo SDK 57.

During development, Expo Go on iOS used SDK 58, so the frontend was upgraded for compatibility.

If Expo Go reports an incompatible SDK version, the team's dependencies must be aligned with the supported version.

Check dependencies using:

```powershell
npx expo install --fix
npx expo-doctor
npm run typecheck
```

**Note:** Any SDK upgrade changes shared frontend dependencies. Coordinate the upgrade with teammates before merging these changes into the shared branch.

### Step 4: Set up Expo tunnel mode

For Windows and a physical iPhone, tunnel mode can help when the phone cannot connect directly to Metro.

Install the tunnel dependency if necessary:

```powershell
npm install --global @expo/ngrok@4.1.0
```

If Expo still cannot detect the package, a local development installation may help:

```powershell
npm install --save-dev @expo/ngrok@4.1.0
```

Review any dependency changes before committing them.

### Step 5: Log in to Expo

Run:

```powershell
npx expo login --no-browser
```

Enter your Expo account credentials.

Verify the login:

```powershell
npx expo whoami
```

The terminal should display your Expo username.

The `--no-browser` option is useful when Windows cannot launch the browser authentication flow.

### Step 6: Start Expo

Run:

```powershell
npx expo start --tunnel --clear
```

Expo should start Metro and generate a QR code.

Open Expo Go on your iPhone and scan the QR code.

If your local network permits direct communication, you can alternatively run:

```powershell
npx expo start --lan --clear
```

Once the application opens, verify that the marketplace listings load correctly.

There are two separate connections involved:

1. **Phone → Expo/Metro:** Loads the React Native application.
2. **Phone → Swift/Vapor API:** Loads listings and performs authentication requests.

Both must work.

---

## 5. Task 3 — Test User Registration

### Step 1: Open registration

On the iPhone:

1. Open KU Marketplace in Expo Go.
2. Tap **Student login / register**.
3. Switch to the registration form.

### Step 2: Enter test credentials

Use the following fictional test account:

| Field | Value |
|---|---|
| Display name | Test Student |
| KU email | `teststudent123@ku.edu` |
| Password | `TestPassword123!` |
| Confirm password | `TestPassword123!` |

Use a unique fictional KU address if the example account has already been registered.

Tap **Register**.

**Expected result:** The account is created, but remains unverified. The application asks the user to verify their KU email.

In development mode, no verification email is actually sent. The verification link is written to Docker logs.

### Step 3: Confirm unverified users cannot log in

Before verifying the account:

1. Return to the Login screen.
2. Enter the newly registered email.
3. Enter its password.
4. Tap **Log in**.

**Expected result:** Login is rejected because the account has not been verified.

This confirms that unverified accounts cannot access authenticated functionality.

## 6. Verify the Student Account

### Step 1: Open a third terminal

In VS Code, open Terminal 3.

Navigate to the project root:

```powershell
cd C:\Users\shaya\OneDrive\Desktop\sprint-1
```

Run:

```powershell
docker compose logs --tail=100 api
```

### Step 2: Find the verification link

Look for a message similar to:

```text
DEVELOPMENT verification link for teststudent123@ku.edu:
http://192.168.40.77:8080/api/v1/auth/verify?token=...
```

The actual URL contains a randomly generated verification token.

Copy the complete verification URL.

### Step 3: Verify the account

Paste the verification URL into your computer's browser.

Expected message:

```text
KU Marketplace email verified.
Return to the app to log in.
```

Your account is now verified.

Verification links are single-use and expire after 30 minutes.

Never share or commit actual verification tokens.

### Step 4: Test registration validation

Try the following test cases:

| Test | Expected result |
|---|---|
| `student@gmail.com` | Rejected |
| `student@ku.edu.fake.com` | Rejected |
| Password `Test123` | Rejected |
| Different password and confirmation | Rejected |
| Previously registered email | Duplicate registration rejected |
| Unverified account login | Access denied |

The current implementation validates the exact `@ku.edu` email domain.

It uses KU email/password registration, not Google OAuth.

---

## 7. Task 7 — Test Secure Login and Logout

### Step 1: Log in

Return to KU Marketplace on your iPhone.

Enter the verified credentials:

```text
Email: teststudent123@ku.edu
Password: TestPassword123!
```

Tap **Log in**.

**Expected result:** Authentication succeeds and the application displays the signed-in account.

### Step 2: Test incorrect credentials

Log out if currently signed in.

Attempt to log in using an incorrect password.

**Expected result:** Authentication is rejected and no session is created.

### Step 3: Test session persistence

Log in successfully.

Completely close Expo Go and reopen the KU Marketplace project.

**Expected result:** The user remains signed in if the session is still valid.

The application uses `expo-secure-store` to store the session token securely on the device.

### Step 4: Test logout

Tap **Log out**.

**Expected result:**

- The authenticated session is revoked on the backend.
- The session is cleared from device storage.
- The application returns to its unauthenticated state.

### Step 5: Confirm protected access is denied

After logging out, attempt to access authenticated functionality again.

**Expected result:** The application requires the user to authenticate again.

The backend should also reject the previously revoked session token.

## 8. Authentication API Endpoints

The backend provides these authentication endpoints:

| Method | Endpoint | Purpose |
|---|---|---|
| POST | `/api/v1/auth/register` | Register a KU student |
| GET | `/api/v1/auth/verify?token=...` | Verify the student's email |
| POST | `/api/v1/auth/login` | Authenticate verified student |
| GET | `/api/v1/auth/me` | Retrieve authenticated account |
| POST | `/api/v1/auth/logout` | Revoke current session |

Protected endpoints use bearer-token authentication.

The implementation uses bcrypt password hashing and stores hashed session tokens in SQLite.

Sessions have a seven-day lifetime unless revoked earlier.

---

## 9. Run Automated Tests

Keep the Docker backend running.

From the project root:

```powershell
node tests/api-smoke.mjs
```

This checks the existing marketplace API.

Next:

```powershell
node tests/auth-smoke.mjs
```

Expected successful authentication test output:

```text
Auth negative-path smoke checks passed.
```

The authentication smoke tests check rejection cases such as invalid registration data, incorrect credentials, and unauthorized requests.

They do not replace the complete manual registration, verification, login, and logout tests.

### Check the frontend

Navigate to:

```powershell
cd frontend
```

Run:

```powershell
npm run typecheck
```

Then:

```powershell
npx expo-doctor
```

To validate the iOS JavaScript bundle:

```powershell
npx expo export --platform ios
```

An Expo export is not a substitute for native iOS simulator testing.

On Windows, use a physical iPhone with Expo Go or another appropriate device testing workflow.

## 10. Troubleshooting

| Problem | Solution |
|---|---|
| `DEV_EMAIL_VERIFICATION=true` not recognized | Use `$env:DEV_EMAIL_VERIFICATION="true"` in PowerShell |
| Docker connection refused | Confirm Docker build finished and backend started |
| `/` returns `Not Found` | Use `/health` |
| Docker displays hundreds of compiling messages | Normal during initial Swift build |
| Expo says internet is offline | Try tunnel mode or check LAN connectivity |
| Expo repeatedly asks for ngrok | Install `@expo/ngrok` |
| Expo requires authentication | Run `npx expo login --no-browser` |
| Browser login fails on Windows | Use terminal login with `--no-browser` |
| Expo SDK incompatible | Align frontend SDK and dependencies with Expo Go |
| Cannot find `expo-secure-store` | Run `npx expo install expo-secure-store` |
| App opens but API fails | Check `.env.local`, LAN IP and Windows Firewall |
| Registration returns an error | Check Docker logs and backend connectivity |
| Verification link missing | Check `DEV_EMAIL_VERIFICATION` inside the container |
| Account already registered | Use a different fictional KU email |
| Verification token invalid | It may be expired, previously used or copied incorrectly |

### Verify Docker environment variables

From the project root:

```powershell
docker compose exec api printenv DEV_EMAIL_VERIFICATION
```

Expected:

```text
true
```

Check the public URL:

```powershell
docker compose exec api printenv PUBLIC_API_URL
```

Expected example:

```text
http://192.168.40.77:8080
```

If the configuration is incorrect, restart Docker with the correct environment variables and recreate the container if necessary.

## 11. Stop and Restart the Application

### Stop Expo

In the Expo terminal, press:

```text
Ctrl + C
```

### Stop the backend

In the Docker terminal, press `Ctrl + C`.

Alternatively, from the repository root:

```powershell
docker compose down
```

This stops the backend containers while preserving the database volume.

**Do not run `docker compose down -v` unless you intentionally want to delete the development database and test accounts.**

### Restart on another day

1. Start Docker Desktop.
2. Run `ipconfig` to check whether the computer's IP changed.
3. Update `frontend/.env.local` if necessary.
4. Set the backend environment variables.
5. Start Docker.
6. Start Expo.
7. Scan the QR code.

---

## 12. Security Considerations

The current implementation is intended for development and testing.

Before production deployment:

- Disable `DEV_EMAIL_VERIFICATION`.
- Configure a real email delivery service.
- Use HTTPS for API communication.
- Add login and registration rate limiting.
- Protect against authentication abuse.
- Complete additional integration and security tests.
- Confirm the approved KU email domain list.
- Review secure session handling and recovery workflows.

Never commit:

```text
.env
.env.local
node_modules/
.expo/
*.sqlite
```

Also never commit actual passwords, session tokens, verification links, or API keys.

The current backend includes optional configuration for a Resend email delivery integration, but development mode does not require an external email service.

---

## 13. Quick Start — Three Terminals

Once the project is configured, the complete workflow can be started using three terminals.

### Terminal 1 — Backend

From the repository root:

```powershell
$env:DEV_EMAIL_VERIFICATION="true"
$env:PUBLIC_API_URL="http://192.168.40.77:8080"
docker compose up --build
```

Keep this terminal running.

### Terminal 2 — Frontend

From the `frontend` directory:

```powershell
npm ci
npx expo install expo-secure-store
npm run typecheck
npx expo start --tunnel --clear
```

Scan the QR code using Expo Go.

### Terminal 3 — Logs and Tests

From the repository root:

```powershell
docker compose logs --tail=100 api
```

Run the automated checks:

```powershell
node tests/api-smoke.mjs
node tests/auth-smoke.mjs
```

### Final Testing Checklist

- [ ] Docker backend starts successfully.
- [ ] `/health` returns `{"status":"ok"}`.
- [ ] iPhone can access the backend through the LAN IP.
- [ ] Expo Go launches KU Marketplace.
- [ ] Marketplace listings load.
- [ ] KU student registration works.
- [ ] Invalid email domains are rejected.
- [ ] Unverified accounts cannot log in.
- [ ] Development verification link works.
- [ ] Verified accounts can log in.
- [ ] Incorrect credentials are rejected.
- [ ] Authenticated session persists after restarting the app.
- [ ] Logout revokes the session.
- [ ] API smoke tests pass.
- [ ] Authentication smoke tests pass.
- [ ] TypeScript checks pass.

---

**Conclusion**

This workflow provides a reproducible local environment for testing KU Marketplace Requirements 3 and 4.

It covers student registration, KU email validation, email verification, secure login, session persistence, and logout using the Swift/Vapor backend and Expo/React Native frontend.

The development verification mechanism allows the authentication process to be tested without configuring a production email service. Before production deployment, real email delivery, HTTPS, rate limiting, and further security validation are required.

**Note:** Replace the sample local IP address and Windows folder path with the corresponding values for your own development environment.
