/**
 * Dashboard Module — Firebase Firestore Backend
 * Drop-in replacement for ../dashboard.js (Phase 8, Wave 7)
 *
 * ALL data comes from Firestore — no Sheets dependency.
 *
 * Collections used:
 *   net_stock_cache  — 3 docs: 'Colour Bold', 'Fruit Bold', 'Rejection'
 *   orders           — pending order book
 *   cart_orders       — today's / recent dispatched orders
 *   packed_orders     — archived dispatched orders
 *
 * Dependencies:
 *   ../firebaseClient  -> getDb()
 *   ./stock_fb         -> getNetStockForUi()   (lazy-loaded, with inline fallback)
 *   ../utils/date      -> formatSheetDate, normalizeSheetDate, parseSheetDate
 */

const { getDb } = require('../../src/backend/database/sqliteClient');
const { formatSheetDate, normalizeSheetDate, parseSheetDate } = require('../utils/date');
const CFG = require('../config');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const NET_STOCK_CACHE_COL = 'net_stock_cache';
const ORDERS_COL = 'orders';
const CART_COL = 'cart_orders';
const PACKED_COL = 'packed_orders';

// ---------------------------------------------------------------------------
// Collection helpers
// ---------------------------------------------------------------------------

function netStockCacheCol() { return getDb().collection(NET_STOCK_CACHE_COL); }
function ordersCol()        { return getDb().collection(ORDERS_COL); }
function cartCol()          { return getDb().collection(CART_COL); }
function packedCol()        { return getDb().collection(PACKED_COL); }

// ---------------------------------------------------------------------------
// Lazy-load stock_fb (may not exist yet in early waves)
// ---------------------------------------------------------------------------

