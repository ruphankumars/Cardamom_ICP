/**
 * Migration Script: Orders, Cart, Packed Orders
 * Sheets → Firestore (Phase 4)
 * 
 * Run ONCE: node backend/migrations/migrateOrders.js
 */

require('dotenv').config({ path: require('path').join(__dirname, '../../.env') });
const sheetsClient = require('../sheetsClient');
const CFG = require('../config');
const { getDb, initializeFirebase } = require('../firebaseClient');

async function migrateSheet(sheetRange, collectionName, label) {
    console.log(`\n========== MIGRATING ${label} ==========\n`);

    const rows = await sheetsClient.readRange(sheetRange, { cache: false });
    if (!rows || rows.length <= 1) {
        console.log(`No ${label} data found. Skipping.`);
        return { migrated: 0, skipped: 0 };
    }

    const headers = rows[0];
    const dataRows = rows.slice(1);
    console.log(`Found ${dataRows.length} rows (headers: ${headers.join(', ')})`);

    const db = getDb();
    let migrated = 0, skipped = 0;
    const BATCH_SIZE = 400;
    let batch = db.batch();
    let batchCount = 0;

    // Column indices
    const col = (name) => {
        let idx = headers.indexOf(name);
        if (idx === -1 && name === 'Bag / Box') { idx = headers.indexOf('Bag/Box'); }
        if (idx === -1 && name === 'Bag / Box') { idx = headers.indexOf('Bag Box'); }
        return idx;
    };

    const iOrderDate = col('Order Date');
    const iBilling = col('Billing From');
    const iClient = col('Client');
    const iLot = col('Lot');
    const iGrade = col('Grade');
    const iBagbox = col('Bag / Box');
    const iNo = col('No');
    const iKgs = col('Kgs');
    const iPrice = col('Price');
    const iBrand = col('Brand');
    const iStatus = col('Status');
    const iNotes = col('Notes');
    const iPackedDate = headers.findIndex(h => {
        const lh = String(h || '').toLowerCase();
        return lh === 'packed date' || lh === 'packaged date';
    });

    for (const row of dataRows) {
        const isEmpty = row.every(cell => !cell || String(cell).trim() === '');
        if (isEmpty) { skipped++; continue; }

        const client = iClient >= 0 ? row[iClient] : '';
        if (!client) { skipped++; continue; }

        const data = {
            orderDate: iOrderDate >= 0 ? (row[iOrderDate] || '') : '',
            billingFrom: iBilling >= 0 ? (row[iBilling] || '') : '',
            client: client,
            lot: iLot >= 0 ? (row[iLot] || '') : '',
            grade: iGrade >= 0 ? (row[iGrade] || '') : '',
            bagbox: iBagbox >= 0 ? (row[iBagbox] || '') : '',
            no: iNo >= 0 ? (Number(row[iNo]) || 0) : 0,
            kgs: iKgs >= 0 ? (Number(row[iKgs]) || 0) : 0,
            price: iPrice >= 0 ? (Number(row[iPrice]) || 0) : 0,
            brand: iBrand >= 0 ? (row[iBrand] || '') : '',
            status: iStatus >= 0 ? (row[iStatus] || 'Pending') : 'Pending',
            notes: iNotes >= 0 ? (row[iNotes] || '') : '',
            createdAt: new Date().toISOString()
        };

        if (iPackedDate >= 0 && row[iPackedDate]) {
            data.packedDate = row[iPackedDate];
        }

        const docRef = db.collection(collectionName).doc();
        batch.set(docRef, data);
        migrated++;
        batchCount++;

        if (batchCount >= BATCH_SIZE) {
            await batch.commit();
            console.log(`  Committed batch of ${batchCount}`);
            batch = db.batch();
            batchCount = 0;
        }
    }

    if (batchCount > 0) {
        await batch.commit();
        console.log(`  Committed final batch of ${batchCount}`);
    }

    const verify = await db.collection(collectionName).count().get();
    console.log(`Verification: Sheets=${dataRows.length}, Firestore=${verify.data().count}, Migrated=${migrated}, Skipped=${skipped}`);
    return { migrated, skipped };
}

async function main() {
    console.log('╔══════════════════════════════════════════════╗');
    console.log('║  PHASE 4 MIGRATION: Orders + Cart + Packed   ║');
    console.log('╚══════════════════════════════════════════════╝');

    try {
        initializeFirebase();

        const r1 = await migrateSheet(`${CFG.sheets.orderBook}!A:L`, 'orders', 'PENDING ORDERS (sygt_order_book)');
        const r2 = await migrateSheet(`${CFG.sheets.cart}!A:M`, 'cart_orders', 'CART ORDERS');
        const r3 = await migrateSheet(`${CFG.sheets.packed}!A:M`, 'packed_orders', 'PACKED ORDERS');

        console.log('\n========================================');
        console.log('  MIGRATION COMPLETE');
        console.log('========================================');
        console.log(`  Orders:  ${r1.migrated} migrated, ${r1.skipped} skipped`);
        console.log(`  Cart:    ${r2.migrated} migrated, ${r2.skipped} skipped`);
        console.log(`  Packed:  ${r3.migrated} migrated, ${r3.skipped} skipped`);
        console.log('\n  Next: Set FB_ORDERS=true and restart');
    } catch (err) {
        console.error('\nMIGRATION FAILED:', err);
        process.exit(1);
    }
    process.exit(0);
}

main();
