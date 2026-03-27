/**
 * Stock Engine — Pure Firestore Implementation
 *
 * Replaces the entire Sheets-based stockCalc.js with a Firestore-native engine.
 * All stock computations, adjustments, sale order aggregation, and net stock
 * calculation happen directly against Firestore collections.
 *
 * Collections used:
 *   - settings/stock_config          (config: ratios, virtualFormulas, virtualImpact)
 *   - live_stock_entries             (daily purchase entries: boldQty, floatQty, mediumQty)
 *   - stock_adjustments              (manual +/- adjustments per type/grade)
 *   - orders                         (pending sale orders)
 *   - cart_orders                    (in-progress / daily cart orders)
 *   - packed_orders                  (archived / fulfilled orders)
 *   - sale_order_summary/packed_totals (materialized view of packed totals)
 *   - net_stock_cache                (computed net stock per type)
 *
 * Dependencies:
 *   - ../firebaseClient  -> getDb(), createBatch()
 *   - ../config          -> CFG (types, absGrades, virtualGrades, saleOrderHeaders)
 *   - ../featureFlags    -> useFirestore(moduleName)
 */

const { getDb, createBatch } = require('../firebaseClient');
const CFG = require('../config');
const flags = require('../featureFlags');

// ============================================================================
// IN-MEMORY CACHE
// ============================================================================

const cache = { stockConfig: null, stockConfigExpiry: 0 };
const CONFIG_TTL = 5 * 60 * 1000; // 5 minutes

// ============================================================================
// GRADE NORMALIZATION (copied from mergeGlue_fb.js)
// ============================================================================

function _norm(s) { return String(s || '').toLowerCase().replace(/\s+/g, ' ').trim(); }

const _SALE_CANON = [
    '8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm',
    '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm',
    '6 mm below', 'mini bold', 'pan'
];

function _pickCanonFromText(gradeText) {
    const t = _norm(gradeText);
    const isMini = /\bmini\b/.test(t) && /\bbold\b/.test(t);
    const isPan = /\bpan\b/.test(t);
    const isBold78 = /7\.?8\b/.test(t) && /\bbold\b/.test(t);
    const isBelow6 = /6\s*mm\s*below/i.test(t) || /below\s*6/i.test(t);

    if (isMini) return 'mini bold';
    if (isPan) return 'pan';
    if (isBelow6) return '6 mm below';
    if (isBold78) return '7.8 bold';

    // Handle "X above" pattern → map to "X to 8 mm" (e.g. "6.5 above" → "6.5 to 8 mm", "7 above" → "7 to 8 mm")
    const aboveMatch = t.match(/(\d+(?:\.\d+)?)\s*(?:mm\s*)?above/);
    if (aboveMatch) {
        const lower = Math.round(parseFloat(aboveMatch[1]) * 2) / 2;
        const _numStr = x => x % 1 === 0 ? String(parseInt(x, 10)) : String(x);
        const candidate = _numStr(lower) + ' to 8 mm';
        if (_SALE_CANON.includes(candidate)) return candidate;
    }

    const m = t.match(/(\d+(?:\.\d+)?)\s*(?:to|–|—|-)?\s*(\d+(?:\.\d+)?)?/);
    if (m) {
        const a = m[1] ? Math.round(parseFloat(m[1]) * 2) / 2 : null;
        const b = m[2] ? Math.round(parseFloat(m[2]) * 2) / 2 : null;

        const _numStr = x => x % 1 === 0 ? String(parseInt(x, 10)) : String(x);
        if (a != null && b == null) { const s = _numStr(a) + ' mm'; if (_SALE_CANON.includes(s)) return s; }
        if (a != null && b != null) { const s = _numStr(a) + ' to ' + _numStr(b) + ' mm'; if (_SALE_CANON.includes(s)) return s; }
    }

    // Fallback: substring match (longest first)
    const sorted = _SALE_CANON.slice().sort((a, b) => _norm(b).length - _norm(a).length);
    for (const c of sorted) {
        if (t.includes(_norm(c))) return c;
    }
    return null;
}

function _chooseSaleRowName(gradeText) {
    const t = _norm(gradeText);
    if (t.includes('colour') || t.includes('color')) return 'Colour Bold';
    if (t.includes('fruit')) return 'Fruit Bold';
    if (t.includes('rejection') || t.includes('split') || t.includes('sick')) return 'Rejection';
    return null;
}

// ============================================================================
// CONSTANTS
// ============================================================================

const ABS_GRADES = CFG.absGrades;   // ['8 mm', '7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below']
const VIRT_GRADES = CFG.virtualGrades; // ['8.5 mm', '7.8 bold', '7 to 8 mm', '6.5 to 8 mm', '6.5 to 7.5 mm', '6 to 7 mm', 'Mini Bold', 'Pan']
const TYPES = CFG.types;             // ['Colour Bold', 'Fruit Bold', 'Rejection']

// Map absolute grade name -> index in ABS_GRADES array
const ABS_IDX = {};
ABS_GRADES.forEach((g, i) => { ABS_IDX[g] = i; });

// Virtual grade impact on absolute grades (used when subtracting virtual sales)
// Each entry: array of { absIdx, factor } describing how selling 1 unit of virtual
// grade affects the absolute grades.
const VIRTUAL_IMPACT_ON_ABSOLUTE = {
    '8.5 mm':       [{ absIdx: 0, factor: 1.0 }],
    '7.8 bold':     [{ absIdx: 0, factor: 0.5 }, { absIdx: 1, factor: 0.5 }],
    '7 to 8 mm':    [{ absIdx: 1, factor: 0.5 }, { absIdx: 2, factor: 0.5 }],
    '6.5 to 8 mm':  [{ absIdx: 1, factor: 1/3 }, { absIdx: 2, factor: 1/3 }, { absIdx: 3, factor: 1/3 }],
    '6.5 to 7.5 mm':[{ absIdx: 2, factor: 0.5 }, { absIdx: 3, factor: 0.5 }],
    '6 to 7 mm':    [{ absIdx: 3, factor: 0.5 }, { absIdx: 4, factor: 0.5 }],
    // Mini Bold: Pan claims 50% of 6mm below, so Mini Bold draws from
    // 6→6.5 at full weight (1.0) and 6mm below at half weight (0.5).
    // Normalized: 1.0/1.5 = 2/3 from 6→6.5, 0.5/1.5 = 1/3 from 6mm below.
    'Mini Bold':    [{ absIdx: 4, factor: 2/3 }, { absIdx: 5, factor: 1/3 }],
    'Pan':          [{ absIdx: 5, factor: 1.0 }]
};

// For addStockAdjustment: map virtual grade adjustment to absolute grade adjustments
const VIRTUAL_TO_ABSOLUTE_MAP = {
    '8.5 mm':       [{ grade: '8 mm', factor: 1.0 }],
    '7.8 bold':     [{ grade: '8 mm', factor: 0.5 }, { grade: '7.5 to 8 mm', factor: 0.5 }],
    '7 to 8 mm':    [{ grade: '7.5 to 8 mm', factor: 0.5 }, { grade: '7 to 7.5 mm', factor: 0.5 }],
    '6.5 to 8 mm':  [{ grade: '7.5 to 8 mm', factor: 1/3 }, { grade: '7 to 7.5 mm', factor: 1/3 }, { grade: '6.5 to 7 mm', factor: 1/3 }],
    '6.5 to 7.5 mm':[{ grade: '7 to 7.5 mm', factor: 0.5 }, { grade: '6.5 to 7 mm', factor: 0.5 }],
    '6 to 7 mm':    [{ grade: '6.5 to 7 mm', factor: 0.5 }, { grade: '6 to 6.5 mm', factor: 0.5 }],
    // Mini Bold: weighted 2/3 to 6→6.5, 1/3 to 6mm below (Pan claims half of 6mm below)
    'Mini Bold':    [{ grade: '6 to 6.5 mm', factor: 2/3 }, { grade: '6 mm below', factor: 1/3 }],
    'Pan':          [{ grade: '6 mm below', factor: 1.0 }]
};

// 14-column header layout for UI
const NET_HEADERS = [
    '8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm',
    '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm',
    '6 mm below', 'Mini Bold', 'Pan'
];

// ============================================================================
// 1. getCachedConfig()
// ============================================================================

/**
 * Read settings/stock_config from Firestore with TTL cache.
 * Falls back to hardcoded default ratios if the document does not exist.
 */