let _stockFb = null;
function _getStockFb() {
    if (!_stockFb) {
        try {
            _stockFb = require('./stock_fb');
        } catch (_e) {
            // stock_fb.js not yet created — provide an inline fallback
            _stockFb = null;
        }
    }
    return _stockFb;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function _formatDateISO(val) {
    if (!val) return '';
    const d = parseSheetDate(val);
    if (!d) return val;
    return d.toISOString().split('T')[0];
}

/**
 * Read all 3 net_stock_cache docs and return them keyed by type name.
 * Each value is the Firestore document data ({ netAbsolute, netVirtual }).
 */
async function _getNetStockCacheDocs() {
    const snap = await netStockCacheCol().get();
    const byType = {};
    snap.docs.forEach(doc => {
        byType[doc.id] = doc.data();
    });
    return byType;
}

/**
 * Sum positive values from an object of { gradeName: number }.
 */
function _sumPositive(obj) {
    if (!obj || typeof obj !== 'object') return 0;
    let total = 0;
    for (const val of Object.values(obj)) {
        const n = Number(val) || 0;
        if (n > 0) total += n;
    }
    return total;
}

// ---------------------------------------------------------------------------
// 1. getDashboardSnapshot
// ---------------------------------------------------------------------------

/**
 * Returns the hero-card data for the dashboard:
 *   - Net stock total (sum of positive values across all types)
 *   - Pending order metrics
 *   - Today's cart (dispatched today) metrics
 *   - Allocator hint (grade with most pending kgs)
 */
async function getDashboardSnapshot(prefetchedData) {
    // 1. Net stock total from net_stock_cache
    let netStockTotalKg = 0;
    let netStockNote = '';

    const cacheDocs = prefetchedData?.cacheDocs || await _getNetStockCacheDocs();
    for (const data of Object.values(cacheDocs)) {
        netStockTotalKg += _sumPositive(data.netAbsolute);
        netStockTotalKg += _sumPositive(data.netVirtual);
    }
    if (netStockTotalKg > 0) {
        netStockNote = 'sum of positive net stock cells (Firestore cache)';
    }

    // 2. Pending orders from orders collection
    let pendingDispatchQty = 0;
    let pendingOrderValue = 0;
    let pendingOrderCount = 0;
    const orderPreview = [];

    const ordSnap = prefetchedData?.ordSnap || await ordersCol().get();
    const pendingDocs = [];

    ordSnap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted === true) return;
        const status = String(d.status || '').toLowerCase();
        if (status !== 'pending') return;

        const kgs   = Number(d.kgs) || 0;
        const price = Number(d.price) || 0;

        pendingDispatchQty += kgs;
        pendingOrderValue += kgs * price;
        pendingOrderCount++;

        pendingDocs.push({ doc, data: d });
    });

    // Preview: latest 5 pending (by createdAt descending, fallback to array order)
    pendingDocs
        .sort((a, b) => {
            const ta = a.data.createdAt || a.data.orderDate || '';
            const tb = b.data.createdAt || b.data.orderDate || '';
            return String(tb).localeCompare(String(ta));
        })
        .slice(0, 5)
        .forEach(({ data: d }) => {
            orderPreview.push({
                date: _formatDateISO(d.orderDate),
                client: d.client || '',
                billing: d.billingFrom || '',
                kgs: Number(d.kgs) || 0,
            });
        });

    // 3. Today cart from cart_orders
    let todayPackedCount = 0;
    let todayPackedFirst = null;
    let dispatchedTodayQty = 0;

    const todayStr = formatSheetDate(); // dd/mm/yy

    const cartSnap = prefetchedData?.cartSnap || await cartCol().get();
    cartSnap.docs.forEach(doc => {
        const d = doc.data();
        const packedDate = d.packedDate || '';
        const normalized = normalizeSheetDate(packedDate);

        if (normalized !== todayStr) return;

        todayPackedCount++;
        const kgs = Number(d.kgs) || 0;
        dispatchedTodayQty += kgs;

        if (!todayPackedFirst) {
            todayPackedFirst = {
                client: d.client || '',
                grade: d.grade || '',
                kgs,
            };
        }
    });

    // 4. Allocator Hint (grade with most pending kgs)
    let allocatorHint = {};
    const gradeKgsMap = {};

    ordSnap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted === true) return;
        if (String(d.status || '').toLowerCase() !== 'pending') return;
        const g = String(d.grade || '').trim();
        const k = Number(d.kgs) || 0;
        if (g) gradeKgsMap[g] = (gradeKgsMap[g] || 0) + k;
    });

    let bestGrade = '';
    let bestQty = 0;
    for (const [g, qty] of Object.entries(gradeKgsMap)) {
        if (qty > bestQty) {
            bestQty = qty;
            bestGrade = g;
        }
    }
    if (bestGrade) {
        allocatorHint = { grade: bestGrade, qty: bestQty };
    }

    return {
        netStockTotalKg,
        netStockNote,
        pendingDispatchQty,
        dispatchedTodayQty,
        pendingOrderValue,
        pendingOrderCount,
        orderPreview,
        todayPackedCount,
        todayPackedFirst,
        allocatorHint,
    };
}

// ---------------------------------------------------------------------------
// 2. getClientLeaderboardForDashboard
// ---------------------------------------------------------------------------

/**
 * Top 10 clients ranked by pending value then dispatch value (last 30 days).
 */
async function getClientLeaderboardForDashboard(prefetchedData) {
    // 1. Pending value from orders
    const pendingMap = {};
    const ordSnap = prefetchedData?.ordSnap || await ordersCol().get();

    ordSnap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted === true) return;
        if (String(d.status || '').toLowerCase() !== 'pending') return;

        const client = String(d.client || '').trim();
        if (!client) return;

        const val = (Number(d.kgs) || 0) * (Number(d.price) || 0);
        pendingMap[client] = (pendingMap[client] || 0) + val;
    });

    // 2. Dispatched value (last 30 days) from cart_orders
    const dispatchMap30 = {};
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 30);

    const cartSnap = prefetchedData?.cartSnap || await cartCol().get();

    cartSnap.docs.forEach(doc => {
        const d = doc.data();
        const packedDate = parseSheetDate(d.packedDate || d.createdAt || '');
        if (!packedDate || packedDate < cutoff) return;

        const client = String(d.client || '').trim();
        if (!client) return;

        const val = (Number(d.kgs) || 0) * (Number(d.price) || 0);
        dispatchMap30[client] = (dispatchMap30[client] || 0) + val;
    });

    // Merge
    const allClients = new Set([...Object.keys(pendingMap), ...Object.keys(dispatchMap30)]);
    const rows = Array.from(allClients).map(client => ({
        client,
        pendingValue: pendingMap[client] || 0,
        dispatchedValue: dispatchMap30[client] || 0,
    }));

    rows.sort((a, b) => {
        if (b.pendingValue !== a.pendingValue) return b.pendingValue - a.pendingValue;
        return b.dispatchedValue - a.dispatchedValue;
    });

    return rows.slice(0, 10);
}

