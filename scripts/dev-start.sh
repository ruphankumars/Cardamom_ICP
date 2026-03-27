#!/bin/bash
# Start local ICP development environment
# Usage: ./scripts/dev-start.sh

set -e

echo "=== Cardamom ICP — Local Development ==="
echo ""

# Check dfx is installed
if ! command -v dfx &> /dev/null; then
    echo "ERROR: dfx not found. Install it:"
    echo '  sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)"'
    exit 1
fi

# Check node_modules
if [ ! -d "node_modules" ]; then
    echo "Installing Node.js dependencies..."
    npm install
fi

# Start local ICP replica
echo "Starting local ICP replica..."
dfx start --background --clean 2>/dev/null || dfx start --background

# Deploy canisters
echo "Deploying canisters to local replica..."
dfx deploy

# Print URLs
BACKEND_ID=$(dfx canister id backend)
FRONTEND_ID=$(dfx canister id frontend)

echo ""
echo "=== Local Development Ready ==="
echo "Backend:  http://localhost:4943/?canisterId=$BACKEND_ID"
echo "Frontend: http://localhost:4943/?canisterId=$FRONTEND_ID"
echo "Health:   http://localhost:4943/?canisterId=$BACKEND_ID/api/health"
echo ""
echo "To stop: dfx stop"
