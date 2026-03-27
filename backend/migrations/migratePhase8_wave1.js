/**
 * Migration Script: Phase 8 Wave 1
 * Dropdown Data + Absolute Grades Config → Firestore
 *
 * Run ONCE: node backend/migrations/migratePhase8_wave1.js
 */
require('dotenv').config({ path: require('path').join(__dirname, '../../.env') });
const sheets = require('../sheetsClient');
const { getDb, initializeFirebase } = require('../firebaseClient');
const CFG = require('../config');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Parse a ratio cell value.
 * - If it is a string containing '%', strip the '%' and divide by 100.
 * - If the numeric value is > 1, assume it was stored as a percentage and divide by 100.
 * - Otherwise return the float as-is.
 */
function parseRatioCell(val) {
    if (val === undefined || val === null || val === '') return 0;
    if (typeof val === 'string') {
        val = val.trim();
        if (val.endsWith('%')) {
            return parseFloat(val.replace('%', '')) / 100;
        }
        val = parseFloat(val);
    }
    if (isNaN(val)) return 0;
    if (val > 1) return val / 100;
    return val;
}

// ---------------------------------------------------------------------------
// 1. Migrate Dropdown Data
// ---------------------------------------------------------------------------

async function migrateDropdownData() {
    console.log('\n=== DROPDOWN DATA ===');
    const rows = await sheets.readRange('DropdownData!A:D', { cache: false }).catch(() => []);
    if (!rows || rows.length === 0) {
        console.log('  No dropdown data found. Skipping.');
        return;
    }

    // Columns: Client (A), Grade (B), Bag/Box (C), Brand (D)
    const sets = { clients: new Set(), grades: new Set(), bagbox: new Set(), brands: new Set() };

    for (const row of rows) {
        const client = (row[0] || '').toString().trim();
        const grade  = (row[1] || '').toString().trim();
        const bagbox = (row[2] || '').toString().trim();
        const brand  = (row[3] || '').toString().trim();

        if (client) sets.clients.add(client);
        if (grade)  sets.grades.add(grade);
        if (bagbox) sets.bagbox.add(bagbox);
        if (brand)  sets.brands.add(brand);
    }

    const db = getDb();
    const batch = db.batch();
    const now = new Date().toISOString();

    for (const [docId, itemSet] of Object.entries(sets)) {
        const ref = db.collection('dropdown_data').doc(docId);
        batch.set(ref, {
            items: Array.from(itemSet),
            lastUpdated: now,
            migratedFrom: 'DropdownData sheet',
        });
        console.log(`  ${docId}: ${itemSet.size} unique values`);
    }

    await batch.commit();
    console.log('  Dropdown data migrated to Firestore (dropdown_data collection).');
}

// ---------------------------------------------------------------------------
// 2. Migrate Absolute Grades → settings/stock_config
// ---------------------------------------------------------------------------

