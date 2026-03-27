#!/usr/bin/env node
/**
 * Import exported Firestore JSON data into ICP SQLite database.
 * 
 * Usage: node scripts/import-to-sqlite.js
 * 
 * Reads data/*.json files created by export-firestore.js
 * and inserts them into the SQLite database via sqliteClient.
 */

const fs = require('fs');
const path = require('path');

// Import the sqliteClient from the ICP project
const sqliteClient = require(path.join(__dirname, '..', 'src', 'backend', 'database', 'sqliteClient'));

const DATA_DIR = path.join(__dirname, '..', 'data');

// Map of Firestore collection names to SQLite table names
const COLLECTION_TABLE_MAP = {
    'users': 'users',
    'orders': 'orders',
    'client_requests': 'client_requests',
    'approval_requests': 'approval_requests',
    'stock': 'stock',
    'tasks': 'tasks',
    'attendance': 'attendance',
    'expenses': 'expenses',
    'gate_passes': 'gate_passes',
    'dispatch_documents': 'dispatch_documents',
    'transport_documents': 'transport_documents',
    'transport_assignments': 'transport_assignments',
    'dropdowns': 'dropdowns',
    'settings': 'settings',
    'counters': 'counters',
    'packed_boxes': 'packed_boxes',
    'offer_prices': 'offer_prices',
    'outstanding': 'outstanding',
    'whatsapp_logs': 'whatsapp_logs',
    'notifications': 'notifications',
    'analytics': 'analytics',
    'dashboard_cache': 'dashboard_cache',
    'client_contacts': 'client_contacts',
    'sync_log': 'sync_log',
    'predictive_analytics': 'predictive_analytics',
    'ai_briefings': 'ai_briefings',
};

// --- Deserialize Firestore special types back to plain values ---
function deserializeValue(val) {
    if (val === null || val === undefined) return null;
    if (typeof val === 'object' && val._type === 'timestamp') {
        return val.value; // Keep as ISO string
    }
    if (typeof val === 'object' && val._type === 'geopoint') {
        return JSON.stringify({ lat: val.lat, lng: val.lng });
    }
    if (typeof val === 'object' && val._type === 'ref') {
        return val.path;
    }
    if (typeof val === 'object' && val._type === 'bytes') {
        return val.value; // Keep as base64 string
    }
    if (Array.isArray(val)) {
        return val.map(deserializeValue);
    }
    if (typeof val === 'object' && val !== null) {
        const result = {};
        for (const [k, v] of Object.entries(val)) {
            result[k] = deserializeValue(v);
        }
        return result;
    }
    return val;
}

// --- Import a single collection ---
async function importCollection(collectionName) {
    const jsonFile = path.join(DATA_DIR, `${collectionName}.json`);
    
    if (!fs.existsSync(jsonFile)) {
        console.log(`  [${collectionName}] — no JSON file, skipping`);
        return 0;
    }

    const rawData = JSON.parse(fs.readFileSync(jsonFile, 'utf8'));
    if (!rawData.length) {
        console.log(`  [${collectionName}] — empty file, skipping`);
        return 0;
    }

    let imported = 0;
    let errors = 0;

    for (const doc of rawData) {
        try {
            const docId = doc._id;
            const data = { ...doc };
            delete data._id;

            // Deserialize Firestore types
            const cleanData = deserializeValue(data);

            // Use setDoc to insert (will create or overwrite)
            await sqliteClient.setDoc(collectionName, docId, cleanData, false);
            imported++;
        } catch (err) {
            errors++;
            if (errors <= 3) {
                console.error(`    Error importing doc ${doc._id}: ${err.message}`);
            }
        }
    }

    if (errors > 3) {
        console.error(`    ... and ${errors - 3} more errors`);
    }

    console.log(`  [${collectionName}] — ${imported}/${rawData.length} docs imported${errors ? ` (${errors} errors)` : ''}`);
    return imported;
}

// --- Main ---
async function main() {
    console.log('=== JSON → SQLite Import ===\n');

    if (!fs.existsSync(DATA_DIR)) {
        console.error(`ERROR: Data directory not found: ${DATA_DIR}`);
        console.error('Run scripts/export-firestore.js first.');
        process.exit(1);
    }

    const jsonFiles = fs.readdirSync(DATA_DIR).filter(f => f.endsWith('.json'));
    console.log(`Found ${jsonFiles.length} JSON files in ${DATA_DIR}\n`);

    let totalImported = 0;
    let totalCollections = 0;

    for (const [collection, table] of Object.entries(COLLECTION_TABLE_MAP)) {
        const count = await importCollection(collection);
        if (count > 0) {
            totalImported += count;
            totalCollections++;
        }
    }

    console.log(`\n=== Import Complete ===`);
    console.log(`Collections imported: ${totalCollections}`);
    console.log(`Total documents: ${totalImported}`);
}

main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});
