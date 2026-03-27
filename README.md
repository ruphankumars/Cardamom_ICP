# Cardamom ICP

> Green cardamom trading platform — fully hosted on the Internet Computer Protocol (ICP).  
> No Firebase. No Render. GitHub + ICP only.

## Architecture

```
GitHub (source + CI/CD)
    │
    ├── GitHub Actions
    │       ├── npm test (227 tests)
    │       ├── flutter build web --release
    │       └── dfx deploy --network ic
    │
ICP Network
    ├── Frontend Canister (Asset) ← Flutter web app
    └── Backend Canister (Azle)   ← Express API + SQLite
            │
            ├── SQLite (stable memory) ← replaces Firestore
            ├── Meta WhatsApp Cloud API ← dispatch/transport docs
            └── Google Sheets API ← stock calculations
```

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Flutter Web (Dart) |
| Backend | Express.js wrapped in Azle `Server()` |
| Database | SQLite via sql.js (asm.js build) |
| Persistence | ICP Stable Memory (`StableBTreeMap`) |
| Hosting | ICP Canisters (backend + frontend) |
| CI/CD | GitHub Actions |
| Push Notifications | HTTP Polling (replaces FCM) |
| WhatsApp | Meta Cloud API (existing account) |
| Stock Engine | Google Sheets API (unchanged) |

## Quick Start

### Prerequisites
- Node.js 20+
- Flutter 3.32+
- DFX SDK: `sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)"`

### Local Development
```bash
# 1. Install dependencies
npm install
cd cardamom_app && flutter pub get && cd ..

# 2. Start local ICP replica and deploy
chmod +x scripts/dev-start.sh
./scripts/dev-start.sh

# 3. Or manually:
dfx start --background --clean
dfx deploy
```

### Run Tests
```bash
npm test                          # All 227 backend tests
npm run test:unit                 # Unit tests only
cd cardamom_app && flutter test   # Flutter tests
```

### Deploy to ICP Mainnet
```bash
# Ensure you have cycles in your wallet
dfx deploy --network ic
```

## Project Structure

```
├── .github/workflows/       # CI/CD pipelines
│   ├── deploy-icp.yml       # Deploy to ICP on push to main
│   └── test.yml             # Run tests on PRs
├── backend/
│   ├── firebase/             # 25 modules (now using sqliteClient)
│   ├── firebaseClient.js     # Shim → delegates to sqliteClient
│   ├── featureFlags.js       # All flags set to ICP_SQLITE
│   ├── middleware/
│   ├── services/
│   └── utils/
├── cardamom_app/             # Flutter mobile/web app
│   ├── lib/
│   │   ├── screens/          # 46 UI screens
│   │   ├── services/         # API, auth, notifications
│   │   ├── models/
│   │   ├── widgets/
│   │   └── theme/
│   └── pubspec.yaml          # No Firebase dependencies
├── src/backend/
│   ├── index.ts              # Azle Server entry point
│   ├── database/
│   │   ├── sqliteClient.js   # Drop-in Firestore replacement
│   │   ├── stableMemory.js   # ICP stable memory persistence
│   │   ├── init.js           # DB initialization + seeding
│   │   └── schema.sql        # 30 SQLite tables
│   └── routes/               # 16 Express route modules
├── scripts/
│   ├── dev-start.sh          # Start local dev environment
│   ├── backup-data.sh        # Backup canister data
│   ├── export-firestore.js   # Export from original Firestore
│   └── import-to-sqlite.js   # Import into ICP SQLite
├── __tests__/                # 227 Jest tests
├── dfx.json                  # ICP canister configuration
├── server.js                 # Original Express server (reference)
└── package.json
```

## Environment Variables

```bash
# JWT Authentication
JWT_SECRET=your-jwt-secret

# ICP Canister Config
ICP_BACKEND_CANISTER_ID=xxxxx-xxxxx-xxxxx-xxxxx-cai
ICP_FRONTEND_CANISTER_ID=xxxxx-xxxxx-xxxxx-xxxxx-cai

# WhatsApp (Meta Cloud API — existing account)
WHATSAPP_TOKEN=your-meta-api-token
WHATSAPP_PHONE_NUMBER_ID=your-phone-number-id

# Google Sheets (stock calculations)
SPREADSHEET_ID=your-spreadsheet-id
GOOGLE_CREDENTIALS_JSON=base64-encoded-credentials

# Logo URL (for PDFs)
LOGO_URL=https://your-logo-url.com/logo.png
```

## GitHub Actions Secrets Required

| Secret | Description |
|---|---|
| `DFX_IDENTITY_PEM` | ICP deploy identity PEM key |
| `ICP_WALLET_ID` | Cycles wallet canister ID |

## Data Migration (from original Cardamom)

```bash
# 1. Export from Firestore (run from this repo)
#    Needs serviceAccountKey.json from original Cardamom repo
node scripts/export-firestore.js

# 2. Import into ICP SQLite
node scripts/import-to-sqlite.js
```

## Key Differences from Original Cardamom

| Feature | Original | ICP Version |
|---|---|---|
| Database | Firebase Firestore | SQLite (ICP stable memory) |
| Backend Host | Render.com | ICP Backend Canister |
| Frontend Host | Render.com static | ICP Asset Canister |
| Push Notifications | Firebase Cloud Messaging | HTTP Polling (30s) |
| WebSockets | Socket.IO | HTTP Polling |
| Auth | JWT + Firebase Admin | JWT only |
| File Storage | Firebase Storage | CDN URLs / base64 |
| WhatsApp | Same Meta API | Same Meta API ✓ |
| Google Sheets | Same API | Same API ✓ |

## License

Private — Emperor Spices