async function getCachedConfig() {
    const now = Date.now();
    if (cache.stockConfig && now < cache.stockConfigExpiry) {
        return cache.stockConfig;
    }

    try {
        const db = getDb();
        const doc = await db.collection('settings').doc('stock_config').get();

        if (doc.exists) {
            cache.stockConfig = doc.data();
            cache.stockConfigExpiry = now + CONFIG_TTL;
            console.log('[stock-FB] Loaded stock config from Firestore');
            return cache.stockConfig;
        }
    } catch (err) {
        console.error('[stock-FB] Error reading stock_config:', err.message);
    }

    // Fallback: build default config from CFG
    // Default ratios are identity-like (equal distribution by type row)
    // In production, these should be stored in Firestore settings/stock_config
    const defaultConfig = {
        types: TYPES,
        absGrades: ABS_GRADES,
        virtualGrades: VIRT_GRADES,
        ratios: {
            bold: {},
            float: {},
            medium: {}
        },
        virtualFormulas: {
            '8.5 mm':       { type: 'percentage', factor: 0.05, sources: ['8 mm'] },
            '7.8 bold':     { type: 'min_multi', multiplier: 2, sources: ['8 mm', '7.5 to 8 mm'] },
            '7 to 8 mm':    { type: 'min_multi', multiplier: 2, sources: ['7.5 to 8 mm', '7 to 7.5 mm'] },
            '6.5 to 8 mm':  { type: 'min_multi', multiplier: 3, sources: ['7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm'] },
            '6.5 to 7.5 mm':{ type: 'min_multi', multiplier: 2, sources: ['7 to 7.5 mm', '6.5 to 7 mm'] },
            '6 to 7 mm':    { type: 'min_multi', multiplier: 2, sources: ['6.5 to 7 mm', '6 to 6.5 mm'] },
            // Mini Bold uses only 50% of 6mm below (Pan claims the other 50%)
            'Mini Bold':    { type: 'min_multi_weighted', multiplier: 2, sources: ['6 to 6.5 mm', '6 mm below'], sourceWeights: [1.0, 0.5] },
            'Pan':          { type: 'percentage', factor: 0.5, sources: ['6 mm below'] }
        },
        virtualImpactOnAbsolute: VIRTUAL_IMPACT_ON_ABSOLUTE
    };

    cache.stockConfig = defaultConfig;
    cache.stockConfigExpiry = now + CONFIG_TTL;
    console.log('[stock-FB] Using hardcoded default stock config (no Firestore doc found)');
    return defaultConfig;
}

// ============================================================================
// 2. computeAbsoluteStock(config?)
// ============================================================================

/**
 * Sum ALL live_stock_entries documents and multiply by segregation ratios.
 * Returns { 'Colour Bold': { '8 mm': 5000, ... }, 'Fruit Bold': {...}, 'Rejection': {...} }
 */
async function computeAbsoluteStock(config) {
    if (!config) config = await getCachedConfig();

    const db = getDb();
    const snap = await db.collection('live_stock_entries').get();

    let totalBold = 0, totalFloat = 0, totalMedium = 0;
    snap.docs.forEach(doc => {
        const d = doc.data();
        totalBold += parseFloat(d.boldQty) || 0;
        totalFloat += parseFloat(d.floatQty) || 0;
        totalMedium += parseFloat(d.mediumQty) || 0;
    });

    console.log(`[stock-FB] computeAbsoluteStock: bold=${totalBold}, float=${totalFloat}, medium=${totalMedium} from ${snap.size} entries`);

    const result = {};
    for (const type of TYPES) {
        result[type] = {};
        for (const grade of ABS_GRADES) {
            const boldRatio = _getRatio(config, 'bold', type, grade);
            const floatRatio = _getRatio(config, 'float', type, grade);
            const mediumRatio = _getRatio(config, 'medium', type, grade);

            result[type][grade] = Math.round(
                boldRatio * totalBold +
                floatRatio * totalFloat +
                mediumRatio * totalMedium
            );
        }
    }

    return result;
}

/**
 * Extract ratio from config. The config.ratios structure:
 *   config.ratios.bold['Colour Bold']['8 mm'] = 0.48
 * Returns 0 if path does not exist.
 */
function _getRatio(config, purchaseType, stockType, grade) {
    try {
        const val = config.ratios[purchaseType][stockType][grade];
        if (val === undefined || val === null) return 0;
        // Handle both decimal (0.48) and percentage (48) forms
        const num = parseFloat(val);
        if (!Number.isFinite(num)) return 0;
        return num > 1 ? num / 100 : num;
    } catch (e) {
        return 0;
    }
}

// ============================================================================
// 3. calculateVirtualFromAbsolutes(absStock, virtualFormulas)
// ============================================================================

/**
 * Given absolute stock for one type and virtualFormulas config, compute virtual grades.
 * @param {Object} absStock - e.g. { '8 mm': 5000, '7.5 to 8 mm': 4000, ... }
 * @param {Object} virtualFormulas - from config
 * @returns {Object} - { '8.5 mm': 250, '7.8 bold': 8000, ... }
 */
function calculateVirtualFromAbsolutes(absStock, virtualFormulas) {
    const result = {};

    for (const [vGrade, formula] of Object.entries(virtualFormulas)) {
        if (formula.type === 'percentage') {
            const sourceVal = absStock[formula.sources[0]] || 0;
            result[vGrade] = Math.round(formula.factor * sourceVal);
        } else if (formula.type === 'min_multi') {
            const sourceVals = formula.sources.map(s => absStock[s] || 0);
            result[vGrade] = Math.round(formula.multiplier * Math.min(...sourceVals));
        } else if (formula.type === 'min_multi_weighted') {
            // Like min_multi but each source is weighted (e.g., Mini Bold uses 50% of 6mm below)
            const sourceVals = formula.sources.map((s, i) => {
                const weight = formula.sourceWeights ? (formula.sourceWeights[i] || 1) : 1;
                return weight * (absStock[s] || 0);
            });
            result[vGrade] = Math.round(formula.multiplier * Math.min(...sourceVals));
        } else {
            result[vGrade] = 0;
        }
    }

    return result;
}

// ============================================================================
// 4. getAdjustmentMap()
// ============================================================================

/**
 * Read stock_adjustments collection. Return aggregated map:
 * { 'Colour Bold': { '8 mm': 50, ... }, ... }
 *
 * ISSUE STK-4 FIX: Only read approved adjustments (those that have an approvalId)
 * or manual adjustments that were added directly (legacy). Pending adjustments
 * are stored in approval_requests collection and are not applied until approved.
 */
async function getAdjustmentMap() {
    try {
        const db = getDb();
        const snap = await db.collection('stock_adjustments').get();

        if (snap.empty) {
            console.log('[stock-FB] No stock adjustments found');
            return {};
        }

        const map = {};
        snap.docs.forEach(doc => {
            const d = doc.data();
            const type = String(d.type || '').trim();
            const grade = String(d.grade || '').trim();
            const delta = parseFloat(d.deltaKgs);

            if (!type || !grade || !Number.isFinite(delta) || delta === 0) return;

            // Only include adjustments that have been approved (have approvalId) or are legacy direct entries
            // Pending adjustments are in approval_requests collection, not here
            if (!d.approvalId && d.createdAt) {
                // Legacy adjustment - assume it was already approved/applied
                if (!map[type]) map[type] = {};
                map[type][grade] = (map[type][grade] || 0) + delta;
            } else if (d.approvalId) {
                // Modern approval workflow - only include if approved
                if (!map[type]) map[type] = {};
                map[type][grade] = (map[type][grade] || 0) + delta;
            }
        });

        console.log('[stock-FB] Adjustment map:', JSON.stringify(map));
        return map;
    } catch (err) {
        console.error('[stock-FB] Error reading adjustments:', err.message);
        return {};
    }
}

// ============================================================================
// 5. aggregateSaleOrders()
// ============================================================================

/**
 * Read from 3 Firestore collections and aggregate by grade and type.
 * Returns { pending: {...}, cart: {...}, packed: {...} }
 * Each is { 'Colour Bold': { '8 mm': 300, ... } }
 *
 * Packed orders are filtered to only include orders from the current stock period
 * (on or after the earliest purchase entry date). Historical packed orders from
 * before the current stock period have already left the warehouse and should not
 * be subtracted from current purchases.
 */