// ---------------------------------------------------------------------------
// 3. getDispatchHistoryForDashboard
// ---------------------------------------------------------------------------

/**
 * Dispatch history grouped by date (last 30 days) from cart_orders.
 */
async function getDispatchHistoryForDashboard(prefetchedData) {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 30);
    const byDate = {};

    const cartSnap = prefetchedData?.cartSnap || await cartCol().get();

    cartSnap.docs.forEach(doc => {
        const d = doc.data();
        const parsedDate = parseSheetDate(d.packedDate || d.createdAt || '');
        if (!parsedDate || parsedDate < cutoff) return;

        const isoDate = parsedDate.toISOString().split('T')[0];
        byDate[isoDate] = (byDate[isoDate] || 0) + (Number(d.kgs) || 0);
    });

    return Object.keys(byDate).sort().map(date => ({
        date,
        kg: byDate[date],
    }));
}

// ---------------------------------------------------------------------------
// 4. getStockHealthForDashboard
// ---------------------------------------------------------------------------

/**
 * Stock health summary (mock — same as current Sheets version).
 */
async function getStockHealthForDashboard() {
    return {
        totalNetKg: 0,
        criticalCount: 0,
        highSurplusCount: 0,
    };
}

// ---------------------------------------------------------------------------
// 5. getNetStockPayload
// ---------------------------------------------------------------------------

/**
 * Returns net stock in { headers, rows } format for the dashboard table.
 *
 * Uses stock_fb.getNetStockForUi() if available; otherwise reads directly
 * from net_stock_cache.
 */
async function getNetStockPayload(prefetchedData) {
    const stockFb = _getStockFb();
    if (!prefetchedData?.cacheDocs && stockFb && typeof stockFb.getNetStockForUi === 'function') {
        const { headers, rows } = await stockFb.getNetStockForUi();
        return {
            headers: ['Type', ...headers],
            rows: rows.map(r => [r.type, ...r.values]),
        };
    }

    // Inline fallback: read from net_stock_cache
    const allGrades = [...CFG.absGrades, ...CFG.virtualGrades];
    const headers = ['Type', ...allGrades];
    const outRows = [];

    const cacheDocs = prefetchedData?.cacheDocs || await _getNetStockCacheDocs();

    for (const typeName of CFG.types) {
        const data = cacheDocs[typeName];
        const row = [typeName];

        for (const grade of allGrades) {
            const absVal = (data && data.netAbsolute && Number(data.netAbsolute[grade])) || 0;
            const virVal = (data && data.netVirtual && Number(data.netVirtual[grade])) || 0;
            row.push(absVal + virVal);
        }
        outRows.push(row);
    }

    return { headers, rows: outRows };
}

// ---------------------------------------------------------------------------
// 6. getHighPositiveStock
// ---------------------------------------------------------------------------

/**
 * Returns stock items with positive net stock (> 1 kg) and their last dispatch
 * date from cart_orders.
 */
