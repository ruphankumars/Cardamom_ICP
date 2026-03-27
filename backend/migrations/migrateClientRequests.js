/**
 * Migration Script: Client Requests & Chat Messages
 * Sheets → Firestore (Phase 3)
 * 
 * Run ONCE: node backend/migrations/migrateClientRequests.js
 */

require('dotenv').config({ path: require('path').join(__dirname, '../../.env') });

const sheetsClient = require('../sheetsClient');
const CFG = require('../config');
const { getDb, initializeFirebase } = require('../firebaseClient');

async function migrateRequests() {
    console.log('\n========================================');
    console.log('  MIGRATING CLIENT REQUESTS');
    console.log('========================================\n');

    const rows = await sheetsClient.readRange(`${CFG.sheets.clientRequests}!A:N`, { cache: false });
    if (!rows || rows.length <= 1) {
        console.log('No client requests found. Skipping.');
        return { migrated: 0, skipped: 0 };
    }

    const headers = rows[0];
    const dataRows = rows.slice(1);
    console.log(`Found ${dataRows.length} requests (headers: ${headers.join(', ')})`);

    const db = getDb();
    let migrated = 0, skipped = 0;
    const BATCH_SIZE = 400;
    let batch = db.batch();
    let batchCount = 0;

    const getCol = (row, name) => {
        const idx = headers.indexOf(name);
        return idx >= 0 ? row[idx] : null;
    };

    for (const row of dataRows) {
        const requestId = getCol(row, 'Request ID');
        if (!requestId) { skipped++; continue; }

        let requestedItems = [], currentItems = [], finalItems = [];
        try { if (getCol(row, 'Requested Items JSON')) requestedItems = JSON.parse(getCol(row, 'Requested Items JSON')); } catch (e) { console.warn(`  Warn: Bad JSON in requestedItems for ${requestId}`); }
        try { if (getCol(row, 'Current Items JSON')) currentItems = JSON.parse(getCol(row, 'Current Items JSON')); } catch (e) { console.warn(`  Warn: Bad JSON in currentItems for ${requestId}`); }
        try { if (getCol(row, 'Final Items JSON')) finalItems = JSON.parse(getCol(row, 'Final Items JSON')); } catch (e) { console.warn(`  Warn: Bad JSON in finalItems for ${requestId}`); }

        const data = {
            requestId,
            clientUsername: getCol(row, 'Client Username') || '',
            clientName: getCol(row, 'Client Name') || '',
            requestType: getCol(row, 'Request Type') || '',
            status: getCol(row, 'Status') || 'OPEN',
            createdAt: getCol(row, 'Created At') || new Date().toISOString(),
            updatedAt: getCol(row, 'Updated At') || new Date().toISOString(),
            draftOwner: getCol(row, 'Current Draft Owner') || '',
            panelVersion: parseInt(getCol(row, 'Current Panel Version') || '1', 10),
            requestedItems,
            currentItems,
            finalItems,
            linkedOrderIds: getCol(row, 'Linked Order IDs') || '',
            cancelReason: getCol(row, 'Cancel Reason') || ''
        };

        const docRef = db.collection('client_requests').doc(requestId);
        batch.set(docRef, data, { merge: true });
        migrated++;
        batchCount++;

        const statusIcon = data.status === 'CONFIRMED' ? '✅' : data.status === 'CANCELLED' ? '❌' : data.status === 'CONVERTED_TO_ORDER' ? '📦' : '📋';
        console.log(`  [${migrated}] ${statusIcon} ${requestId} by ${data.clientName} (${data.status})`);

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

    const verify = await db.collection('client_requests').count().get();
    console.log(`\nVerification: Sheets=${dataRows.length}, Firestore=${verify.data().count}, Migrated=${migrated}, Skipped=${skipped}`);
    return { migrated, skipped };
}

async function migrateChats() {
    console.log('\n========================================');
    console.log('  MIGRATING CHAT MESSAGES');
    console.log('========================================\n');

    const rows = await sheetsClient.readRange(`${CFG.sheets.clientChats}!A:I`, { cache: false });
    if (!rows || rows.length <= 1) {
        console.log('No chat messages found. Skipping.');
        return { migrated: 0, skipped: 0 };
    }

    const headers = rows[0];
    const dataRows = rows.slice(1);
    console.log(`Found ${dataRows.length} chat messages`);

    const db = getDb();
    let migrated = 0, skipped = 0;

    const requestIdCol = headers.indexOf('Request ID');
    const messageIdCol = headers.indexOf('Message ID');
    const timestampCol = headers.indexOf('Timestamp');
    const senderRoleCol = headers.indexOf('Sender Role');
    const senderUsernameCol = headers.indexOf('Sender Username');
    const messageKindCol = headers.indexOf('Message Kind');
    const panelVersionCol = headers.indexOf('Panel Version');
    const panelSnapshotCol = headers.indexOf('Panel Snapshot JSON');
    const textMessageCol = headers.indexOf('Text Message');

    // Group by requestId for batch writes to subcollections
    const byRequest = {};
    for (const row of dataRows) {
        const reqId = row[requestIdCol];
        if (!reqId) { skipped++; continue; }
        if (!byRequest[reqId]) byRequest[reqId] = [];
        byRequest[reqId].push(row);
    }

    console.log(`Messages span ${Object.keys(byRequest).length} requests`);

    for (const [reqId, messages] of Object.entries(byRequest)) {
        let batch = db.batch();
        let count = 0;

        for (const row of messages) {
            const messageId = row[messageIdCol] || `MSG-${Date.now()}-${Math.random().toString(36).substr(2, 5)}`;
            let panelSnapshot = null;
            try {
                if (row[panelSnapshotCol] && String(row[panelSnapshotCol]).trim()) {
                    panelSnapshot = JSON.parse(row[panelSnapshotCol]);
                }
            } catch (e) { /* skip bad JSON */ }

            const msgData = {
                messageId,
                requestId: reqId,
                timestamp: row[timestampCol] || new Date().toISOString(),
                senderRole: row[senderRoleCol] || 'SYSTEM',
                senderUsername: row[senderUsernameCol] || 'unknown',
                messageKind: row[messageKindCol] || 'TEXT',
                panelVersion: row[panelVersionCol] ? parseInt(row[panelVersionCol], 10) : null,
                panelSnapshot,
                textMessage: row[textMessageCol] || null
            };

            const docRef = db.collection('client_requests').doc(reqId).collection('messages').doc(messageId);
            batch.set(docRef, msgData, { merge: true });
            count++;
            migrated++;

            if (count >= 400) {
                await batch.commit();
                batch = db.batch();
                count = 0;
            }
        }

        if (count > 0) await batch.commit();
        console.log(`  ${reqId}: ${messages.length} messages migrated`);
    }

    console.log(`\nTotal: ${migrated} messages migrated, ${skipped} skipped`);
    return { migrated, skipped };
}

async function main() {
    console.log('╔══════════════════════════════════════════════╗');
    console.log('║  PHASE 3 MIGRATION: Client Requests + Chat   ║');
    console.log('╚══════════════════════════════════════════════╝');

    try {
        initializeFirebase();
        const reqResult = await migrateRequests();
        const chatResult = await migrateChats();

        console.log('\n========================================');
        console.log('  MIGRATION COMPLETE');
        console.log('========================================');
        console.log(`  Requests: ${reqResult.migrated} migrated, ${reqResult.skipped} skipped`);
        console.log(`  Messages: ${chatResult.migrated} migrated, ${chatResult.skipped} skipped`);
        console.log('\n  Next: Set FB_CLIENT_REQUESTS=true and restart');
    } catch (err) {
        console.error('\nMIGRATION FAILED:', err);
        process.exit(1);
    }
    process.exit(0);
}

main();
