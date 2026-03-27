# Cardamom ICP Deployment Guide

## Prerequisites

- dfx 0.31.0+ (`dfx --version`)
- Node.js 18+ (`node --version`)
- Flutter 3.41+ (`flutter --version`)
- ICP cycles wallet (for mainnet)

## Local Development

```bash
# Start local replica
dfx start --clean --background

# Deploy both canisters
JWT_SECRET=your_jwt_secret dfx deploy

# Test
curl http://127.0.0.1:4943/health?canisterId=<BACKEND_CANISTER_ID>
open http://<FRONTEND_CANISTER_ID>.localhost:4943/
```

## Data Migration (Firestore → SQLite)

### Step 1: Export from Firestore

Place your Firebase `serviceAccountKey.json` in the project root, then:

```bash
# Export all collections (paginated, batches of 500)
node scripts/export-firestore.js

# Or export specific collections
node scripts/export-firestore.js users orders clients

# List all known collections
node scripts/export-firestore.js --list
```

Output: `data/firestore-export/<collection>.json`

### Step 2: Import into SQLite

```bash
# Import all exported collections
node scripts/import-to-sqlite.js

# Import specific collections
node scripts/import-to-sqlite.js users orders

# Preview without writing
node scripts/import-to-sqlite.js --dry-run

# Clear tables before import
node scripts/import-to-sqlite.js --clear
```

Output: `data/cardamom.db`

The canister loads from stable memory on startup. For local dev, `init.js`
seeds a fresh admin user if the database is empty.

## ICP Mainnet Deployment

### Step 1: Get cycles

```bash
# Check your identity
dfx identity whoami
dfx identity get-principal

# If you need a new identity
dfx identity new cardamom-prod
dfx identity use cardamom-prod

# Get cycles (requires ICP tokens)
# Option A: Via NNS app at https://nns.ic0.app
# Option B: Via dfx
dfx ledger create-canister <YOUR_PRINCIPAL> --amount 5.0 --network ic
dfx identity deploy-wallet <CANISTER_ID> --network ic
```

### Step 2: Set environment variables

```bash
export JWT_SECRET="your_production_jwt_secret_minimum_32_chars"
export NODE_ENV="production"
export META_WHATSAPP_TOKEN="your_meta_token"
export META_WHATSAPP_PHONE_ID="your_phone_id"
export META_WHATSAPP_SYGT_PHONE_ID="your_sygt_phone_id"
export GOOGLE_SERVICE_ACCOUNT_EMAIL="your_service_account@..."
export GOOGLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n..."
export OUTSTANDING_SYGT_SHEET_ID="your_sheet_id"
export OUTSTANDING_ESPL_SHEET_ID="your_sheet_id"
export SPREADSHEET_ID="your_spreadsheet_id"
export LOGO_URL="https://<FRONTEND_CANISTER_ID>.ic0.app/images/brand/espl_logo.png"
```

### Step 3: Build Flutter web

```bash
cd cardamom_app
flutter build web --release
cd ..
```

### Step 4: Deploy to mainnet

```bash
# Deploy both canisters
dfx deploy --network ic

# Or deploy individually
dfx deploy backend --network ic
dfx deploy frontend --network ic
```

### Step 5: Update Flutter with production canister IDs

After mainnet deploy, update the canister ID in:
- `cardamom_app/lib/services/api_service.dart` — `_cloudUrl`
- `cardamom_app/lib/services/connectivity_service.dart` — `_primaryHealthUrl`

Then rebuild and redeploy frontend:
```bash
cd cardamom_app && flutter build web --release && cd ..
dfx deploy frontend --network ic
```

### Step 6: Verify

```bash
# Health check
curl https://<BACKEND_CANISTER_ID>.ic0.app/health

# Frontend
open https://<FRONTEND_CANISTER_ID>.ic0.app
```

## Canister IDs

| Canister | Local | Mainnet |
|----------|-------|---------|
| backend  | uxrrr-q7777-77774-qaaaq-cai | _(deploy to get)_ |
| frontend | u6s2n-gx777-77774-qaaba-cai | _(deploy to get)_ |

## Architecture

```
Flutter Web App (frontend canister)
        ↓ REST API
Express + SQLite (backend canister)
        ↓ Stable Memory
StableBTreeMap (survives upgrades)
```

- **Backend**: Azle Server() wrapping Express, sql.js (asm.js build) for SQLite
- **Frontend**: Flutter web compiled to JS, served from asset canister
- **Persistence**: Database auto-persists to StableBTreeMap after writes, pre-upgrade hook ensures data survives canister upgrades
