/**
 * Migration Script: Users & Approval Requests
 * Sheets → Firestore (Phase 2)
 * 
 * Run this ONCE before flipping the feature flags:
 *   node backend/migrations/migrateUsersAndApprovals.js
 * 
 * Prerequisites:
 *   - Firebase credentials configured (env vars or serviceAccountKey.json)
 *   - Google Sheets credentials configured (env vars or credentials.json)
 *   - Both systems accessible from this machine
 * 
 * What this does:
 *   1. Reads all users from Google Sheets (app_users)
 *   2. Writes them to Firestore (users collection)
 *   3. Reads all approval requests from Google Sheets (approval_requests)
 *   4. Writes them to Firestore (approval_requests collection)
 *   5. Verifies counts match
 * 
 * Safe to run multiple times — uses set() with merge, so it won't duplicate.
 */

require('dotenv').config({ path: require('path').join(__dirname, '../../.env') });

const sheetsClient = require('../sheetsClient');
const { getDb, initializeFirebase } = require('../firebaseClient');

// ============================================================================
// MIGRATE USERS
// ============================================================================

async function migrateUsers() {
    console.log('\n========================================');
    console.log('  MIGRATING USERS (app_users → users)');
    console.log('========================================\n');

    // Read from Sheets
    const rows = await sheetsClient.readRange('app_users!A:I', { cache: false });
    if (!rows || rows.length <= 1) {
        console.log('No users found in Google Sheets. Skipping.');
        return { migrated: 0, skipped: 0 };
    }

    const dataRows = rows.slice(1); // Skip header
    console.log(`Found ${dataRows.length} users in Google Sheets`);

    const db = getDb();
    const batch = db.batch();
    let migrated = 0;
    let skipped = 0;

    for (const row of dataRows) {
        if (!row || row.length < 5 || !row[0]) {
            skipped++;
            continue;
        }

        const id = parseInt(row[0]) || 0;
        if (id === 0) {
            skipped++;
            continue;
        }

        let pageAccess = null;
        try {
            if (row[7]) pageAccess = JSON.parse(row[7]);
        } catch (e) {
            console.warn(`  Warning: Could not parse pageAccess for user ${row[1]}: ${e.message}`);
        }

        const userData = {
            id: id,
            username: row[1] || '',
            password: row[2] || '',  // Keep existing hash (SHA-256 or bcrypt — will auto-upgrade on login)
            email: row[3] || '',
            role: row[4] || 'employee',
            clientName: row[5] || '',
            fullName: row[6] || '',
            pageAccess: pageAccess,
            createdAt: row[8] || new Date().toISOString(),
        };

        const docRef = db.collection('users').doc(String(id));
        batch.set(docRef, userData, { merge: true });
        migrated++;

        console.log(`  [${migrated}] ${userData.username} (${userData.role}) → users/${id}`);
    }

    if (migrated > 0) {
        await batch.commit();
        console.log(`\nCommitted ${migrated} users to Firestore`);
    }

    // Verify
    const verifySnap = await db.collection('users').count().get();
    const firestoreCount = verifySnap.data().count;
    console.log(`Verification: Sheets=${dataRows.length}, Firestore=${firestoreCount}, Migrated=${migrated}, Skipped=${skipped}`);

    return { migrated, skipped };
}

// ============================================================================
// MIGRATE APPROVAL REQUESTS
// ============================================================================

