# AGENTS.md

This file provides guidance when working with code in the Cardamom ICP repository.

## Project Overview

Cardamom ICP is a green cardamom trading platform hosted entirely on the Internet Computer Protocol (ICP). It was migrated from a Firebase + Render.com stack to ICP, maintaining all original functionality.

**Architecture:**
- **Backend Canister** (Azle) — Express.js wrapped in Azle `Server()`, with SQLite replacing Firestore
- **Frontend Canister** (Assets) — Flutter web app served as static assets
- **Database** — SQLite via sql.js (asm.js build), persisted in ICP Stable Memory
- **External APIs** — Meta WhatsApp Cloud API, Google Sheets API (unchanged from original)

## Commands

### Backend Development
```bash
npm install          # Install dependencies
npm test             # Run all 227 tests with coverage
npm run test:unit    # Run unit tests only
npm run test:api     # Run API tests only
```

### ICP Development
```bash
dfx start --background --clean   # Start local ICP replica
dfx deploy                       # Deploy all canisters locally
dfx deploy backend               # Deploy backend only
dfx deploy frontend              # Deploy frontend only
dfx deploy --network ic          # Deploy to ICP mainnet
dfx stop                         # Stop local replica
```

### Flutter App (from `cardamom_app/` directory)
```bash
flutter pub get                  # Install dependencies
flutter build web --release      # Build for web
flutter test                     # Run tests
```

### Data Migration
```bash
node scripts/export-firestore.js   # Export Firestore → data/*.json
node scripts/import-to-sqlite.js   # Import data/*.json → SQLite
```

## Architecture Details

### Database Layer
- `src/backend/database/sqliteClient.js` — Drop-in replacement for `firebaseClient.js`
- Exposes identical Firestore-like API: `getDoc()`, `getDocs()`, `addDoc()`, `setDoc()`, `updateDoc()`, `deleteDoc()`, `runTransaction()`, `createBatch()`
- Query chaining: `.where()`, `.orderBy()`, `.limit()`, `.get()`
- Snapshot API with `.docs`, `.data()`, `.ref`

### Stable Memory Persistence
- `src/backend/database/stableMemory.js` — saves/loads SQLite DB to ICP stable memory
- All CRUD operations trigger debounced auto-persistence via `_afterWrite()` hooks
- Database survives canister upgrades via `preUpgrade` hook

### Route Modules
16 route modules under `src/backend/routes/`:
auth, orders, stock, users, workers, attendance, tasks, dropdowns, clients, clientRequests, approvalRequests, admin, reports, analytics, notifications, misc

### Notifications
Push notifications use HTTP polling (30s interval) instead of FCM:
- Backend: `GET /api/notifications/poll?userId=X`
- Flutter: `Timer.periodic` in `push_notification_service.dart`
- Backed by `notifications` table in SQLite

### Feature Flags
`backend/featureFlags.js`:
- `useFirestore()` → always returns `false`
- `useIcp()` → always returns `true`
- All modules use `ICP_SQLITE` backend

## Testing
Tests in `__tests__/` (227 tests, 6 suites). Jest config in `package.json`.
API tests build Express app from modular route files.

## ICP-Specific Gotchas
- No filesystem writes (use CDN URLs or base64 for images)
- No native WASM modules (pdfkit, jimp lazy-loaded with try/catch)
- `bcrypt` replaced with `bcryptjs` (pure JS)
- `sharp` replaced with SVG buffer fallback
- `socket.io` replaced with HTTP polling
- `express-rate-limit` replaced with inline implementation
- `process.exit()` replaced with `throw` (ICP compat)
- Environment variables set in `dfx.json` canister config
