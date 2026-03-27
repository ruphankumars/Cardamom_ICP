#!/usr/bin/env node
/**
 * One-time migration script: ClientContactDetails Sheet → Firestore client_contacts
 *
 * Usage:
 *   node backend/scripts/migrate_client_contacts.js
 *
 * Prerequisites:
 *   - SPREADSHEET_ID set in .env
 *   - Firebase credentials set in .env
 */

require('dotenv').config();

const sheets = require('../sheetsClient');
const { getDb } = require('../firebaseClient');

const COLLECTION = 'client_contacts';

async function migrate() {
    console.log('[Migration] Reading ClientContactDetails from Google Sheets...');

    const data = await sheets.readRange('ClientContactDetails!A:D');
    if (!data || data.length < 2) {
        console.log('[Migration] No data found in ClientContactDetails sheet.');
        return;
    }

    const headers = data[0];
    const nameCol = headers.findIndex(h => String(h).toLowerCase().includes('client') || String(h).toLowerCase().includes('name'));
    const phoneCol = headers.findIndex(h => String(h).toLowerCase().includes('contact') || String(h).toLowerCase().includes('phone'));
    const addressCol = 2; // Column C
    const gstinCol = 3;   // Column D

    console.log(`[Migration] Found ${data.length - 1} rows. Columns: name=${nameCol}, phone=${phoneCol}`);

    const db = getDb();
    const col = db.collection(COLLECTION);
    let created = 0;
    let skipped = 0;

    for (const row of data.slice(1)) {
        const name = String(row[nameCol] || '').trim();
        if (!name) { skipped++; continue; }

        const doc = {
            name,
            phone: String(row[phoneCol] || '').trim(),
            address: String(row[addressCol] || '').trim(),
            gstin: String(row[gstinCol] || '').trim(),
            _normalizedName: name.toLowerCase().replace(/\s+/g, ' ').trim(),
            _createdAt: new Date().toISOString(),
            _updatedAt: new Date().toISOString(),
        };

        await col.add(doc);
        created++;
        process.stdout.write(`\r[Migration] ${created} created, ${skipped} skipped`);
    }

    console.log(`\n[Migration] Done. Created ${created} documents, skipped ${skipped} empty rows.`);
}

migrate().catch(err => {
    console.error('[Migration] Fatal error:', err);
    process.exit(1);
});