async function getHighPositiveStock(prefetchedData) {
    const SURPLUS_THRESHOLD = 1;
    const highItems = [];

    const cacheDocs = prefetchedData?.cacheDocs || await _getNetStockCacheDocs();

    for (const typeName of CFG.types) {
        const data = cacheDocs[typeName];
        if (!data) continue;

        const processObj = (obj) => {
            if (!obj || typeof obj !== 'object') return;
            for (const [gradeName, rawVal] of Object.entries(obj)) {
                const n = Number(rawVal) || 0;
                if (n > SURPLUS_THRESHOLD) {
                    // Check if we already have this grade for this type
                    const existing = highItems.find(
                        it => it.type === typeName && it.grade === gradeName
                    );
                    if (existing) {
                        existing.netKg += n;
                    } else {
                        highItems.push({ type: typeName, grade: gradeName, netKg: n });
                    }
                }
            }
        };

        processObj(data.netAbsolute);
        processObj(data.netVirtual);
    }

    if (!highItems.length) return [];

    // Last dispatch date per grade from cart_orders
    const lastDispatchByGrade = {};
    const cartSnapHP = prefetchedData?.cartSnap || await cartCol().get();

    cartSnapHP.docs.forEach(doc => {
        const d = doc.data();
        const grade = String(d.grade || '').trim();
        if (!grade) return;

        const parsedDate = parseSheetDate(d.packedDate || d.createdAt || '');
        if (parsedDate && (!lastDispatchByGrade[grade] || parsedDate > lastDispatchByGrade[grade])) {
            lastDispatchByGrade[grade] = parsedDate;
        }
    });

    const today = new Date();
    const MS_PER_DAY = 1000 * 60 * 60 * 24;

    const result = highItems.map(it => {
        const lastDate = lastDispatchByGrade[it.grade];
        let daysSince = null;
        let note = 'No dispatch record found';

        if (lastDate) {
            daysSince = Math.floor((today - lastDate) / MS_PER_DAY);
            if (daysSince > 30) note = 'No dispatch in 30+ days';
            else if (daysSince > 7) note = 'Slow moving (7+ days)';
            else note = 'Recently moving';
        }

        return {
            type: it.type,
            grade: it.grade,
            netKg: it.netKg,
            daysSinceDispatch: daysSince,
            note,
        };
    });

    return result.sort((a, b) => b.netKg - a.netKg);
}

// ---------------------------------------------------------------------------
// 7. getStockTypeGradePayload
// ---------------------------------------------------------------------------

/**
 * Flat type x grade breakdown from net_stock_cache.
 * Returns { headers: ['Type', 'Grade', 'Net Stock (kg)'], rows: [[...], ...] }
 */
async function getStockTypeGradePayload(prefetchedData) {
    const outRows = [];
    const cacheDocs = prefetchedData?.cacheDocs || await _getNetStockCacheDocs();

    for (const typeName of CFG.types) {
        const data = cacheDocs[typeName];
        if (!data) continue;

        const gradeSet = new Set();
        const gradeVals = {};

        // Merge netAbsolute and netVirtual
        const mergeObj = (obj) => {
            if (!obj || typeof obj !== 'object') return;
            for (const [gradeName, rawVal] of Object.entries(obj)) {
                gradeSet.add(gradeName);
                gradeVals[gradeName] = (gradeVals[gradeName] || 0) + (Number(rawVal) || 0);
            }
        };

        mergeObj(data.netAbsolute);
        mergeObj(data.netVirtual);

        for (const gradeName of gradeSet) {
            outRows.push([typeName, gradeName, gradeVals[gradeName] || 0]);
        }
    }

    return {
        headers: ['Type', 'Grade', 'Net Stock (kg)'],
        rows: outRows,
    };
}

// ---------------------------------------------------------------------------
// 8. getDashboardPayload
// ---------------------------------------------------------------------------

/**
 * Aggregates all dashboard sub-payloads with a 5-second timeout.
 * This is the main endpoint consumed by the Flutter app.
 */
