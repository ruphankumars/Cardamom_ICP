/**
 * Migration Script: Tasks, Workers, Attendance, Expenses, Gate Passes
 * Sheets → Firestore (Phase 6)
 * 
 * Run ONCE: node backend/migrations/migratePhase6.js
 */
require('dotenv').config({ path: require('path').join(__dirname, '../../.env') });
const sheets = require('../sheetsClient');
const { getDb, initializeFirebase } = require('../firebaseClient');

async function migrateCollection(sheetRange, collectionName, rowToDoc, label) {
    console.log(`\n=== ${label} ===`);
    const rows = await sheets.readRange(sheetRange, { cache: false }).catch(() => []);
    if (!rows || rows.length <= 1) { console.log('  No data. Skipping.'); return 0; }
    const headers = rows[0]; const dataRows = rows.slice(1);
    console.log(`  Found ${dataRows.length} rows`);
    const db = getDb(); let batch = db.batch(), count = 0, migrated = 0;
    for (const row of dataRows) {
        const doc = rowToDoc(row, headers);
        if (!doc) continue;
        const id = doc._id || doc.id || `${Date.now()}-${Math.random().toString(36).substr(2, 6)}`;
        delete doc._id;
        batch.set(db.collection(collectionName).doc(String(id)), doc, { merge: true });
        migrated++; count++;
        if (count >= 400) { await batch.commit(); batch = db.batch(); count = 0; }
    }
    if (count > 0) await batch.commit();
    const v = await db.collection(collectionName).count().get();
    console.log(`  Migrated: ${migrated}, Firestore: ${v.data().count}`);
    return migrated;
}

function safeJson(val) { try { return val ? JSON.parse(val) : null; } catch { return null; } }

async function main() {
    console.log('╔══════════════════════════════════════════════╗');
    console.log('║  PHASE 6 MIGRATION: Tasks/Workers/Expenses/GP ║');
    console.log('╚══════════════════════════════════════════════╝');
    initializeFirebase();

    // 1. Tasks
    await migrateCollection('app_tasks!A:AD', 'tasks', (row) => {
        if (!row[0]) return null;
        return {
            _id: row[0], id: row[0], title: row[1] || '', description: row[2] || '', notes: row[3] || '',
            url: row[4] || '', assigneeId: row[5] || '', assigneeName: row[6] || '',
            deadline: row[7] || null, dueDate: row[8] || null, dueTime: row[9] || null,
            hasDueDate: row[10] === 'true', hasDueTime: row[11] === 'true', isUrgent: row[12] === 'true',
            repeatType: row[13] || 'none', endRepeat: row[14] || 'never', endRepeatDate: row[15] || null,
            endRepeatCount: row[16] ? parseInt(row[16]) : null, earlyReminder: row[17] || 'none',
            listName: row[18] || 'Tasks', tags: safeJson(row[19]) || [], subtasks: safeJson(row[20]) || [],
            isFlagged: row[21] === 'true', priority: row[22] || 'none', status: row[23] || 'pending',
            hasLocation: row[24] === 'true', locationData: safeJson(row[25]),
            whenMessaging: row[26] === 'true', imageUrl: row[27] || null,
            createdAt: row[28] || new Date().toISOString(), updatedAt: row[29] || new Date().toISOString()
        };
    }, 'TASKS');

    // 2. Workers
    await migrateCollection('Workers!A:H', 'workers', (row) => {
        if (!row[0]) return null;
        return { _id: row[0], id: row[0], name: row[1] || '', phone: row[2] || '', baseDailyWage: Number(row[3]) || 0, team: row[4] || '', status: row[5] || 'Active', joinDate: row[6] || '', notes: row[7] || '' };
    }, 'WORKERS');

    // 3. Attendance
    await migrateCollection('Attendance!A:L', 'attendance', (row) => {
        if (!row[0]) return null;
        const id = row[2] && row[1] ? `${row[1]}_${row[2]}` : row[0];
        return { _id: id, id: row[0], date: row[1] || '', workerId: row[2] || '', workerName: row[3] || '', status: row[4] || 'present', otHours: Number(row[5]) || 0, otReason: row[6] || '', wagePaid: Number(row[7]) || 0, markedBy: row[8] || '', markedAt: row[9] || '', updatedBy: row[10] || '', updatedAt: row[11] || '' };
    }, 'ATTENDANCE');

    // 4. Expenses
    await migrateCollection('Expenses!A:N', 'expenses', (row) => {
        if (!row[0]) return null;
        return { _id: row[0], id: row[0], date: row[1] || '', workerWages: Number(row[2]) || 0, totalVariable: Number(row[3]) || 0, totalMisc: Number(row[4]) || 0, grandTotal: Number(row[5]) || 0, status: row[6] || 'draft', submittedBy: row[7] || '', submittedAt: row[8] || '', approvedBy: row[9] || '', approvedAt: row[10] || '', rejectionReason: row[11] || '', createdAt: row[12] || new Date().toISOString(), updatedAt: row[13] || new Date().toISOString() };
    }, 'EXPENSES');

    // 5. Expense Items
    await migrateCollection('ExpenseItems!A:J', 'expense_items', (row) => {
        if (!row[0]) return null;
        return { _id: row[0], id: row[0], sheetId: row[1] || '', category: row[2] || '', subCategory: row[3] || '', quantity: Number(row[4]) || 0, rate: Number(row[5]) || 0, amount: Number(row[6]) || 0, note: row[7] || '', receiptUrl: row[8] || '', createdAt: row[9] || '' };
    }, 'EXPENSE_ITEMS');

    // 6. Gate Passes
    await migrateCollection('GatePasses!A:AB', 'gate_passes', (row) => {
        if (!row[0]) return null;
        return { _id: row[0], id: row[0], passNumber: row[1] || '', type: row[2] || '', packaging: row[3] || '', bagCount: Number(row[4]) || 0, boxCount: Number(row[5]) || 0, bagWeight: Number(row[6]) || 0, boxWeight: Number(row[7]) || 0, calculatedWeight: Number(row[8]) || 0, actualWeight: Number(row[9]) || 0, finalWeight: Number(row[10]) || 0, purpose: row[11] || '', notes: row[12] || '', vehicleNumber: row[13] || '', driverName: row[14] || '', driverPhone: row[15] || '', status: row[16] || 'pending', requestedBy: row[17] || '', requestedAt: row[18] || '', approvedBy: row[19] || '', approvedAt: row[20] || '', signatureData: row[21] || '', rejectionReason: row[22] || '', actualEntryTime: row[23] || '', actualExitTime: row[24] || '', isCompleted: row[25] === 'true', completedBy: row[26] || '', updatedAt: row[27] || '' };
    }, 'GATE PASSES');

    console.log('\n========================================');
    console.log('  PHASE 6 MIGRATION COMPLETE');
    console.log('  Next: Set FB_TASKS=true FB_ATTENDANCE=true FB_EXPENSES=true FB_GATEPASSES=true');
    console.log('========================================');
    process.exit(0);
}

main().catch(e => { console.error('FAILED:', e); process.exit(1); });