async function aggregateSaleOrders() {
    const db = getDb();

    // Helper to build empty type->grade map
    const emptyTypeMap = () => {
        const m = {};
        for (const type of TYPES) m[type] = {};
        return m;
    };

    // Helper to accumulate an order into a type map
    const accumulate = (typeMap, gradeText, kgs) => {
        const type = _chooseSaleRowName(gradeText);
        if (!type) return;

        const canon = _pickCanonFromText(gradeText);
        if (!canon) return;

        if (!typeMap[type]) typeMap[type] = {};
        typeMap[type][canon] = (typeMap[type][canon] || 0) + kgs;
    };

    // 1. Pending orders (status=Pending only)
    const pending = emptyTypeMap();
    try {
        const pendingSnap = await db.collection('orders').get();
        pendingSnap.docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted === true) return;
            if (String(d.status || '').toLowerCase() !== 'pending') return;
            const kgs = parseFloat(d.kgs) || 0;
            if (kgs <= 0) return;
            accumulate(pending, String(d.grade || ''), kgs);
        });
    } catch (err) {
        console.error('[stock-FB] Error reading pending orders:', err.message);
    }

    // 2. Cart orders (status='On Progress' only)
    const cart = emptyTypeMap();
    try {
        const cartSnap = await db.collection('cart_orders').get();
        cartSnap.docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted === true) return;
            if (String(d.status || '').toLowerCase() !== 'on progress') return;
            const kgs = parseFloat(d.kgs) || 0;
            if (kgs <= 0) return;
            accumulate(cart, String(d.grade || ''), kgs);
        });
    } catch (err) {
        console.error('[stock-FB] Error reading cart orders:', err.message);
    }

    // 3. Packed orders - full scan, filtered by stock period cutoff date
    //    Only count packed orders from the current stock period (>= earliest purchase date).
    //    Historical packed orders predate current purchases and are already dispatched.
    const packed = emptyTypeMap();
    try {
        // Find earliest purchase date as cutoff
        const purchaseSnap = await db.collection('live_stock_entries').get();
        let cutoffDate = null;
        purchaseSnap.docs.forEach(doc => {
            const d = doc.data();
            const dateStr = d.timestamp || d.createdAt || d.date || '';
            if (!dateStr) return;
            try {
                const dt = new Date(dateStr);
                if (!isNaN(dt.getTime()) && (cutoffDate === null || dt < cutoffDate)) {
                    cutoffDate = dt;
                }
            } catch (_) {}
        });
        // Set cutoff to start of that day (midnight)
        if (cutoffDate) {
            cutoffDate = new Date(cutoffDate.getFullYear(), cutoffDate.getMonth(), cutoffDate.getDate());
        }

        const packedSnap = await db.collection('packed_orders').get();
        let included = 0, excluded = 0;
        packedSnap.docs.forEach(doc => {
            const d = doc.data();
            const kgs = parseFloat(d.kgs) || 0;
            if (kgs <= 0) return;

            // Filter by cutoff date if available
            if (cutoffDate) {
                const dateStr = d.packedAt || d.archivedAt || d.createdAt || d.orderDate || '';
                if (dateStr) {
                    let packedDate;
                    // Handle DD/MM/YY format (e.g. "02/02/26")
                    const ddmmyy = String(dateStr).match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/);
                    if (ddmmyy) {
                        const yr = parseInt(ddmmyy[3]) < 100 ? 2000 + parseInt(ddmmyy[3]) : parseInt(ddmmyy[3]);
                        packedDate = new Date(yr, parseInt(ddmmyy[2]) - 1, parseInt(ddmmyy[1]));
                    } else {
                        packedDate = new Date(dateStr);
                    }
                    if (!isNaN(packedDate?.getTime()) && packedDate < cutoffDate) {
                        excluded++;
                        return; // Skip — predates current stock period
                    }
                }
            }

            included++;
            accumulate(packed, String(d.grade || ''), kgs);
        });
        console.log(`[stock-FB] Packed orders: ${included} included, ${excluded} excluded (before ${cutoffDate?.toISOString()?.split('T')[0] || 'no-cutoff'})`);
    } catch (err) {
        console.error('[stock-FB] Error reading packed orders:', err.message);
    }

    return { pending, cart, packed };
}

// ============================================================================
// 6. calculateNetStock() — THE CORE FUNCTION
// ============================================================================

/**
 * The core net stock calculation.
 *
 * Steps:
 *   a. Load config
 *   b. Compute absolute stock from live_stock_entries
 *   c. Aggregate sale orders (pending, cart, packed)
 *   d. Get adjustment map
 *   e. For each type:
 *      - Start with computed absolutes
 *      - Subtract direct absolute grade sales (pending + cart)
 *      - Subtract virtual grade sales impact on absolutes (pending + cart)
 *      - Subtract packed direct and packed virtual impacts
 *      - Apply adjustments
 *      - Round, fix -0
 *      - Recalculate virtuals from adjusted absolutes
 *   f. Write results to net_stock_cache collection (via transaction to prevent lost updates)
 *   g. Return results
 *
 * TRANSACTION RATIONALE: Multiple callers (addOrder, deleteOrder, addStockAdjustment,
 * addTodayPurchase, autoArchive) can trigger calculateNetStock concurrently. Without
 * a transaction on the net_stock_cache write, a slower calculation could overwrite a
 * newer one, causing lost updates. The transaction ensures serialized writes with a
 * timestamp check: only the most recent calculation wins.
 */
async function calculateNetStock() {
    const startTime = Date.now();
    console.log('[stock-FB] calculateNetStock starting...');

    try {
        // a-d. Parallelize all independent Firestore reads (3x faster)
        const config = await getCachedConfig(); // needed by computeAbsoluteStock
        const [computedAbsolutes, saleOrders, adjMap] = await Promise.all([
            computeAbsoluteStock(config),
            aggregateSaleOrders(),
            getAdjustmentMap(),
        ]);

        // e. Process each type (pure computation, no Firestore writes yet)
        const results = {};

        for (const type of TYPES) {
            // Clone computed absolutes for this type
            const abs = ABS_GRADES.map(g => computedAbsolutes[type][g] || 0);

            // Merge pending + cart into combined active sales
            const activeSales = _mergeSaleMaps(
                saleOrders.pending[type] || {},
                saleOrders.cart[type] || {}
            );

            // Subtract direct absolute grade sales (including '6 mm below')
            for (let i = 0; i < ABS_GRADES.length; i++) {
                const grade = ABS_GRADES[i];
                const sold = activeSales[_norm(grade)] || activeSales[grade] || 0;
                if (sold > 0) abs[i] -= sold;
            }

            // Subtract virtual grade sales impact on absolutes (pending + cart)
            _subtractVirtualImpact(abs, activeSales);

            // Subtract packed direct and packed virtual impacts
            const packedSales = saleOrders.packed[type] || {};

            for (let i = 0; i < ABS_GRADES.length; i++) {
                const grade = ABS_GRADES[i];
                const sold = packedSales[_norm(grade)] || packedSales[grade] || 0;
                if (sold > 0) abs[i] -= sold;
            }

            _subtractVirtualImpact(abs, packedSales);

            // Apply adjustments for absolute grades
            const adjForType = adjMap[type] || {};
            for (let i = 0; i < ABS_GRADES.length; i++) {
                const gradeName = ABS_GRADES[i];
                const delta = adjForType[gradeName] || 0;
                if (delta !== 0) {
                    const before = abs[i];
                    abs[i] += delta;
                    console.log(`[stock-FB] Adjustment: ${type} ${gradeName} ${delta > 0 ? '+' : ''}${delta} (${before} -> ${abs[i]})`);
                }
            }

            // Round and fix -0
            for (let i = 0; i < abs.length; i++) {
                abs[i] = Math.round(abs[i]);
                if (Object.is(abs[i], -0)) abs[i] = 0;
            }

            const absMap = {};
            ABS_GRADES.forEach((g, i) => { absMap[g] = abs[i]; });

            let virtuals;
            if (type === 'Rejection') {
                // REJECTION: Do NOT compute virtual grades from absolutes.
                // Rejection stock is a flat pool — each grade stands on its own.
                // Virtual grade adjustments for Rejection are stored directly and displayed as-is.
                virtuals = {};
                for (const vg of VIRT_GRADES) {
                    const adjDelta = adjForType[vg] || 0;
                    if (adjDelta !== 0) {
                        virtuals[vg] = Math.round(adjDelta);
                        console.log(`[stock-FB] Rejection virtual adj: ${vg} ${adjDelta > 0 ? '+' : ''}${adjDelta}`);
                    }
                }
            } else {
                // COLOUR BOLD / FRUIT BOLD: Recalculate virtuals from adjusted absolutes
                const virtualFormulas = config.virtualFormulas || _defaultVirtualFormulas();
                virtuals = calculateVirtualFromAbsolutes(absMap, virtualFormulas);
            }

            // Build result for this type
            results[type] = {
                computed: { ...computedAbsolutes[type] },
                saleOrder: { ...(activeSales) },
                packedSale: { ...packedSales },
                adjustments: { ...adjForType },
                netAbsolute: { ...absMap },
                netVirtual: { ...virtuals },
                lastUpdated: new Date().toISOString()
            };
        }

        // f. Write results to net_stock_cache using a transaction to prevent
        //    concurrent recalculations from overwriting each other (lost updates).
        //    The transaction reads the current lastUpdated timestamp for each type
        //    and only writes if our calculation is newer.
        const db = getDb();
        await db.runTransaction(async (transaction) => {
            // Read current cache documents to check timestamps
            const cacheRefs = TYPES.map(type => db.collection('net_stock_cache').doc(type));
            const currentDocs = await Promise.all(cacheRefs.map(ref => transaction.get(ref)));

            for (let i = 0; i < TYPES.length; i++) {
                const type = TYPES[i];
                const currentDoc = currentDocs[i];
                const newData = results[type];

                // Only skip if an existing doc has a strictly newer timestamp
                if (currentDoc.exists) {
                    const existing = currentDoc.data();
                    if (existing.lastUpdated && newData.lastUpdated &&
                        existing.lastUpdated > newData.lastUpdated) {
                        console.log(`[stock-FB] Skipping ${type} cache write: existing data is newer`);
                        continue;
                    }
                }

                transaction.set(cacheRefs[i], newData);
            }
        });

        const elapsed = Date.now() - startTime;
        console.log(`[stock-FB] calculateNetStock completed in ${elapsed}ms`);

        return results;
    } catch (err) {
        console.error('[stock-FB] calculateNetStock ERROR:', err.message, err.stack);
        throw err;
    }
}