async function getDashboardPayload() {
    const timeoutPromise = new Promise((_, reject) => {
        setTimeout(() => reject(new Error('Dashboard fetch timed out')), 5000);
    });

    try {
        // Prefetch all collections ONCE (3 reads instead of 11)
        const [cacheDocs, ordSnap, cartSnap] = await Promise.all([
            _getNetStockCacheDocs(),
            ordersCol().get(),
            cartCol().get(),
        ]);
        const prefetchedData = { cacheDocs, ordSnap, cartSnap };

        const fetchPromise = Promise.all([
            getDashboardSnapshot(prefetchedData),
            getNetStockPayload(prefetchedData),
            getHighPositiveStock(prefetchedData),
            getClientLeaderboardForDashboard(prefetchedData),
            getDispatchHistoryForDashboard(prefetchedData),
            getStockTypeGradePayload(prefetchedData),
        ]);

        const [
            snapshot,
            netStock,
            highPositive,
            clientLeaderboard,
            dispatchHistory,
            stockTypeGrade,
        ] = await Promise.race([fetchPromise, timeoutPromise]);

        // Flatten and map for Flutter App
        return {
            // Hero Cards
            totalStock: snapshot.netStockTotalKg || 0,
            pendingQty: snapshot.pendingDispatchQty || 0,
            todayPackedKgs: snapshot.dispatchedTodayQty || 0,
            todayPackedCount: snapshot.todayPackedCount || 0,

            // Sales Snapshot
            todaySalesKgs: snapshot.dispatchedTodayQty || 0,
            todaySalesVal: (snapshot.todaySalesValue || 0).toFixed(2), // Use actual sales value from orders
            todaySalesLots: snapshot.todayPackedCount || 0,
            summaryDispatchedToday: snapshot.dispatchedTodayQty || 0,
            pendingValue: snapshot.pendingOrderValue || 0,
            allocatorHint: snapshot.allocatorHint || {},
            todayPackedFirst: snapshot.todayPackedFirst,

            // Legacy / Extra Data
            stockHealth: {
                totalNetKg: snapshot.netStockTotalKg,
                criticalCount: 0,
                highSurplusCount: 0,
            },
            netStock,
            highPositive,
            clientLeaderboard,
            dispatchHistory,
            stockTypeGrade,
        };
    } catch (err) {
        console.error('[Dashboard-FB] Error or Timeout:', err.message);
        // Safe fallback so the UI does not hang
        return {
            totalStock: 0,
            pendingQty: 0,
            todayPackedKgs: 0,
            todayPackedCount: 0,
            todaySalesKgs: 0,
            todaySalesVal: '0.00',
            todaySalesLots: 0,
            summaryDispatchedToday: 0,
            pendingValue: 0,
            stockHealth: { totalNetKg: 0, criticalCount: 0, highSurplusCount: 0 },
            netStock: { headers: [], rows: [] },
            highPositive: [],
            clientLeaderboard: [],
            dispatchHistory: [],
            stockTypeGrade: { headers: [], rows: [] },
            error: err.message,
        };
    }
}

// ---------------------------------------------------------------------------
// 9. getStockTotals — flat { grade: totalKgs } map across all types
// ---------------------------------------------------------------------------

/**
 * Returns a flat object mapping each grade name to its total net stock (kg)
 * summed across all types (Colour Bold + Fruit Bold + Rejection).
 * Used by pricing_intelligence.js to iterate grades.
 */
async function getStockTotals() {
    const totals = {};
    const cacheDocs = await _getNetStockCacheDocs();
    for (const data of Object.values(cacheDocs)) {
        for (const [grade, kgs] of Object.entries(data.netAbsolute || {})) {
            totals[grade] = (totals[grade] || 0) + (Number(kgs) || 0);
        }
        for (const [grade, kgs] of Object.entries(data.netVirtual || {})) {
            totals[grade] = (totals[grade] || 0) + (Number(kgs) || 0);
        }
    }
    return totals;
}

// ---------------------------------------------------------------------------
// Exports (same surface as ../dashboard.js)
// ---------------------------------------------------------------------------

module.exports = {
    getDashboardSnapshot,
    getClientLeaderboardForDashboard,
    getDispatchHistoryForDashboard,
    getStockHealthForDashboard,
    getNetStockPayload,
    getHighPositiveStock,
    getStockTypeGradePayload,
    getDashboardPayload,
    getStockTotals,
};
