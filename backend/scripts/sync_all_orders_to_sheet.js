#!/usr/bin/env node
/**
 * Sync All Orders to Google Sheets — "AllOrders" sheet
 *
 * Reads all orders from Firestore (orders, cart_orders, packed_orders)
 * and writes them to an "AllOrders" sheet in Google Sheets.
 *
 * Can be run as:
 *   1. Standalone script:  node backend/scripts/sync_all_orders_to_sheet.js
 *   2. API endpoint:       POST /api/admin/sync-allorders (via server.js)
 */

const sheets = require('../sheetsClient');
const { getDb } = require('../firebaseClient');

const SHEET_NAME = 'AllOrders';
const HEADERS = [
    'Order Date', 'Billing From', 'Client', 'Lot', 'Grade',
    'Bag / Box', 'No', 'Kgs', 'Price', 'Brand',
    'Status', 'Notes', 'Packed Date', 'Source'
];

async function syncAllOrders() {
    console.log('[Sync] Reading all orders from Firestore...');

    const db = getDb();

    const [ordersSnap, cartSnap, packedSnap] = await Promise.all([
        db.collection('orders').get(),
        db.collection('cart_orders').get(),
        db.collection('packed_orders').get(),
    ]);

    const rows = [];

    // 1. Pending orders
    ordersSnap.docs.forEach(doc => {
        const d = doc.data();
        rows.push([
            d.orderDate || '',
            d.billingFrom || '',
            d.client || '',
            d.lot || '',
            d.grade || '',
            d.bagbox || '',
            Number(d.no) || 0,
            Number(d.kgs) || 0,
            Number(d.price) || 0,
            d.brand || '',
            d.status || 'Pending',
            d.notes || '',
            '',
            'Pending'
        ]);
    });

    // 2. Cart orders (in progress)
    cartSnap.docs.forEach(doc => {
        const d = doc.data();
        rows.push([
            d.orderDate || '',
            d.billingFrom || '',
            d.client || '',
            d.lot || '',
            d.grade || '',
            d.bagbox || '',
            Number(d.no) || 0,
            Number(d.kgs) || 0,
            Number(d.price) || 0,
            d.brand || '',
            d.status || 'On Progress',
            d.notes || '',
            d.packedDate || '',
            'On Progress'
        ]);
    });

    // 3. Packed/archived orders (done)
    packedSnap.docs.forEach(doc => {
        const d = doc.data();
        rows.push([
            d.orderDate || '',
            d.billingFrom || '',
            d.client || '',
            d.lot || '',
            d.grade || '',
            d.bagbox || '',
            Number(d.no) || 0,
            Number(d.kgs) || 0,
            Number(d.price) || 0,
            d.brand || '',
            d.status || 'Done',
            d.notes || '',
            d.packedDate || '',
            'Done'
        ]);
    });

    // Sort by Order Date descending, then by Client
    rows.sort((a, b) => {
        const dateA = String(a[0]);
        const dateB = String(b[0]);
        if (dateA !== dateB) return dateB.localeCompare(dateA);
        return String(a[2]).localeCompare(String(b[2]));
    });

    // Ensure the sheet exists
    await sheets.ensureSheet(SHEET_NAME, HEADERS);

    // Clear existing data (keep headers)
    await sheets.clearRange(`${SHEET_NAME}!A2:N`);

    // Write all rows
    if (rows.length > 0) {
        await sheets.writeRange(`${SHEET_NAME}!A2`, rows);
    }

    const summary = {
        pending: ordersSnap.size,
        onProgress: cartSnap.size,
        done: packedSnap.size,
        total: rows.length
    };

    console.log(`[Sync] Done! ${rows.length} orders synced to "${SHEET_NAME}" sheet.`);
    return summary;
}

module.exports = { syncAllOrders };

// If run directly as a script
if (require.main === module) {
    require('dotenv').config();
    syncAllOrders()
        .then(s => {
            console.log(`  - Pending: ${s.pending}`);
            console.log(`  - On Progress: ${s.onProgress}`);
            console.log(`  - Done: ${s.done}`);
            process.exit(0);
        })
        .catch(err => {
            console.error('[Sync] Fatal error:', err);
            process.exit(1);
        });
}
