#!/usr/bin/env node
/**
 * Export all Firestore collections to JSON files for ICP migration.
 * 
 * Usage: node scripts/export-firestore.js
 * 
 * Requires: Original Cardamom repo's serviceAccountKey.json or
 * FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY env vars.
 * 
 * Output: Creates data/*.json files for each collection.
 */

const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

// --- Configuration ---
const OUTPUT_DIR = path.join(__dirname, '..', 'data');
const SERVICE_ACCOUNT_PATH = path.join(__dirname, '..', '..', 'Cardamom', 'serviceAccountKey.json');

const COLLECTIONS = [
    'users',
    'orders',
    'client_requests',
    'approval_requests',
    'stock',
    'tasks',
    'attendance',
    'expenses',
    'gate_passes',
    'dispatch_documents',
    'transport_documents',
    'transport_assignments',
    'dropdowns',
    'settings',
    'counters',
    'packed_boxes',
    'offer_prices',
    'outstanding',
    'whatsapp_logs',
    'notifications',
    'analytics',
    'dashboard_cache',
    'client_contacts',
    'sync_log',
    'predictive_analytics',
    'ai_briefings',
];

// --- Initialize Firebase ---
function initFirebase() {
    if (process.env.FIREBASE_PROJECT_ID && process.env.FIREBASE_CLIENT_EMAIL && process.env.FIREBASE_PRIVATE_KEY) {
        admin.initializeApp({
            credential: admin.credential.cert({
                projectId: process.env.FIREBASE_PROJECT_ID,
                clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
                privateKey: process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n'),
            }),
        });
        console.log('[Export] Initialized Firebase from env vars');
    } else if (fs.existsSync(SERVICE_ACCOUNT_PATH)) {
        const serviceAccount = require(SERVICE_ACCOUNT_PATH);
        admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
        console.log('[Export] Initialized Firebase from serviceAccountKey.json');
    } else {
        console.error('[Export] ERROR: No Firebase credentials found!');
        console.error('  Set FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY');
        console.error(`  OR place serviceAccountKey.json at ${SERVICE_ACCOUNT_PATH}`);
        process.exit(1);
    }
}

// --- Serialize Firestore types to plain JSON ---
function serializeValue(val) {
    if (val === null || val === undefined) return null;
    if (val instanceof admin.firestore.Timestamp) {
        return { _type: 'timestamp', value: val.toDate().toISOString() };
    }
    if (val instanceof admin.firestore.GeoPoint) {
        return { _type: 'geopoint', lat: val.latitude, lng: val.longitude };
    }
    if (val instanceof admin.firestore.DocumentReference) {
        return { _type: 'ref', path: val.path };
    }
    if (Buffer.isBuffer(val)) {
        return { _type: 'bytes', value: val.toString('base64') };
    }
    if (Array.isArray(val)) {
        return val.map(serializeValue);
    }
    if (typeof val === 'object' && val !== null) {
        const result = {};
        for (const [k, v] of Object.entries(val)) {
            result[k] = serializeValue(v);
        }
        return result;
    }
    return val;
}

// --- Export a single collection ---
async function exportCollection(db, collectionName) {
    try {
        const snapshot = await db.collection(collectionName).get();
        if (snapshot.empty) {
            console.log(`  [${collectionName}] — empty (0 docs), skipping`);
            return 0;
        }

        const docs = [];
        snapshot.forEach(doc => {
            docs.push({
                _id: doc.id,
                ...serializeValue(doc.data()),
            });
        });

        const outFile = path.join(OUTPUT_DIR, `${collectionName}.json`);
        fs.writeFileSync(outFile, JSON.stringify(docs, null, 2));
        console.log(`  [${collectionName}] — ${docs.length} docs → ${outFile}`);
        return docs.length;
    } catch (err) {
        console.error(`  [${collectionName}] ERROR: ${err.message}`);
        return 0;
    }
}

// --- Main ---
async function main() {
    console.log('=== Firestore → JSON Export ===\n');
    initFirebase();
    const db = admin.firestore();

    // Create output directory
    if (!fs.existsSync(OUTPUT_DIR)) {
        fs.mkdirSync(OUTPUT_DIR, { recursive: true });
    }

    let totalDocs = 0;
    let totalCollections = 0;

    for (const col of COLLECTIONS) {
        const count = await exportCollection(db, col);
        if (count > 0) {
            totalDocs += count;
            totalCollections++;
        }
    }

    console.log(`\n=== Export Complete ===`);
    console.log(`Collections exported: ${totalCollections}`);
    console.log(`Total documents: ${totalDocs}`);
    console.log(`Output directory: ${OUTPUT_DIR}`);

    process.exit(0);
}

main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});