async function migrateApprovalRequests() {
    console.log('\n========================================');
    console.log('  MIGRATING APPROVAL REQUESTS');
    console.log('========================================\n');

    // Read from Sheets — use A:P to include dismissed column
    const rows = await sheetsClient.readRange('approval_requests!A:P', { cache: false });
    if (!rows || rows.length <= 1) {
        console.log('No approval requests found in Google Sheets. Skipping.');
        return { migrated: 0, skipped: 0 };
    }

    const dataRows = rows.slice(1); // Skip header
    console.log(`Found ${dataRows.length} approval requests in Google Sheets`);

    const db = getDb();
    let migrated = 0;
    let skipped = 0;

    // Firestore batch has a 500-operation limit, so batch in chunks
    const BATCH_SIZE = 400;
    let batch = db.batch();
    let batchCount = 0;

    for (const row of dataRows) {
        if (!row || !row[0]) {
            skipped++;
            continue;
        }

        const requestId = row[0];

        // Parse JSON fields safely
        let resourceData = null;
        let proposedChanges = null;
        try {
            if (row[6]) resourceData = JSON.parse(row[6]);
        } catch (e) {
            console.warn(`  Warning: Could not parse resourceData for ${requestId}: ${e.message}`);
        }
        try {
            if (row[7]) proposedChanges = JSON.parse(row[7]);
        } catch (e) {
            console.warn(`  Warning: Could not parse proposedChanges for ${requestId}: ${e.message}`);
        }

        const requestData = {
            id: requestId,
            requesterId: row[1] || '',
            requesterName: row[2] || '',
            actionType: row[3] || '',
            resourceType: row[4] || '',
            resourceId: row[5] || '',
            resourceData: resourceData,
            proposedChanges: proposedChanges,
            reason: row[8] || '',
            status: row[9] || 'pending',
            rejectionReason: row[10] || null,
            createdAt: row[11] || new Date().toISOString(),
            updatedAt: row[12] || new Date().toISOString(),
            processedBy: row[13] || null,
            processedAt: row[14] || null,
            dismissed: row[15] === 'true' || row[15] === true,
        };

        const docRef = db.collection('approval_requests').doc(requestId);
        batch.set(docRef, requestData, { merge: true });
        migrated++;
        batchCount++;

        const statusIcon = requestData.status === 'pending' ? '⏳' :
            requestData.status === 'approved' ? '✅' : '❌';
        console.log(`  [${migrated}] ${statusIcon} ${requestId.substring(0, 8)}... by ${requestData.requesterName} (${requestData.status}${requestData.dismissed ? ', dismissed' : ''})`);

        // Commit batch if reaching limit
        if (batchCount >= BATCH_SIZE) {
            await batch.commit();
            console.log(`  Committed batch of ${batchCount} documents`);
            batch = db.batch();
            batchCount = 0;
        }
    }

    // Commit remaining
    if (batchCount > 0) {
        await batch.commit();
        console.log(`  Committed final batch of ${batchCount} documents`);
    }

    // Verify
    const verifySnap = await db.collection('approval_requests').count().get();
    const firestoreCount = verifySnap.data().count;
    console.log(`\nVerification: Sheets=${dataRows.length}, Firestore=${firestoreCount}, Migrated=${migrated}, Skipped=${skipped}`);

    return { migrated, skipped };
}

// ============================================================================
// MAIN
// ============================================================================

async function main() {
    console.log('╔══════════════════════════════════════════════╗');
    console.log('║  PHASE 2 MIGRATION: Sheets → Firestore      ║');
    console.log('║  Modules: Users + Approval Requests          ║');
    console.log('╚══════════════════════════════════════════════╝');

    try {
        initializeFirebase();

        const usersResult = await migrateUsers();
        const approvalsResult = await migrateApprovalRequests();

        console.log('\n========================================');
        console.log('  MIGRATION COMPLETE');
        console.log('========================================');
        console.log(`  Users:     ${usersResult.migrated} migrated, ${usersResult.skipped} skipped`);
        console.log(`  Approvals: ${approvalsResult.migrated} migrated, ${approvalsResult.skipped} skipped`);
        console.log('\n  Next steps:');
        console.log('  1. Verify data in Firebase Console (console.firebase.google.com)');
        console.log('  2. Set environment variables: FB_USERS=true FB_APPROVALS=true');
        console.log('  3. Restart the server');
        console.log('  4. Test login, approval create/approve/reject/dismiss flows');
        console.log('  5. If everything works, the old Sheets data can stay as backup');

    } catch (err) {
        console.error('\nMIGRATION FAILED:', err);
        process.exit(1);
    }

    process.exit(0);
}

main();