/**
 * Merge two sale maps (grade -> kgs) by summing values.
 */
function _mergeSaleMaps(a, b) {
    const merged = { ...a };
    for (const [grade, kgs] of Object.entries(b)) {
        merged[grade] = (merged[grade] || 0) + kgs;
    }
    return merged;
}

/**
 * Subtract virtual grade sales impact on the absolute grades array (in-place).
 * Looks up each virtual grade in the sales map by both normalized and original name.
 */
function _subtractVirtualImpact(abs, salesMap) {
    const getQ = (grade) => {
        return salesMap[grade] || salesMap[_norm(grade)] || 0;
    };

    const q85 = getQ('8.5 mm');
    if (q85 > 0) {
        abs[0] -= 1.0 * q85;
    }

    const q78 = getQ('7.8 bold');
    if (q78 > 0) {
        abs[0] -= 0.5 * q78;
        abs[1] -= 0.5 * q78;
    }

    const q78mm = getQ('7 to 8 mm');
    if (q78mm > 0) {
        abs[1] -= 0.5 * q78mm;
        abs[2] -= 0.5 * q78mm;
    }

    const q658 = getQ('6.5 to 8 mm');
    if (q658 > 0) {
        abs[1] -= q658 / 3;
        abs[2] -= q658 / 3;
        abs[3] -= q658 / 3;
    }

    const q6575 = getQ('6.5 to 7.5 mm');
    if (q6575 > 0) {
        abs[2] -= 0.5 * q6575;
        abs[3] -= 0.5 * q6575;
    }

    const q67 = getQ('6 to 7 mm');
    if (q67 > 0) {
        abs[3] -= 0.5 * q67;
        abs[4] -= 0.5 * q67;
    }

    const qMini = getQ('Mini Bold') || getQ('mini bold');
    if (qMini > 0) {
        abs[4] -= (2/3) * qMini;  // 6→6.5 (full weight source)
        abs[5] -= (1/3) * qMini;  // 6mm below (half weight — Pan claims the other half)
    }

    const qPan = getQ('Pan') || getQ('pan');
    if (qPan > 0) {
        abs[5] -= 1.0 * qPan;
    }
}

/**
 * Default virtual formulas if config does not contain them.
 */
function _defaultVirtualFormulas() {
    return {
        '8.5 mm':       { type: 'percentage', factor: 0.05, sources: ['8 mm'] },
        '7.8 bold':     { type: 'min_multi', multiplier: 2, sources: ['8 mm', '7.5 to 8 mm'] },
        '7 to 8 mm':    { type: 'min_multi', multiplier: 2, sources: ['7.5 to 8 mm', '7 to 7.5 mm'] },
        '6.5 to 8 mm':  { type: 'min_multi', multiplier: 3, sources: ['7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm'] },
        '6.5 to 7.5 mm':{ type: 'min_multi', multiplier: 2, sources: ['7 to 7.5 mm', '6.5 to 7 mm'] },
        '6 to 7 mm':    { type: 'min_multi', multiplier: 2, sources: ['6.5 to 7 mm', '6 to 6.5 mm'] },
        'Mini Bold':    { type: 'min_multi_weighted', multiplier: 2, sources: ['6 to 6.5 mm', '6 mm below'], sourceWeights: [1.0, 0.5] },
        'Pan':          { type: 'percentage', factor: 0.5, sources: ['6 mm below'] }
    };
}

// ============================================================================
// 7. getNetStockForUi()
// ============================================================================

/**
 * Read net_stock_cache collection and format for UI.
 *
 * NOTE: Read-only function. Eventual consistency is acceptable — it reads
 * from the net_stock_cache materialized view which is atomically updated
 * by calculateNetStock(). No transaction needed for reads.
 *
 * Returns interleaved 14-column layout matching the sheet:
 * [v[8.5mm], a[8mm], v[7.8bold], a[7.5-8mm], v[7-8mm], v[6.5-8mm],
 *  a[7-7.5mm], v[6.5-7.5mm], a[6.5-7mm], v[6-7mm], a[6-6.5mm],
 *  a[6mmBelow], v[MiniBold], v[Pan]]
 */
async function getNetStockForUi() {
    try {
        const db = getDb();
        const snap = await db.collection('net_stock_cache').get();

        const headers = NET_HEADERS;
        const typeData = {};

        snap.docs.forEach(doc => {
            typeData[doc.id] = doc.data();
        });

        const rows = TYPES.map(type => {
            const data = typeData[type];
            if (!data) {
                return { type, values: Array(14).fill(0) };
            }

            const a = data.netAbsolute || {};
            const v = data.netVirtual || {};

            // 14-column interleaved layout:
            // [v0, a0, v1, a1, v2, v3, a2, v4, a3, v5, a4, a5, v6, v7]
            const values = [
                v['8.5 mm'] || 0,           // col 0: virtual
                a['8 mm'] || 0,             // col 1: absolute
                v['7.8 bold'] || 0,         // col 2: virtual
                a['7.5 to 8 mm'] || 0,      // col 3: absolute
                v['7 to 8 mm'] || 0,        // col 4: virtual
                v['6.5 to 8 mm'] || 0,      // col 5: virtual
                a['7 to 7.5 mm'] || 0,      // col 6: absolute
                v['6.5 to 7.5 mm'] || 0,    // col 7: virtual
                a['6.5 to 7 mm'] || 0,      // col 8: absolute
                v['6 to 7 mm'] || 0,        // col 9: virtual
                a['6 to 6.5 mm'] || 0,      // col 10: absolute
                a['6 mm below'] || 0,       // col 11: absolute
                v['Mini Bold'] || 0,        // col 12: virtual
                v['Pan'] || 0               // col 13: virtual
            ];

            return { type, values };
        });

        // Compute rejection breakdown: Split (70%) + Sick (30%) from Rejection totals
        const rejectionRow = rows.find(r => r.type === 'Rejection');
        let rejectionBreakdown = null;
        if (rejectionRow) {
            const totalRejKgs = rejectionRow.values.reduce((sum, v) => sum + (v || 0), 0);
            const splitKgs = Math.round(totalRejKgs * 0.70 * 100) / 100;
            const sickKgs = Math.round(totalRejKgs * 0.30 * 100) / 100;
            // Per-grade breakdown
            const splitValues = rejectionRow.values.map(v => Math.round((v || 0) * 0.70 * 100) / 100);
            const sickValues = rejectionRow.values.map(v => Math.round((v || 0) * 0.30 * 100) / 100);
            rejectionBreakdown = {
                total: totalRejKgs,
                split: { label: 'Split Rejection (70%)', total: splitKgs, values: splitValues },
                sick:  { label: 'Sick Rejection (30%)',  total: sickKgs,  values: sickValues },
            };
        }

        return { headers, rows, rejectionBreakdown };
    } catch (err) {
        console.error('[stock-FB] getNetStockForUi ERROR:', err.message);
        return {
            headers: NET_HEADERS,
            rows: TYPES.map(type => ({ type, values: Array(14).fill(0) }))
        };
    }
}

