#!/usr/bin/env node
/**
 * Export Firestore Data — Paginated (batches of 500)
 *
 * Exports all Firestore collections to JSON files in data/firestore-export/.
 * Each collection is saved as a separate JSON file containing an array of
 * { id, data } objects.
 *
 * Prerequisites:
 *   - Place your Firebase serviceAccountKey.json in the project root
 *     OR set GOOGLE_APPLICATION_CREDENTIALS env var
 *   - npm install firebase-admin (already in package.json)
 *
 * Usage:
 *   node scripts/export-firestore.js                    # Export all collections
 *   node scripts/export-firestore.js users orders       # Export specific collections
 *   node scripts/export-firestore.js --list             # List all collections
 *
 * The script fetches documents in batches of 500 to avoid hanging on large
 * collections. Progress is logged per batch.
 */

const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const BATCH_SIZE = 500;
const OUTPUT_DIR = path.join(__dirname, '..', 'data', 'firestore-export');

// All known Firestore collections (matches SQLite schema tables)
const ALL_COLLECTIONS = [
    'users',
    'orders',
    'cart_orders',
    'packed_orders',
    'client_requests',
    'rejected_offers',
    'approval_requests',
    'live_stock_entries',
    'stock_adjustments',
    'net_stock_cache',
    'sale_order_summary',
    'dispatch_documents',
    'transport_documents',
    'daily_transport_assignments',
    'tasks',
    'workers',
    'attendance',
    'expenses',
    'expense_items',
    'gate_passes',
    'settings',
    'dropdown_data',
    'client_contacts',
    'clients',
    'offer_prices',
    'client_name_mappings',
    'packedBoxes',
    'notifications',
    'whatsapp_send_logs',
    'counters',
    'lot_counters',
    'order_edit_history',
    'unarchive_requests',
];

// Subcollections: parent_collection -> subcollection name
const SUBCOLLECTIONS = {
    'client_requests': ['messages'],
};

// ---------------------------------------------------------------------------
// Firebase Init
// ---------------------------------------------------------------------------
function initFirebase() {
    // Try multiple credential sources
    const keyPath = path.join(__dirname, '..', 'serviceAccountKey.json');
    const backendKeyPath = path.join(__dirname, '..', 'backend', 'serviceAccountKey.json');

    if (fs.existsSync(keyPath)) {
        const serviceAccount = require(keyPath);
        admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
        console.log(`[Firebase] Initialized with ${keyPath}`);
    } else if (fs.existsSync(backendKeyPath)) {
        const serviceAccount = require(backendKeyPath);
        admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
        console.log(`[Firebase] Initialized with ${backendKeyPath}`);
    } else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
        admin.initializeApp({ credential: admin.credential.applicationDefault() });
        console.log(`[Firebase] Initialized with GOOGLE_APPLICATION_CREDENTIALS`);
    } else {
        console.error('ERROR: No Firebase credentials found.');
        console.error('Place serviceAccountKey.json in project root or set GOOGLE_APPLICATION_CREDENTIALS.');
        process.exit(1);
    }

    return admin.firestore();
}

// ---------------------------------------------------------------------------
// Paginated Export
// ---------------------------------------------------------------------------

/**
 * Export a single collection with pagination (batches of BATCH_SIZE).
 * Returns array of { id, data } objects.
 */
async function exportCollection(db, collectionName) {
    const docs = [];
    let lastDoc = null;
    let batchNum = 0;

    while (true) {
        let query = db.collection(collectionName)
            .orderBy('__name__')
            .limit(BATCH_SIZE);

        if (lastDoc) {
            query = query.startAfter(lastDoc);
        }

        const snapshot = await query.get();

        if (snapshot.empty) break;

        for (const doc of snapshot.docs) {
            docs.push({
                id: doc.id,
                data: doc.data(),
            });
        }

        lastDoc = snapshot.docs[snapshot.docs.length - 1];
        batchNum++;
        process.stdout.write(`  batch ${batchNum}: ${docs.length} docs so far\r`);

        // If we got fewer than BATCH_SIZE, we've reached the end
        if (snapshot.size < BATCH_SIZE) break;
    }

    console.log(`  ${collectionName}: ${docs.length} documents exported (${batchNum} batches)`);
    return docs;
}

/**
 * Export subcollections for each parent document.
 * Returns array of { id, parentId, data } objects.
 */
