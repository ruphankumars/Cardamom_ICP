/**
 * Migration Script: Stock Adjustments
 * Sheets → Firestore (Phase 5)
 * 
 * Run ONCE: node backend/migrations/migrateStock.js
 */

require('dotenv').config({ path: require('path').join(__dirname, '../../.env') });
const sheetsClient = require('../sheetsClient');
const CFG = require('../config');
const { getDb, initializeFirebase } = require('../firebaseClient');

async function main() {
    console.log('╔══════════════════════════════════════════════╗');
    console.log('║  PHASE 5 MIGRATION: Stock Adjustments         ║');
    console.log('╚══════════════════════════════════════════════╝');

    try {
        initializeFirebase();
        const db = getDb();

        const rows = await sheetsClient.readRange(`${CFG.sheets.adjust}!A:E`, { cache: false });
        if (!rows || rows.length <= 1) {
            console.log('No stock adjustments found. Skipping.');
            process.exit(0);
        }

        const headers = rows[0];
        const dataRows = rows.slice(1);
        console.log(`Found ${dataRows.length} adjustments`);

        const iTs = headers.indexOf('Timestamp') >= 0 ? headers.indexOf('Timestamp') : 0;
        const iType = headers.indexOf('Type') >= 0 ? headers.indexOf('Type') : 1;
        const iGrade = headers.indexOf('Grade') >= 0 ? headers.indexOf('Grade') : 2;
        const iDelta = headers.indexOf('Delta Kgs') >= 0 ? headers.indexOf('Delta Kgs') : 3;
        const iNotes = headers.indexOf('Notes') >= 0 ? headers.indexOf('Notes') : 4;

        let batch = db.batch(), count = 0, migrated = 0;

        for (const row of dataRows) {
            const type = String(row[iType] || '').trim();
            const grade = String(row[iGrade] || '').trim();
            const delta = parseFloat(row[iDelta]);
            if (!type || !grade || isNaN(delta)) continue;

            batch.set(db.collection('stock_adjustments').doc(), {
                timestamp: row[iTs] || '',
                type, grade, deltaKgs: delta,
                notes: row[iNotes] || '',
                createdAt: new Date().toISOString()
            });
            migrated++;
            count++;

            if (count >= 400) {
                await batch.commit();
                batch = db.batch();
                count = 0;
            }
        }

        if (count > 0) await batch.commit();

        const verify = await db.collection('stock_adjustments').count().get();
        console.log(`\nMigrated: ${migrated}, Firestore count: ${verify.data().count}`);
        console.log('\nNext: Set FB_STOCK=true and restart');
    } catch (err) {
        console.error('MIGRATION FAILED:', err);
        process.exit(1);
    }
    process.exit(0);
}

main();