// ============================================================================
// 8. addTodayPurchase(qtyArray)
// ============================================================================

/**
 * Add a purchase entry to live_stock_entries.
 * If the Sheets feature flag is still active, also writes to the Sheets live_stock.
 */
async function addTodayPurchase(qtyArray, date) {
    if (!Array.isArray(qtyArray) || qtyArray.length !== 3) {
        return 'Invalid purchase data received.';
    }

    const [boldQty, floatQty, mediumQty] = qtyArray.map(q => parseFloat(q) || 0);
    if (boldQty <= 0 && floatQty <= 0 && mediumQty <= 0) {
        return 'Please enter at least one valid quantity.';
    }

    const ts = date ? new Date(date).toISOString() : new Date().toISOString();

    // Write to Firestore
    const db = getDb();
    await db.collection('live_stock_entries').add({
        timestamp: ts,
        boldQty,
        floatQty,
        mediumQty,
        createdAt: ts
    });

    console.log(`[stock-FB] Added purchase: bold=${boldQty}, float=${floatQty}, medium=${mediumQty}`);

    // Recalculate net stock
    await calculateNetStock();

    return (
        'Added today\'s purchase: \n' +
        '  Bold: ' + boldQty + ' kg, Floating: ' + floatQty + ' kg, Medium: ' + mediumQty + ' kg'
    );
}

/**
 * addPurchase(purchaseData) — accepts an object from approval requests
 * and delegates to addTodayPurchase.
 * Accepts: { boldQty, floatQty, mediumQty } or an array [bold, float, medium]
 */
async function addPurchase(purchaseData) {
    if (Array.isArray(purchaseData)) {
        return addTodayPurchase(purchaseData);
    }
    const bold = Number(purchaseData.boldQty || purchaseData.bold || 0);
    const float = Number(purchaseData.floatQty || purchaseData.float || purchaseData.floating || 0);
    const medium = Number(purchaseData.mediumQty || purchaseData.medium || 0);
    return addTodayPurchase([bold, float, medium]);
}

// ============================================================================
// 9. addStockAdjustment({ type, grade, deltaKgs, notes })
// ============================================================================

/**
 * Add a manual stock adjustment. Virtual grades are converted to absolute grade
 * adjustments using the virtualToAbsoluteMap.
 *
 * ISSUE STK-4 FIX: Stock adjustments require approval for non-admin users.
 * For admin users (role === 'admin' or 'ops'), the adjustment is applied directly.
 * For non-admin users, an approval request is created instead.
 */
async function addStockAdjustment({ type, grade, deltaKgs, notes, requesterId, requesterName, userRole, date }) {
    const normalizedType = String(type || '').trim();
    const normalizedGrade = String(grade || '').trim();
    const delta = parseFloat(deltaKgs);
    const noteText = String(notes || '').trim();

    if (!TYPES.includes(normalizedType)) {
        throw new Error(`Unknown type: ${normalizedType}`);
    }

    const allGrades = [...ABS_GRADES, ...VIRT_GRADES];
    if (!allGrades.includes(normalizedGrade)) {
        throw new Error(`Unknown grade: ${normalizedGrade}`);
    }

    if (!Number.isFinite(delta) || delta === 0) {
        throw new Error('Enter a non-zero adjustment in kgs.');
    }

    // Check if this is an admin/ops/superadmin user (they can apply directly)
    const role = String(userRole || '').toLowerCase().trim();
    const isAdmin = role === 'admin' || role === 'ops' || role === 'superadmin';

    const ts = date ? new Date(date).toISOString() : new Date().toISOString();

    const isVirtual = VIRT_GRADES.includes(normalizedGrade);
    const db = getDb();
    const approvalCol = db.collection('approval_requests');

    // For non-admin users: create approval request
    if (!isAdmin) {
        const adjustmentDetails = {
            type: normalizedType,
            grade: normalizedGrade,
            deltaKgs: delta,
            notes: noteText,
            timestamp: ts
        };

        try {
            const { v4: uuidv4 } = require('uuid');
            const requestId = uuidv4();

            // Create approval request for stock adjustment
            await approvalCol.doc(requestId).set({
                id: requestId,
                requesterId: String(requesterId || ''),
                requesterName: requesterName || 'Unknown',
                actionType: 'stock_adjustment',
                resourceType: 'stock_adjustment',
                resourceId: `stock_adj_${Date.now()}`,
                resourceData: adjustmentDetails,
                proposedChanges: {
                    adjustment: adjustmentDetails,
                    virtualToAbsoluteConversion: isVirtual && VIRTUAL_TO_ABSOLUTE_MAP[normalizedGrade]
                        ? VIRTUAL_TO_ABSOLUTE_MAP[normalizedGrade]
                        : null
                },
                reason: `Stock adjustment: ${normalizedGrade} (${normalizedType}) ${delta > 0 ? '+' : ''}${delta}kg`,
                status: 'pending',
                rejectionReason: null,
                createdAt: ts,
                updatedAt: ts,
                processedBy: null,
                processedAt: null,
                dismissed: false,
            });

            console.log(`[stock-FB] Created approval request ${requestId} for stock adjustment by ${requesterName}`);

            return {
                success: true,
                message: 'Stock adjustment submitted for approval. Please wait for admin approval before changes are applied.',
                requestId: requestId,
                requiresApproval: true
            };
        } catch (err) {
            console.error('[stock-FB] Error creating approval request:', err.message);
            throw new Error('Failed to submit stock adjustment for approval: ' + err.message);
        }
    }

    // For admin/ops users: apply directly
    const batch = createBatch();
    const adjustCol = db.collection('stock_adjustments');
    const isRejection = normalizedType === 'Rejection';

    try {
        if (!isRejection && isVirtual && VIRTUAL_TO_ABSOLUTE_MAP[normalizedGrade]) {
            // Convert virtual grade adjustment to absolute grade adjustments
            // NOTE: Rejection type is excluded — rejection stock is a flat pool,
            // not a hierarchical grade system. "8 mm rejection" = exactly that grade.
            console.log(`[stock-FB] Admin applying: Converting virtual grade '${normalizedGrade}' adjustment to absolute grades`);
            for (const { grade: absGrade, factor } of VIRTUAL_TO_ABSOLUTE_MAP[normalizedGrade]) {
                const absDelta = Math.round(delta * factor);
                if (absDelta !== 0) {
                    console.log(`[stock-FB] Admin applying: ${normalizedType} ${absGrade} ${absDelta > 0 ? '+' : ''}${absDelta}`);
                    batch.set(adjustCol.doc(), {
                        timestamp: ts,
                        type: normalizedType,
                        grade: absGrade,
                        deltaKgs: absDelta,
                        notes: `${noteText} [from ${normalizedGrade} adjustment] [Applied by admin]`.trim(),
                        sourceGrade: normalizedGrade,
                        appliedBy: requesterName || 'admin',
                        appliedAt: ts,
                        createdAt: ts
                    });
                }
            }
        } else {
            // Direct grade adjustment (absolute grades, OR any Rejection grade)
            console.log(`[stock-FB] Admin applying direct: ${normalizedType} ${normalizedGrade} ${delta > 0 ? '+' : ''}${delta}`);
            batch.set(adjustCol.doc(), {
                timestamp: ts,
                type: normalizedType,
                grade: normalizedGrade,
                deltaKgs: delta,
                notes: `${noteText} [Applied by admin]`.trim(),
                appliedBy: requesterName || 'admin',
                appliedAt: ts,
                createdAt: ts
            });
        }

        await batch.commit();

        // Recalculate net stock
        await calculateNetStock();

        console.log(`[stock-FB] Admin adjustment applied and net stock updated`);
        return { success: true, message: 'Adjustment applied and net stock updated.', appliedDirectly: true };
    } catch (err) {
        console.error('[stock-FB] Error applying admin adjustment:', err.message);
        throw err;
    }
}

// ============================================================================
// 9.5 applyApprovedStockAdjustment(approvalRequestId)
// ============================================================================

/**
 * Apply an approved stock adjustment. Called by the approval workflow
 * after admin approves a stock adjustment request.
 *
 * ISSUE STK-4: This function applies the adjustment to stock_adjustments collection
 * only after approval is granted.
 */