async function migrateAbsoluteGrades() {
    console.log('\n=== ABSOLUTE GRADES CONFIG ===');

    // Read absolute_grades!B2:G10 — 9 rows, 6 columns
    // 3 blocks of 3 types x 6 grades
    // Block 0 (rows 0-2): bold
    // Block 1 (rows 3-5): float
    // Block 2 (rows 6-8): medium
    const rows = await sheets.readRange('absolute_grades!B2:G10', { cache: false }).catch(() => []);
    if (!rows || rows.length < 9) {
        console.log(`  Expected 9 rows, got ${rows ? rows.length : 0}. Skipping.`);
        return;
    }

    const blockNames = ['bold', 'float', 'medium'];
    const types = ['Colour Bold', 'Fruit Bold', 'Rejection'];
    const grades = ['8 mm', '7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below'];

    const ratios = {};
    for (let b = 0; b < 3; b++) {
        const blockName = blockNames[b];
        ratios[blockName] = {};
        for (let t = 0; t < 3; t++) {
            const rowIdx = b * 3 + t;
            const typeName = types[t];
            ratios[blockName][typeName] = {};
            for (let g = 0; g < 6; g++) {
                ratios[blockName][typeName][grades[g]] = parseRatioCell(rows[rowIdx][g]);
            }
        }
        console.log(`  Parsed block "${blockName}": ${JSON.stringify(ratios[blockName][types[0]])}`);
    }

    // Virtual grade formulas (static definitions)
    const virtualFormulas = {
        '8.5 mm':        { type: 'percentage',  sources: ['8 mm'],                                            factor: 0.05 },
        '7.8 bold':      { type: 'min_multi',   sources: ['8 mm', '7.5 to 8 mm'],                             multiplier: 2 },
        '7 to 8 mm':     { type: 'min_multi',   sources: ['7.5 to 8 mm', '7 to 7.5 mm'],                      multiplier: 2 },
        '6.5 to 8 mm':   { type: 'min_multi',   sources: ['7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm'],      multiplier: 3 },
        '6.5 to 7.5 mm': { type: 'min_multi',   sources: ['7 to 7.5 mm', '6.5 to 7 mm'],                      multiplier: 2 },
        '6 to 7 mm':     { type: 'min_multi',   sources: ['6.5 to 7 mm', '6 to 6.5 mm'],                      multiplier: 2 },
        'Mini Bold':     { type: 'min_multi',   sources: ['6 to 6.5 mm', '6 mm below'],                       multiplier: 2 },
        'Pan':           { type: 'percentage',  sources: ['6 mm below'],                                       factor: 0.50 },
    };

    // Impact of virtual grades on absolute grades (weight distribution)
    const virtualImpactOnAbsolute = {
        '8.5 mm':        { '8 mm': 1.0 },
        '7.8 bold':      { '8 mm': 0.5,          '7.5 to 8 mm': 0.5 },
        '7 to 8 mm':     { '7.5 to 8 mm': 0.5,   '7 to 7.5 mm': 0.5 },
        '6.5 to 8 mm':   { '7.5 to 8 mm': 0.333, '7 to 7.5 mm': 0.333, '6.5 to 7 mm': 0.333 },
        '6.5 to 7.5 mm': { '7 to 7.5 mm': 0.5,   '6.5 to 7 mm': 0.5 },
        '6 to 7 mm':     { '6.5 to 7 mm': 0.5,   '6 to 6.5 mm': 0.5 },
        'Mini Bold':     { '6 to 6.5 mm': 0.5,   '6 mm below': 0.5 },
        'Pan':           { '6 mm below': 1.0 },
    };

    const stockConfig = {
        ratios,
        virtualFormulas,
        virtualImpactOnAbsolute,
        types,
        absGrades: grades,
        virtualGrades: [
            '8.5 mm', '7.8 bold', '7 to 8 mm', '6.5 to 8 mm',
            '6.5 to 7.5 mm', '6 to 7 mm', 'Mini Bold', 'Pan',
        ],
        saleOrderHeaders: [
            '8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm',
            '6.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm',
            '6 to 7 mm', '6 to 6.5 mm', '6 mm below', 'Mini Bold', 'Pan',
        ],
        lastUpdated: new Date().toISOString(),
    };

    const db = getDb();
    await db.collection('settings').doc('stock_config').set(stockConfig);
    console.log('  Stock config written to settings/stock_config.');
}

// ---------------------------------------------------------------------------
// 3. Run All
// ---------------------------------------------------------------------------

async function migrateAll() {
    console.log('╔══════════════════════════════════════════════════╗');
    console.log('║  PHASE 8 WAVE 1: Dropdown + Stock Config        ║');
    console.log('╚══════════════════════════════════════════════════╝');
    initializeFirebase();

    await migrateDropdownData();
    await migrateAbsoluteGrades();

    console.log('\n========================================');
    console.log('  PHASE 8 WAVE 1 MIGRATION COMPLETE');
    console.log('  Next: Set FB_DROPDOWN=true to activate Firestore dropdowns');
    console.log('========================================');
}

// ---------------------------------------------------------------------------
// CLI runner
// ---------------------------------------------------------------------------

if (require.main === module) {
    migrateAll()
        .then(() => process.exit(0))
        .catch(err => {
            console.error('MIGRATION FAILED:', err);
            process.exit(1);
        });
}

module.exports = { migrateDropdownData, migrateAbsoluteGrades, migrateAll };
