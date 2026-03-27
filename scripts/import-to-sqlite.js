#!/usr/bin/env node
/**
 * Import Firestore Export Data into SQLite
 *
 * Reads JSON files from data/firestore-export/ (produced by export-firestore.js)
 * and inserts them into the SQLite database via sqliteClient.js.
 *
 * Usage:
 *   node scripts/import-to-sqlite.js                     # Import all collections
 *   node scripts/import-to-sqlite.js users orders         # Import specific collections
 *   node scripts/import-to-sqlite.js --dry-run            # Preview without writing
 *   node scripts/import-to-sqlite.js --clear              # Clear tables before import
 *
 * After import, the database is persisted to data/cardamom.db for local dev
 * or can be loaded into the ICP canister via stable memory.
 */

const fs = require('fs');
const path = require('path');

const INPUT_DIR = path.join(__dirname, '..', 'data', 'firestore-export');
const DB_OUTPUT = path.join(__dirname, '..', 'data', 'cardamom.db');

// Tables that use parentId (subcollection flattening)
const SUBCOLLECTION_TABLES = new Set(['client_request_messages']);

// ---------------------------------------------------------------------------
// Import logic
// ---------------------------------------------------------------------------

async function importCollection(db, tableName, docs, opts = {}) {
    const { dryRun = false, clear = false } = opts;
    const isSubcollection = SUBCOLLECTION_TABLES.has(tableName);

    if (dryRun) {
        console.log(`  [DRY RUN] ${tableName}: would import ${docs.length} documents`);
        return docs.length;
    }

    if (clear) {
        db.run(`DELETE FROM "${tableName}"`);
        console.log(`  Cleared ${tableName}`);
    }

    let imported = 0;
    let skipped = 0;

    // Use a transaction for performance
    db.run('BEGIN TRANSACTION');

    try {
        for (const doc of docs) {
            const id = doc.id;
            const data = doc.data || {};
            const parentId = doc.parentId || null;
            const now = new Date().toISOString();

            // Extract timestamps from data if present
            const createdAt = data._createdAt || data.createdAt || data.created_at || now;
            const updatedAt = data._updatedAt || data.updatedAt || data.updated_at || now;

            try {
                if (isSubcollection && parentId) {
                    db.run(
                        `INSERT OR REPLACE INTO "${tableName}" (id, parentId, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?, ?)`,
                        [id, parentId, JSON.stringify(data), createdAt, updatedAt]
                    );
                } else {
                    db.run(
                        `INSERT OR REPLACE INTO "${tableName}" (id, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?)`,
                        [id, JSON.stringify(data), createdAt, updatedAt]
                    );
                }
                imported++;
            } catch (err) {
                // Table might not exist — create it dynamically
                if (err.message && err.message.includes('no such table')) {
                    console.warn(`  WARNING: Table "${tableName}" not in schema, creating dynamically`);
                    if (isSubcollection && parentId) {
                        db.run(`CREATE TABLE IF NOT EXISTS "${tableName}" (id TEXT PRIMARY KEY, parentId TEXT NOT NULL, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT, _updatedAt TEXT)`);
                    } else {
                        db.run(`CREATE TABLE IF NOT EXISTS "${tableName}" (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT, _updatedAt TEXT)`);
                    }
                    // Retry the insert
                    if (isSubcollection && parentId) {
                        db.run(
                            `INSERT OR REPLACE INTO "${tableName}" (id, parentId, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?, ?)`,
                            [id, parentId, JSON.stringify(data), createdAt, updatedAt]
                        );
                    } else {
                        db.run(
                            `INSERT OR REPLACE INTO "${tableName}" (id, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?)`,
                            [id, JSON.stringify(data), createdAt, updatedAt]
                        );
                    }
                    imported++;
                } else {
                    console.error(`  ERROR inserting ${tableName}/${id}: ${err.message}`);
                    skipped++;
                }
            }
        }

        db.run('COMMIT');
    } catch (err) {
        db.run('ROLLBACK');
        throw err;
    }

    console.log(`  ${tableName}: ${imported} imported, ${skipped} skipped`);
    return imported;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
    const args = process.argv.slice(2);
    const dryRun = args.includes('--dry-run');
    const clear = args.includes('--clear');
    const collections = args.filter(a => !a.startsWith('--'));

    // Check input directory
    if (!fs.existsSync(INPUT_DIR)) {
        console.error(`ERROR: Export directory not found: ${INPUT_DIR}`);
        console.error('Run scripts/export-firestore.js first.');
        process.exit(1);
    }

    // Find available JSON files
    const jsonFiles = fs.readdirSync(INPUT_DIR)
        .filter(f => f.endsWith('.json'))
        .map(f => f.replace('.json', ''));

    if (jsonFiles.length === 0) {
        console.error(`ERROR: No JSON files found in ${INPUT_DIR}`);
        process.exit(1);
    }

    const toImport = collections.length > 0
        ? collections.filter(c => jsonFiles.includes(c))
        : jsonFiles;

    if (collections.length > 0) {
        const missing = collections.filter(c => !jsonFiles.includes(c));
        if (missing.length > 0) {
            console.warn(`WARNING: No export files found for: ${missing.join(', ')}`);
        }
    }

    console.log(`\n=== SQLite Import ===`);
    console.log(`Source: ${INPUT_DIR}`);
    console.log(`Collections: ${toImport.length}`);
    if (dryRun) console.log('MODE: Dry run (no writes)');
    if (clear) console.log('MODE: Clear tables before import');
    console.log('');

    // Initialize SQLite
    let db;
    if (!dryRun) {
        const initSqlJs = require('sql.js/dist/sql-asm.js');
        const SQL = await initSqlJs();

        // Load existing DB or create new
        if (fs.existsSync(DB_OUTPUT)) {
            const buffer = fs.readFileSync(DB_OUTPUT);
            db = new SQL.Database(new Uint8Array(buffer));
            console.log(`Loaded existing database: ${DB_OUTPUT}`);
        } else {
            db = new SQL.Database();
            console.log('Created new database');
        }

        // Apply schema
        const schemaPath = path.join(__dirname, '..', 'src', 'backend', 'database', 'schema.sql');
        if (fs.existsSync(schemaPath)) {
            const schema = fs.readFileSync(schemaPath, 'utf8');
            const statements = schema.split(';').map(s => s.trim()).filter(s => s.length > 0);
            for (const stmt of statements) {
                db.run(stmt + ';');
            }
            console.log(`Schema applied (${statements.length} statements)`);
        }
    }

    // Import each collection
    const summary = {};
    let totalImported = 0;

    for (const name of toImport) {
        const filePath = path.join(INPUT_DIR, `${name}.json`);
        try {
            const raw = fs.readFileSync(filePath, 'utf8');
            const docs = JSON.parse(raw);

            if (!Array.isArray(docs)) {
                console.warn(`  WARNING: ${name}.json is not an array, skipping`);
                summary[name] = 'SKIPPED (not array)';
                continue;
            }

            const count = await importCollection(db, name, docs, { dryRun, clear });
            summary[name] = count;
            totalImported += count;
        } catch (err) {
            console.error(`  ERROR importing ${name}: ${err.message}`);
            summary[name] = `ERROR: ${err.message}`;
        }
    }

    // Save the database
    if (!dryRun && db) {
        const outDir = path.dirname(DB_OUTPUT);
        if (!fs.existsSync(outDir)) {
            fs.mkdirSync(outDir, { recursive: true });
        }

        const data = db.export();
        fs.writeFileSync(DB_OUTPUT, Buffer.from(data));
        console.log(`\nDatabase saved to: ${DB_OUTPUT} (${(data.length / 1024).toFixed(1)} KB)`);
        db.close();
    }

    // Print summary
    console.log(`\n=== Import Summary ===`);
    for (const [name, count] of Object.entries(summary)) {
        console.log(`  ${name}: ${typeof count === 'number' ? count + ' docs' : count}`);
    }
    console.log(`\nTotal: ${totalImported} documents imported`);

    if (!dryRun) {
        console.log(`\nNext steps:`);
        console.log(`  1. Verify: node -e "const SQL=require('sql.js/dist/sql-asm.js');SQL().then(s=>{const d=new s.Database(require('fs').readFileSync('${DB_OUTPUT}'));console.log(d.exec('SELECT name,COUNT(*) FROM sqlite_master WHERE type=\\'table\\' GROUP BY type'));d.close()})"`);
        console.log(`  2. The canister will auto-load from stable memory on deploy.`);
        console.log(`     For local testing, the init.js seeds a fresh DB if stable memory is empty.`);
    }
}

main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});