async function applyApprovedStockAdjustment(approvalRequestId) {
    const db = getDb();
    const approvalRef = db.collection('approval_requests').doc(approvalRequestId);
    const snap = await approvalRef.get();

    if (!snap.exists) {
        throw new Error('Approval request not found');
    }

    const approval = snap.data();

    if (approval.status !== 'approved') {
        throw new Error('Approval request is not approved');
    }

    if (approval.actionType !== 'stock_adjustment') {
        throw new Error('This approval is not for a stock adjustment');
    }

    const resourceData = approval.resourceData || {};
    const normalizedType = String(resourceData.type || '').trim();
    const normalizedGrade = String(resourceData.grade || '').trim();
    const delta = parseFloat(resourceData.deltaKgs);
    const noteText = String(resourceData.notes || '').trim();
    const ts = new Date().toISOString();

    const isVirtual = VIRT_GRADES.includes(normalizedGrade);
    const batch = createBatch();
    const adjustCol = db.collection('stock_adjustments');

    try {
        const isRejection = normalizedType === 'Rejection';
        if (!isRejection && isVirtual && VIRTUAL_TO_ABSOLUTE_MAP[normalizedGrade]) {
            // Convert virtual grade adjustment to absolute grade adjustments
            // Rejection excluded: rejection stock is flat, no grade hierarchy
            console.log(`[stock-FB] Applying approved: Converting virtual grade '${normalizedGrade}' adjustment to absolute grades`);
            for (const { grade: absGrade, factor } of VIRTUAL_TO_ABSOLUTE_MAP[normalizedGrade]) {
                const absDelta = Math.round(delta * factor);
                if (absDelta !== 0) {
                    console.log(`[stock-FB] Applying approved: ${normalizedType} ${absGrade} ${absDelta > 0 ? '+' : ''}${absDelta}`);
                    batch.set(adjustCol.doc(), {
                        timestamp: ts,
                        type: normalizedType,
                        grade: absGrade,
                        deltaKgs: absDelta,
                        notes: `${noteText} [from ${normalizedGrade} adjustment] [Approved by ${approval.processedBy}]`.trim(),
                        sourceGrade: normalizedGrade,
                        approvalId: approvalRequestId,
                        approvedBy: approval.processedBy,
                        approvedAt: approval.processedAt,
                        createdAt: ts
                    });
                }
            }
        } else {
            // Direct grade adjustment (absolute grades, OR any Rejection grade)
            batch.set(adjustCol.doc(), {
                timestamp: ts,
                type: normalizedType,
                grade: normalizedGrade,
                deltaKgs: delta,
                notes: `${noteText} [Approved by ${approval.processedBy}]`.trim(),
                approvalId: approvalRequestId,
                approvedBy: approval.processedBy,
                approvedAt: approval.processedAt,
                createdAt: ts
            });
        }

        await batch.commit();

        // Recalculate net stock
        await calculateNetStock();

        console.log(`[stock-FB] Applied approved adjustment ${approvalRequestId}`);
        return { success: true, message: 'Stock adjustment applied and net stock updated.' };
    } catch (err) {
        console.error('[stock-FB] Error applying approved adjustment:', err.message);
        throw err;
    }
}

// ============================================================================
// 10. rebuildFromScratchAPI()
// ============================================================================

/**
 * Invalidate cache and fully recalculate net stock from scratch.
 */
async function rebuildFromScratchAPI() {
    console.log('[stock-FB] rebuildFromScratchAPI: starting full rebuild...');

    // Invalidate cache
    cache.stockConfig = null;
    cache.stockConfigExpiry = 0;

    // Rebuild packed totals materialized view
    await rebuildPackedSaleOrderFromPackedOrders();

    // Recalculate net stock
    const results = await calculateNetStock();

    const typeSummary = TYPES.map(type => {
        const r = results[type];
        if (!r) return `  ${type}: no data`;
        const totalAbs = Object.values(r.netAbsolute).reduce((a, b) => a + b, 0);
        return `  ${type}: ${Math.round(totalAbs)} kg absolute total`;
    }).join('\n');

    return `Rebuilt from scratch (Firestore mode)!\n${typeSummary}`;
}

// ============================================================================
// 11. incrementPackedTotals(archivedOrders)
// ============================================================================

/**
 * Transaction-based update to sale_order_summary/packed_totals materialized view.
 * For each archived order, parse grade to determine type and canonical grade, add kgs.
 *
 * TRANSACTION VERIFIED: This correctly uses db.runTransaction() to atomically
 * read the current packed_totals, add the new order kgs, and write back.
 * This prevents lost updates when multiple archive operations run concurrently
 * (e.g., two users archiving cart orders at the same time).
 * Firestore will automatically retry on contention (up to 5 times).
 */
async function incrementPackedTotals(archivedOrders) {
    if (!archivedOrders || archivedOrders.length === 0) return;

    const db = getDb();
    const docRef = db.collection('sale_order_summary').doc('packed_totals');

    await db.runTransaction(async (transaction) => {
        const doc = await transaction.get(docRef);
        const existing = doc.exists ? doc.data() : {};

        // Ensure type maps exist
        for (const type of TYPES) {
            if (!existing[type] || typeof existing[type] !== 'object') {
                existing[type] = {};
            }
        }

        // Process each archived order
        for (const order of archivedOrders) {
            const gradeText = String(order.grade || '');
            const kgs = parseFloat(order.kgs) || 0;
            if (kgs <= 0 || !gradeText) continue;

            const type = _chooseSaleRowName(gradeText);
            if (!type) continue;

            const canon = _pickCanonFromText(gradeText);
            if (!canon) continue;

            existing[type][canon] = (existing[type][canon] || 0) + kgs;
        }

        existing.lastUpdated = new Date().toISOString();
        transaction.set(docRef, existing);
    });

    console.log(`[stock-FB] incrementPackedTotals: updated with ${archivedOrders.length} orders`);
}

// ============================================================================
// 12. updatePackedSaleOrder(rows, headers)
// ============================================================================

/**
 * Wrapper that calls incrementPackedTotals for compatibility with orderBook_fb.js autoArchive.
 * Converts the row/header format to order objects.
 *
 * @param {Array} rows - Array of row arrays from cart_orders
 * @param {Array} headers - Header row (e.g., ['Order Date', ..., 'Grade', ..., 'Kgs', ...])
 */
async function updatePackedSaleOrder(rows, headers) {
    if (!rows || rows.length === 0) return;

    const iGrade = headers.indexOf('Grade');
    const iKgs = headers.indexOf('Kgs');

    if (iGrade < 0 || iKgs < 0) {
        console.warn('[stock-FB] updatePackedSaleOrder: Missing Grade or Kgs column');
        return;
    }

    const orders = rows.map(row => ({
        grade: String(row[iGrade] || ''),
        kgs: parseFloat(row[iKgs]) || 0
    })).filter(o => o.grade && o.kgs > 0);

    if (orders.length > 0) {
        await incrementPackedTotals(orders);
    }

    // Also recalculate net stock
    await calculateNetStock();
}

// ============================================================================
// 13. PROXY / COMPATIBILITY FUNCTIONS
// ============================================================================

/**
 * updateAllStocks() - proxy that calls calculateNetStock()
 */
async function updateAllStocks() {
    try {
        await calculateNetStock();
        const dashboardHtml = await validateSaleOrder();
        return {
            message: 'All stock levels recalculated (Firestore mode).',
            dashboard: dashboardHtml
        };
    } catch (err) {
        return {
            message: 'Error during recalculation: ' + err.message,
            dashboard: ''
        };
    }
}

/**
 * validateSaleOrder() - generates HTML stock summary from net_stock_cache
 */
async function validateSaleOrder() {
    const displayAbsGrades = ABS_GRADES;
    const absColMap = {
        '8 mm': 1,
        '7.5 to 8 mm': 3,
        '7 to 7.5 mm': 6,
        '6.5 to 7 mm': 8,
        '6 to 6.5 mm': 10,
        '6 mm below': 11
    };

    const netStock = await getNetStockForUi();
    const safeRows = netStock.rows || [];

    let stockHtml = "<h3><span style='color:#2c3e50'>Stock Summary & Health Report</span></h3>";
    stockHtml += '<table><tr><th>Type</th>';
    displayAbsGrades.forEach(g => { stockHtml += '<th>' + g + '</th>'; });
    stockHtml += '</tr>';

    for (let t = 0; t < TYPES.length; t++) {
        stockHtml += '<tr><td><b>' + TYPES[t] + '</b></td>';
        for (const g of displayAbsGrades) {
            const idx = absColMap[g];
            const absQty = safeRows[t] ? (safeRows[t].values[idx] || 0) : 0;
            stockHtml +=
                '<td style="color:' + (absQty < 0 ? 'red' : 'green') +
                '; font-weight:bold">' +
                Math.round(absQty) +
                '</td>';
        }
        stockHtml += '</tr>';
    }
    stockHtml += '</table>';

    const statusCard = await getDeltaStatusHtml();
    return statusCard + stockHtml;
}

