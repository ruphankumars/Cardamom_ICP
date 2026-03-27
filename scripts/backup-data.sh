#!/bin/bash
# Backup SQLite data from ICP canister
# Usage: ./scripts/backup-data.sh

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups/$TIMESTAMP"

echo "=== Cardamom ICP — Data Backup ==="
echo "Backup directory: $BACKUP_DIR"

mkdir -p "$BACKUP_DIR"

# Export all collections via API
BACKEND_URL=${1:-"http://localhost:4943"}
CANISTER_ID=${2:-$(dfx canister id backend 2>/dev/null || echo "")}

if [ -z "$CANISTER_ID" ]; then
    echo "Usage: ./scripts/backup-data.sh <backend_url> <canister_id>"
    echo "  or run from project root with local replica running"
    exit 1
fi

COLLECTIONS=(
    "users" "orders" "client_requests" "approval_requests"
    "stock" "tasks" "attendance" "expenses" "gate_passes"
    "dispatch_documents" "transport_documents" "dropdowns"
    "settings" "notifications" "packed_boxes" "offer_prices"
    "outstanding" "whatsapp_logs"
)

for col in "${COLLECTIONS[@]}"; do
    echo "  Backing up $col..."
    curl -s "$BACKEND_URL/?canisterId=$CANISTER_ID/api/$col" > "$BACKUP_DIR/$col.json" 2>/dev/null || echo "[]" > "$BACKUP_DIR/$col.json"
done

echo ""
echo "=== Backup Complete ==="
echo "Files saved to: $BACKUP_DIR"
ls -la "$BACKUP_DIR"