async function exportSubcollection(db, parentCollection, subcollectionName) {
    const allDocs = [];

    // First get all parent document IDs
    const parentDocs = [];
    let lastDoc = null;

    while (true) {
        let query = db.collection(parentCollection)
            .orderBy('__name__')
            .limit(BATCH_SIZE);

        if (lastDoc) query = query.startAfter(lastDoc);
        const snapshot = await query.get();
        if (snapshot.empty) break;

        for (const doc of snapshot.docs) {
            parentDocs.push(doc.id);
        }
        lastDoc = snapshot.docs[snapshot.docs.length - 1];
        if (snapshot.size < BATCH_SIZE) break;
    }

    console.log(`  Scanning ${parentDocs.length} parent docs in ${parentCollection}...`);

    // For each parent, export subcollection
    for (const parentId of parentDocs) {
        const subRef = db.collection(parentCollection).doc(parentId).collection(subcollectionName);
        const snapshot = await subRef.get();

        for (const doc of snapshot.docs) {
            allDocs.push({
                id: doc.id,
                parentId: parentId,
                data: doc.data(),
            });
        }
    }

    // Flatten subcollection name for file: client_requests/messages -> client_request_messages
    const flatName = `${parentCollection.replace(/s$/, '')}_${subcollectionName}`;
    console.log(`  ${flatName}: ${allDocs.length} documents exported`);
    return { flatName, docs: allDocs };
}

/**
 * Serialize Firestore-specific types (Timestamp, GeoPoint, etc.) to JSON-safe values.
 */
function serializeFirestoreValue(obj) {
    if (obj === null || obj === undefined) return obj;

    // Firestore Timestamp -> ISO string
    if (obj.toDate && typeof obj.toDate === 'function') {
        return obj.toDate().toISOString();
    }

    // Firestore GeoPoint
    if (obj.latitude !== undefined && obj.longitude !== undefined && obj._latitude !== undefined) {
        return { lat: obj.latitude, lng: obj.longitude };
    }

    // DocumentReference -> path string
    if (obj.path && obj.firestore) {
        return obj.path;
    }

    // Uint8Array / Buffer -> base64
    if (obj instanceof Uint8Array || Buffer.isBuffer(obj)) {
        return Buffer.from(obj).toString('base64');
    }

    // Array
    if (Array.isArray(obj)) {
        return obj.map(serializeFirestoreValue);
    }

    // Plain object
    if (typeof obj === 'object') {
        const result = {};
        for (const [key, value] of Object.entries(obj)) {
            result[key] = serializeFirestoreValue(value);
        }
        return result;
    }

    return obj;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
    const args = process.argv.slice(2);

    if (args.includes('--list')) {
        console.log('Known collections:');
        ALL_COLLECTIONS.forEach(c => console.log(`  - ${c}`));
        console.log('\nSubcollections:');
        for (const [parent, subs] of Object.entries(SUBCOLLECTIONS)) {
            subs.forEach(s => console.log(`  - ${parent}/{docId}/${s}`));
        }
        process.exit(0);
    }

    const collectionsToExport = args.length > 0
        ? args.filter(a => !a.startsWith('--'))
        : ALL_COLLECTIONS;

    const db = initFirebase();

    // Create output directory
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });

    console.log(`\n=== Firestore Export ===`);
    console.log(`Output: ${OUTPUT_DIR}`);
    console.log(`Collections: ${collectionsToExport.length}`);
    console.log(`Batch size: ${BATCH_SIZE}\n`);

    const summary = {};
    let totalDocs = 0;

    for (const collectionName of collectionsToExport) {
        try {
            const docs = await exportCollection(db, collectionName);

            // Serialize Firestore types
            const serialized = docs.map(d => ({
                id: d.id,
                data: serializeFirestoreValue(d.data),
            }));

            // Write to file
            const outPath = path.join(OUTPUT_DIR, `${collectionName}.json`);
            fs.writeFileSync(outPath, JSON.stringify(serialized, null, 2));

            summary[collectionName] = docs.length;
            totalDocs += docs.length;

            // Export subcollections if any
            if (SUBCOLLECTIONS[collectionName]) {
                for (const subName of SUBCOLLECTIONS[collectionName]) {
                    const { flatName, docs: subDocs } = await exportSubcollection(db, collectionName, subName);
                    const subSerialized = subDocs.map(d => ({
                        id: d.id,
                        parentId: d.parentId,
                        data: serializeFirestoreValue(d.data),
                    }));
                    const subOutPath = path.join(OUTPUT_DIR, `${flatName}.json`);
                    fs.writeFileSync(subOutPath, JSON.stringify(subSerialized, null, 2));
                    summary[flatName] = subDocs.length;
                    totalDocs += subDocs.length;
                }
            }
        } catch (err) {
            console.error(`  ERROR exporting ${collectionName}: ${err.message}`);
            summary[collectionName] = `ERROR: ${err.message}`;
        }
    }

    console.log(`\n=== Export Summary ===`);
    for (const [name, count] of Object.entries(summary)) {
        console.log(`  ${name}: ${typeof count === 'number' ? count + ' docs' : count}`);
    }
    console.log(`\nTotal: ${totalDocs} documents exported to ${OUTPUT_DIR}`);

    process.exit(0);
}

main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});