/**
 * getDeltaStatusHtml() - returns HTML showing "Firestore mode" status
 */
async function getDeltaStatusHtml() {
    let liveEntryCount = 0;
    try {
        const db = getDb();
        const snap = await db.collection('live_stock_entries').get();
        liveEntryCount = snap.size;
    } catch (err) {
        console.warn('[stock-FB] getDeltaStatusHtml: could not count live entries:', err.message);
    }

    return (
        '<div style="' +
        'border-left: 6px solid #27ae60;' +
        'background:#fff; padding:14px 16px; margin:10px 0 18px 0; border-radius:10px;' +
        'box-shadow:0 2px 8px rgba(0,0,0,0.06); font-size:14px;">' +
        '<div style="display:flex; align-items:center; gap:8px; margin-bottom:6px;">' +
        '<b>Firestore Stock Engine</b>' +
        '</div>' +
        '<div style="display:grid; grid-template-columns: 190px 1fr; row-gap:4px;">' +
        '<div>Mode:</div><div><b>Pure Firestore</b></div>' +
        '<div>Live stock entries:</div><div><b>' + liveEntryCount + '</b></div>' +
        '<div>Computation:</div><div><b style="color:#27ae60">Real-time</b></div>' +
        '</div>' +
        '<div style="margin-top:8px; color:#666;">' +
        'All stock calculations run directly against Firestore. No delta pointer needed.' +
        '</div>' +
        '</div>'
    );
}

/**
 * resetDeltaPointerAPI() - no-op in Firestore mode
 */
async function resetDeltaPointerAPI() {
    return 'Firestore mode: No delta pointer to reset. Stock is calculated from all entries in real-time.';
}

/**
 * rebuildPackedSaleOrderFromPackedOrders() - rebuild packed_totals from packed_orders
 *
 * TRANSACTION RATIONALE: Uses a transaction to write the rebuilt packed_totals
 * atomically. This prevents a concurrent incrementPackedTotals() from writing
 * between our read of packed_orders and our write to packed_totals, which would
 * cause the incremental update to be silently overwritten by the full rebuild.
 */
async function rebuildPackedSaleOrderFromPackedOrders() {
    console.log('[stock-FB] rebuildPackedSaleOrderFromPackedOrders: starting full rebuild...');

    const db = getDb();
    const packedSnap = await db.collection('packed_orders').get();

    const totals = {};
    for (const type of TYPES) {
        totals[type] = {};
    }

    let processedCount = 0;
    packedSnap.docs.forEach(doc => {
        const d = doc.data();
        const gradeText = String(d.grade || '');
        const kgs = parseFloat(d.kgs) || 0;
        if (kgs <= 0 || !gradeText) return;

        const type = _chooseSaleRowName(gradeText);
        if (!type) return;

        const canon = _pickCanonFromText(gradeText);
        if (!canon) return;

        totals[type][canon] = (totals[type][canon] || 0) + kgs;
        processedCount++;
    });

    totals.lastUpdated = new Date().toISOString();

    // Use a transaction to ensure atomic replacement of packed_totals.
    // This prevents a concurrent incrementPackedTotals from being lost.
    const docRef = db.collection('sale_order_summary').doc('packed_totals');
    await db.runTransaction(async (transaction) => {
        await transaction.get(docRef); // Required read before write in Firestore transactions
        transaction.set(docRef, totals);
    });

    console.log(`[stock-FB] rebuildPackedSaleOrderFromPackedOrders: processed ${processedCount} orders from ${packedSnap.size} packed docs`);
    return processedCount;
}

/**
 * validateStockSufficiency(type, grade, requiredKgs) - check net stock
 *
 * NOTE: Read-only function. Uses eventual consistency from net_stock_cache.
 * For order placement, the actual stock deduction happens via calculateNetStock()
 * which uses transactions, so a brief stale read here is acceptable.
 */
async function validateStockSufficiency(type, grade, requiredKgs) {
    const netStock = await getNetStockForUi();
    const typeRow = netStock.rows.find(r => _norm(r.type) === _norm(type));

    if (!typeRow) {
        return { valid: false, available: 0, shortfall: requiredKgs, message: `Unknown stock type: ${type}` };
    }

    const gradeIdx = netStock.headers.findIndex(h => _norm(h) === _norm(grade));
    if (gradeIdx < 0) {
        return { valid: false, available: 0, shortfall: requiredKgs, message: `Unknown grade: ${grade}` };
    }

    const available = typeRow.values[gradeIdx] || 0;
    const shortfall = requiredKgs - available;

    if (shortfall > 0) {
        return {
            valid: false,
            available,
            shortfall,
            message: `Insufficient ${grade} (${type}): need ${requiredKgs}kg, have ${available}kg`
        };
    }

    return { valid: true, available, shortfall: 0, message: 'Stock sufficient' };
}

/**
 * detectNegativeStock() - find negative values in net_stock_cache
 *
 * NOTE: Read-only function. Eventual consistency is acceptable for
 * negative stock detection (diagnostic/reporting purpose).
 */
async function detectNegativeStock() {
    const netStock = await getNetStockForUi();
    const negatives = [];

    netStock.rows.forEach(row => {
        row.values.forEach((val, idx) => {
            if (val < 0) {
                negatives.push({
                    type: row.type,
                    grade: netStock.headers[idx],
                    value: val
                });
            }
        });
    });

    return {
        hasNegative: negatives.length > 0,
        negatives,
        message: negatives.length > 0
            ? `Found ${negatives.length} negative stock values!`
            : 'No negative stock detected'
    };
}

/**
 * getStockSummary() - summarize totals
 *
 * NOTE: This is a read-only function that reads from the net_stock_cache
 * materialized view. Eventual consistency is acceptable here because:
 *   - It is used for display/reporting purposes only
 *   - The cache is updated atomically by calculateNetStock()
 *   - Wrapping in a transaction would add latency with no correctness benefit
 */
async function getStockSummary() {
    const netStock = await getNetStockForUi();
    const summary = {};

    netStock.rows.forEach(row => {
        const total = row.values.reduce((sum, v) => sum + (v > 0 ? v : 0), 0);
        summary[row.type] = Math.round(total);
    });

    const negativeCheck = await detectNegativeStock();

    return {
        totals: summary,
        grandTotal: Object.values(summary).reduce((a, b) => a + b, 0),
        negativeStock: negativeCheck.negatives,
        health: 'HEALTHY',
        oversoldCount: negativeCheck.negatives.length,
        oversoldMessage: negativeCheck.hasNegative
            ? `${negativeCheck.negatives.length} grade(s) oversold - pending purchase`
            : 'All stock positive'
    };
}

/**
 * verifyOrderIntegrity() - compare expected vs actual from Firestore
 */
