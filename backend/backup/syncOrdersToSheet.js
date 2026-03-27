#!/usr/bin/env node
/**
 * Sync All Orders to Google Sheets — Backup Script
 *
 * Exports all orders from Firebase (orders, cart_orders, packed_orders)
 * to an "AllOrders" sheet in Google Sheets for backup and research.
 *
 * Usage:
 *   SPREADSHEET_ID=<your-id> node backend/backup/syncOrdersToSheet.js
 *
 * Prerequisites:
 *   - Firebase credentials in .env
 *   - Google Sheets credentials (credentials.json)
 *   - SPREADSHEET_ID environment variable
 */

require('dotenv').config();

const sheets = require('./sheetsBackupClient');
const { getDb } = require('../firebaseClient');

const SHEET_NAME = 'AllOrders';
const HEADERS = [
    'Order Date', 'Billing From', 'Client', 'Lot', 'Grade',
    'Bag / Box', 'No', 'Kgs', 'Price', 'Brand',
    'Status', 'Notes', 'Packed Date', 'Source'
];

async function syncAllOrders() {
    console.log('========================================');
    console.log('📦 Syncing All Orders to Google Sheets');
    console.log('========================================');

    if (!sheets.getSpreadsheetId()) {
        console.error('❌ Error: SPREADSHEET_ID not set in environment');
        console.log('   Set it with: SPREADSHEET_ID=<your-id> node backend/backup/syncOrdersToSheet.js');
        process.exit(1);
    }

    console.log('[Sync] Reading all orders from Firebase...');

    const db = getDb();

    // Read all three collections in parallel
    const [ordersSnap, cartSnap, packedSnap] = await Promise.all([
        db.collection('orders').get(),
        db.collection('cart_orders').get(),
        db.collection('packed_orders').get(),
    ]);

    const rows = [];

    // 1. Pending orders (from 'orders' collection)
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

    console.log(`✅ Pending orders: ${ordersSnap.size}`);

    // 2. Cart orders (in progress / today's dispatch)
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

    console.log(`✅ Cart orders (On Progress): ${cartSnap.size}`);

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

    console.log(`✅ Packed orders (Done): ${packedSnap.size}`);
    console.log(`📊 Total rows: ${rows.length}`);

    // Sort by Order Date descending, then by Client
    rows.sort((a, b) => {
        const dateA = String(a[0]);
        const dateB = String(b[0]);
        if (dateA !== dateB) return dateB.localeCompare(dateA);
        return String(a[2]).localeCompare(String(b[2]));
    });

    // Ensure the sheet exists with headers
    console.log(`[Sync] Ensuring "${SHEET_NAME}" sheet exists...`);
    await sheets.ensureSheet(SHEET_NAME, HEADERS);

    // Clear existing data (keep headers)
    console.log(`[Sync] Clearing old data...`);
    await sheets.clearRange(`${SHEET_NAME}!A2:N`);

    // Write all rows
    if (rows.length > 0) {
        console.log(`[Sync] Writing ${rows.length} rows to "${SHEET_NAME}"...`);
        await sheets.writeRange(`${SHEET_NAME}!A2`, rows);
    }

    console.log('========================================');
    console.log(`✅ DONE! ${rows.length} orders synced to "${SHEET_NAME}"`);
    console.log(`   - Pending:     ${ordersSnap.size}`);
    console.log(`   - On Progress: ${cartSnap.size}`);
    console.log(`   - Done:        ${packedSnap.size}`);
    console.log('========================================');
}

syncAllOrders().catch(err => {
    console.error('❌ Sync failed:', err.message);
    process.exit(1);
});