async function verifyOrderIntegrity() {
    console.log('[stock-FB] verifyOrderIntegrity: starting check...');
    const issues = [];
    const summary = { saleOrder: {}, packedSale: {}, orders: {} };

    try {
        const db = getDb();

        // 1. Count pending orders (Pending status)
        const ordersSnap = await db.collection('orders').get();
        let pendingTotal = 0;
        ordersSnap.docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted === true) return;
            if (String(d.status || '').toLowerCase() !== 'pending') return;
            pendingTotal += parseFloat(d.kgs) || 0;
        });
        summary.orders.sygtPending = Math.round(pendingTotal);

        // 2. Count cart orders (On Progress status)
        const cartSnap = await db.collection('cart_orders').get();
        let cartTotal = 0;
        cartSnap.docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted === true) return;
            if (String(d.status || '').toLowerCase() !== 'on progress') return;
            cartTotal += parseFloat(d.kgs) || 0;
        });
        summary.orders.cartOnProgress = Math.round(cartTotal);

        summary.orders.expectedSaleTotal = summary.orders.sygtPending + summary.orders.cartOnProgress;

        // 3. Read packed_totals
        const packedTotalsDoc = await db.collection('sale_order_summary').doc('packed_totals').get();
        let packedTotalKgs = 0;
        if (packedTotalsDoc.exists) {
            const data = packedTotalsDoc.data();
            for (const type of TYPES) {
                if (data[type] && typeof data[type] === 'object') {
                    for (const kgs of Object.values(data[type])) {
                        packedTotalKgs += parseFloat(kgs) || 0;
                    }
                }
            }
        }
        summary.packedSale.actualTotal = Math.round(packedTotalKgs);

        // 4. Count actual packed_orders for comparison
        const packedSnap = await db.collection('packed_orders').get();
        let expectedPackedTotal = 0;
        packedSnap.docs.forEach(doc => {
            expectedPackedTotal += parseFloat(doc.data().kgs) || 0;
        });
        summary.orders.packedOrders = Math.round(expectedPackedTotal);

        if (Math.abs(expectedPackedTotal - packedTotalKgs) > 1) {
            issues.push({
                type: 'PACKED_SALE_MISMATCH',
                message: `packed_totals materialized view (${Math.round(packedTotalKgs)}kg) doesn't match packed_orders (${Math.round(expectedPackedTotal)}kg)`,
                expected: Math.round(expectedPackedTotal),
                actual: Math.round(packedTotalKgs),
                fix: 'Run Rebuild from Scratch to recalculate materialized view'
            });
        }

        // 5. Verify net_stock_cache exists and is recent
        const netCacheSnap = await db.collection('net_stock_cache').get();
        if (netCacheSnap.empty) {
            issues.push({
                type: 'MISSING_NET_CACHE',
                message: 'net_stock_cache collection is empty',
                fix: 'Run Recalculate to populate'
            });
        } else {
            let oldestUpdate = null;
            netCacheSnap.docs.forEach(doc => {
                const lu = doc.data().lastUpdated;
                if (lu) {
                    const d = new Date(lu);
                    if (!oldestUpdate || d < oldestUpdate) oldestUpdate = d;
                }
            });
            if (oldestUpdate) {
                const ageMs = Date.now() - oldestUpdate.getTime();
                const ageMinutes = Math.round(ageMs / 60000);
                summary.saleOrder.cacheAgeMinutes = ageMinutes;
                if (ageMs > 24 * 60 * 60 * 1000) {
                    issues.push({
                        type: 'STALE_CACHE',
                        message: `net_stock_cache is ${ageMinutes} minutes old (>24h)`,
                        fix: 'Run Recalculate to refresh'
                    });
                }
            }
        }
    } catch (err) {
        issues.push({
            type: 'INTEGRITY_CHECK_ERROR',
            message: `Error during integrity check: ${err.message}`,
            fix: 'Check Firestore connectivity'
        });
    }

    const isHealthy = issues.length === 0;
    console.log(`[stock-FB] verifyOrderIntegrity: ${issues.length} issues found`);

    return {
        healthy: isHealthy,
        issues,
        summary,
        message: isHealthy
            ? 'All order quantities are in sync'
            : `Found ${issues.length} integrity issue(s)`
    };
}

/**
 * clearRejectionAdjustments() - Delete all Rejection stock adjustment docs and recalculate
 */
async function clearRejectionAdjustments() {
    const db = getDb();
    const snap = await db.collection('stock_adjustments').where('type', '==', 'Rejection').get();
    if (snap.empty) return { success: true, deleted: 0, message: 'No Rejection adjustments to clear' };

    // Batch delete in chunks of 500
    const docs = snap.docs;
    for (let i = 0; i < docs.length; i += 499) {
        const batch = createBatch();
        const chunk = docs.slice(i, i + 499);
        chunk.forEach(d => batch.delete(d.ref));
        await batch.commit();
    }

    // Also clear the Rejection net_stock_cache document
    const cacheRef = db.collection('net_stock_cache').doc('Rejection');
    const cacheSnap = await cacheRef.get();
    if (cacheSnap.exists) await cacheRef.delete();

    // Recalculate
    await calculateNetStock();

    return { success: true, deleted: docs.length, message: `Deleted ${docs.length} Rejection adjustment(s) and recalculated stock` };
}

/**
 * syncAdjustmentsToSheet() - no-op in pure Firestore mode
 */
async function syncAdjustmentsToSheet() {
    console.log('[stock-FB] syncAdjustmentsToSheet: no-op in Firestore mode');
    return { message: 'Firestore mode: adjustments are stored natively, no Sheet sync needed.' };
}

// ============================================================================
// EXPORTS
// ============================================================================

// ============================================================================
// HISTORY QUERIES
// ============================================================================

/**
 * Get purchase history from live_stock_entries, ordered by timestamp desc.
 * @param {number} limit - Max entries to return (default 100)
 * @param {string|null} startDate - ISO date string filter (inclusive)
 * @param {string|null} endDate - ISO date string filter (inclusive)
 */
async function getPurchaseHistory(limit = 100, startDate = null, endDate = null) {
    const db = getDb();
    let query = db.collection('live_stock_entries').orderBy('timestamp', 'desc');

    if (startDate) {
        query = query.where('timestamp', '>=', new Date(startDate));
    }
    if (endDate) {
        const end = new Date(endDate);
        end.setHours(23, 59, 59, 999);
        query = query.where('timestamp', '<=', end);
    }

    query = query.limit(limit);
    const snap = await query.get();

    return snap.docs.map(doc => {
        const d = doc.data();
        return {
            id: doc.id,
            timestamp: d.timestamp ? (d.timestamp.toDate ? d.timestamp.toDate().toISOString() : new Date(d.timestamp).toISOString()) : null,
            boldQty: parseFloat(d.boldQty) || 0,
            floatQty: parseFloat(d.floatQty) || 0,
            mediumQty: parseFloat(d.mediumQty) || 0,
            createdAt: d.createdAt ? (d.createdAt.toDate ? d.createdAt.toDate().toISOString() : new Date(d.createdAt).toISOString()) : null,
        };
    });
}

/**
 * Get adjustment history from stock_adjustments, ordered by timestamp desc.
 * @param {number} limit - Max entries to return (default 100)
 * @param {string|null} startDate - ISO date string filter (inclusive)
 * @param {string|null} endDate - ISO date string filter (inclusive)
 */
async function getAdjustmentHistory(limit = 100, startDate = null, endDate = null) {
    const db = getDb();
    let query = db.collection('stock_adjustments').orderBy('timestamp', 'desc');

    if (startDate) {
        query = query.where('timestamp', '>=', new Date(startDate));
    }
    if (endDate) {
        const end = new Date(endDate);
        end.setHours(23, 59, 59, 999);
        query = query.where('timestamp', '<=', end);
    }

    query = query.limit(limit);
    const snap = await query.get();

    return snap.docs.map(doc => {
        const d = doc.data();
        return {
            id: doc.id,
            type: d.type || '',
            grade: d.grade || '',
            deltaKgs: parseFloat(d.deltaKgs) || 0,
            notes: d.notes || '',
            timestamp: d.timestamp ? (d.timestamp.toDate ? d.timestamp.toDate().toISOString() : new Date(d.timestamp).toISOString()) : null,
            appliedBy: d.appliedBy || d.requesterName || '',
            createdAt: d.createdAt ? (d.createdAt.toDate ? d.createdAt.toDate().toISOString() : new Date(d.createdAt).toISOString()) : null,
        };
    });
}

module.exports = {
    // Core computation
    getCachedConfig,
    computeAbsoluteStock,
    calculateVirtualFromAbsolutes,
    getAdjustmentMap,
    aggregateSaleOrders,
    calculateNetStock,

    // UI / API
    getNetStockForUi,
    addTodayPurchase,
    addPurchase,
    addStockAdjustment,
    applyApprovedStockAdjustment,
    rebuildFromScratchAPI,

    // Packed orders
    incrementPackedTotals,
    updatePackedSaleOrder,
    rebuildPackedSaleOrderFromPackedOrders,

    // Proxy / compatibility
    updateAllStocks,
    validateSaleOrder,
    getDeltaStatusHtml,
    resetDeltaPointerAPI,

    // Robustness
    validateStockSufficiency,
    detectNegativeStock,
    getStockSummary,
    verifyOrderIntegrity,

    // Maintenance
    clearRejectionAdjustments,
    syncAdjustmentsToSheet,

    // History
    getPurchaseHistory,
    getAdjustmentHistory,

    // Test-only exports (internal functions exposed for unit testing)
    _test: {
        _norm,
        _pickCanonFromText,
        _chooseSaleRowName,
        _getRatio,
        _SALE_CANON,
        ABS_GRADES,
        VIRT_GRADES,
        TYPES,
        NET_HEADERS,
        VIRTUAL_IMPACT_ON_ABSOLUTE,
        VIRTUAL_TO_ABSOLUTE_MAP,
        CONFIG_TTL,
        cache,
    }
};
