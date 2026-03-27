/**
 * Order Book Module — Firebase Firestore Backend
 * Drop-in replacement for ../orderBook.js
 * 
 * Collections: orders (pending), cart_orders (today), packed_orders (archived)
 * 
 * Key improvements:
 *   - No row-index bugs (document IDs, not row numbers)
 *   - Atomic batch operations (no partial failures)
 *   - No date-format ambiguity (ISO strings)
 *   - No column-name mismatches (Bag / Box vs Bag/Box)
 */

const { getDb, createBatch, runTransaction } = require('../../src/backend/database/sqliteClient');
const { formatSheetDate, normalizeSheetDate, toDate } = require('../utils/date');

// Lazy-load stock_fb for sale order aggregation (replaces mergeGlue)
let _stockFbForMerge = null;
function getMergeGlue() {
    // stock_fb.aggregateSaleOrders replaces mergeGlue entirely
    if (!_stockFbForMerge) _stockFbForMerge = require('./stock_fb');
    return _stockFbForMerge;
}

// Lazy-load stockCalc → now always stock_fb
let _stockCalc = null;
function getStockCalc() {
    if (!_stockCalc) _stockCalc = require('./stock_fb');
    return _stockCalc;
}

// Lazy-load stock_fb (Firestore stock engine)
let _stockFb = null;
function getStockFb() {
    if (!_stockFb) _stockFb = require('./stock_fb');
    return _stockFb;
}

// Lazy-load integrityCheck
let _integrityCheck = null;
function getIntegrityCheck() {
    if (!_integrityCheck) _integrityCheck = require('../integrityCheck');
    return _integrityCheck;
}

// Feature-flag-gated stock recalculation triggers with debounce
// Prevents 100 orders → 100 recalcs. Batches within 2s window into single recalc.
let _stockRecalcTimer = null;
let _stockRecalcResolvers = [];

async function triggerStockRecalc() {
    _invalidateOrdersCache(); // Clear shared cache on any write operation
    return new Promise((resolve, reject) => {
        _stockRecalcResolvers.push({ resolve, reject });
        if (_stockRecalcTimer) clearTimeout(_stockRecalcTimer);
        _stockRecalcTimer = setTimeout(async () => {
            const resolvers = [..._stockRecalcResolvers];
            _stockRecalcResolvers = [];
            _stockRecalcTimer = null;
            try {
                const flags = require('../featureFlags');
                if (flags.useFirestore('saleAggregation')) {
                    await getStockFb().calculateNetStock();
                } else {
                    await getMergeGlue().rebuildSaleOrderFromOrderBook();
                }
                resolvers.forEach(r => r.resolve());
            } catch (err) {
                resolvers.forEach(r => r.reject(err));
            }
        }, 2000); // 2s debounce window
    });
}

function triggerStockRecalcBackground() {
    // Fire-and-forget with same debounce
    triggerStockRecalc().catch(err => {
        console.error('[orderBook-FB] Background stock recalc error:', err.message);
    });
}

const ORDERS_COL = 'orders';
const CART_COL = 'cart_orders';
const PACKED_COL = 'packed_orders';

function ordersCol() { return getDb().collection(ORDERS_COL); }
function cartCol() { return getDb().collection(CART_COL); }
function packedCol() { return getDb().collection(PACKED_COL); }

/** Check if a doc is active (not soft-deleted). Use to filter reads. */
function isActiveDoc(doc) {
    return doc.exists && doc.data().isDeleted !== true;
}

/** Filter snapshot docs to only active (non-deleted) docs */
function activeDocs(snap) {
    return snap.docs.filter(doc => doc.data().isDeleted !== true);
}

function _formatDate(val) {
    if (!val) return '';
    const { formatSheetDate, toDate } = require('../utils/date');
    const d = toDate(val);
    if (!d) return val;
    return formatSheetDate(d);
}

/** Convert Firestore doc to order object */
function docToOrder(doc) {
    const d = doc.data();
    return {
        id: doc.id,  // Firestore doc ID (replaces row index)
        orderDate: d.orderDate || '',
        billingFrom: d.billingFrom || '',
        client: d.client || '',
        lot: d.lot || '',
        grade: d.grade || '',
        bagbox: d.bagbox || '',
        no: Number(d.no) || 0,
        kgs: Number(d.kgs) || 0,
        price: Number(d.price) || 0,
        brand: d.brand || '',
        status: d.status || 'Pending',
        notes: d.notes || '',
        packedDate: d.packedDate || '',
        index: doc.id  // Use doc ID as index (replaces row number)
    };
}

// ============================================================================
// LOT NUMBERS
// ============================================================================

/**
 * Get the next lot number for a client (read-only, non-transactional).
 * Used for display/preview purposes. For actual lot assignment, use
 * getNextLotNumberTransactional() to prevent duplicates under concurrency.
 */
async function getNextLotNumber(client) {
    if (!client) return { nextLot: 'L1', nextLotNumber: 1 };

    // Search across all 3 collections for this client's max lot
    const [ordSnap, cartSnap, packSnap] = await Promise.all([
        ordersCol().where('client', '==', client).get(),
        cartCol().where('client', '==', client).get(),
        packedCol().where('client', '==', client).get()
    ]);

    let maxLot = 0;
    const checkLot = (docs) => {
        docs.forEach(doc => {
            const lot = doc.data().lot;
            if (lot) {
                const match = /^L(\d+)$/i.exec(String(lot).trim());
                if (match) maxLot = Math.max(maxLot, parseInt(match[1], 10));
            }
        });
    };
    checkLot(ordSnap.docs);
    checkLot(cartSnap.docs);
    checkLot(packSnap.docs);

    const nextLotNumber = maxLot + 1;
    return { nextLot: `L${nextLotNumber}`, nextLotNumber };
}

/**
 * Transactional lot number generation using a counter document.
 *
 * TRANSACTION RATIONALE: Without a transaction, two concurrent addOrder() calls
 * for the same client could both read the same max lot number and generate
 * duplicate lot numbers (e.g., both get L5). This uses a counter document
 * at lot_counters/{client} as a serialization point. The transaction reads
 * the current counter, increments it, and writes back atomically.
 * Firestore retries on contention (up to 5 times), ensuring uniqueness.
 *
 * On first use for a client, initializes the counter from existing orders
 * across all 3 collections (orders, cart_orders, packed_orders).
 *
 * @param {string} client - Client name
 * @returns {Promise<{nextLot: string, nextLotNumber: number}>}
 */
async function getNextLotNumberTransactional(client) {
    if (!client) return { nextLot: 'L1', nextLotNumber: 1 };

    const db = getDb();
    const counterRef = db.collection('lot_counters').doc(client);

    const result = await db.runTransaction(async (transaction) => {
        const counterDoc = await transaction.get(counterRef);

        let currentMax;
        if (counterDoc.exists) {
            currentMax = counterDoc.data().lastLotNumber || 0;
        } else {
            // First time: scan existing orders to initialize the counter.
            // This scan is outside the transaction's read set for the 3 order
            // collections, but it only runs once per client. Subsequent calls
            // use the counter document directly.
            const [ordSnap, cartSnap, packSnap] = await Promise.all([
                ordersCol().where('client', '==', client).get(),
                cartCol().where('client', '==', client).get(),
                packedCol().where('client', '==', client).get()
            ]);

            currentMax = 0;
            const checkLot = (docs) => {
                docs.forEach(doc => {
                    const lot = doc.data().lot;
                    if (lot) {
                        const match = /^L(\d+)$/i.exec(String(lot).trim());
                        if (match) currentMax = Math.max(currentMax, parseInt(match[1], 10));
                    }
                });
            };
            checkLot(ordSnap.docs);
            checkLot(cartSnap.docs);
            checkLot(packSnap.docs);
        }

        const nextLotNumber = currentMax + 1;
        transaction.set(counterRef, {
            client,
            lastLotNumber: nextLotNumber,
            updatedAt: new Date().toISOString()
        });

        return { nextLot: `L${nextLotNumber}`, nextLotNumber };
    });

    return result;
}

async function assignLotNumbers() {
    // In Firestore, lot numbers are assigned at creation time. No-op needed.
}

// ============================================================================
// ADD ORDERS
// ============================================================================

/**
 * Add a single order to the orders collection.
 *
 * If lot is not provided, uses transactional lot number generation to
 * prevent duplicate lot numbers under concurrent access.
 */
async function addOrder(order, skipRebuild = false) {
    // Server-side validation — reject invalid orders
    if (!order.client || !String(order.client).trim()) {
        return { success: false, error: 'Client is required' };
    }
    if (!order.grade || !String(order.grade).trim()) {
        return { success: false, error: 'Grade is required' };
    }
    if (!Number(order.kgs) || Number(order.kgs) <= 0) {
        return { success: false, error: 'Kgs must be greater than 0' };
    }
    if (!Number(order.price) || Number(order.price) <= 0) {
        return { success: false, error: 'Price must be greater than 0' };
    }

    // Auto-assign lot if missing — use transactional generation to prevent duplicates
    let lotNumber = order.lot || '';
    if (!lotNumber && order.client) {
        const { nextLot } = await getNextLotNumberTransactional(order.client);
        lotNumber = nextLot;
    }

    const docRef = ordersCol().doc();  // Auto-generate ID
    await docRef.set({
        orderDate: order.orderDate || '',
        billingFrom: order.billingFrom || '',
        client: order.client || '',
        lot: lotNumber,
        grade: order.grade || '',
        bagbox: order.bagbox || '',
        no: Number(order.no) || 0,
        kgs: Number(order.kgs) || 0,
        price: Number(order.price) || 0,
        brand: order.brand || '',
        status: 'Pending',
        notes: order.notes || '',
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        isDeleted: false
    });

    if (!skipRebuild) {
        await triggerStockRecalc();
    }

    return { success: true, message: 'Order added successfully' };
}

/**
 * Add multiple orders in a batch. Uses transactional lot number generation
 * for any orders missing a lot number to prevent duplicates.
 */
async function addOrders(orders) {
    if (!orders || !orders.length) return { success: true };

    // Server-side validation — reject batch if any order is invalid
    for (let i = 0; i < orders.length; i++) {
        const o = orders[i];
        if (!o.client || !String(o.client).trim()) {
            return { success: false, error: `Order ${i + 1}: Client is required` };
        }
        if (!o.grade || !String(o.grade).trim()) {
            return { success: false, error: `Order ${i + 1}: Grade is required` };
        }
        if (!Number(o.kgs) || Number(o.kgs) <= 0) {
            return { success: false, error: `Order ${i + 1}: Kgs must be greater than 0` };
        }
        if (!Number(o.price) || Number(o.price) <= 0) {
            return { success: false, error: `Order ${i + 1}: Price must be greater than 0` };
        }
    }

    // ── Idempotency check: skip orders that were already created (replay protection) ──
    let skipped = 0;
    const idempotencyKeys = orders
        .map(o => o.idempotencyKey)
        .filter(Boolean);

    const existingKeys = new Set();
    if (idempotencyKeys.length > 0) {
        // Firestore `in` queries are limited to 30 values — chunk if needed
        const chunks = [];
        for (let i = 0; i < idempotencyKeys.length; i += 30) {
            chunks.push(idempotencyKeys.slice(i, i + 30));
        }
        for (const chunk of chunks) {
            const snap = await ordersCol()
                .where('idempotencyKey', 'in', chunk)
                .select('idempotencyKey')
                .get();
            snap.docs.forEach(doc => {
                const k = doc.data().idempotencyKey;
                if (k) existingKeys.add(k);
            });
        }
    }

    // Filter out already-created orders
    const newOrders = orders.filter(o => {
        if (o.idempotencyKey && existingKeys.has(o.idempotencyKey)) {
            skipped++;
            return false;
        }
        return true;
    });

    if (newOrders.length === 0) {
        return { success: true, message: 'All orders already exist (idempotent replay)', skipped };
    }

    // Pre-assign lot numbers for orders that need them (transactional, per-client)
    for (const order of newOrders) {
        if (!order.lot && order.client) {
            const { nextLot } = await getNextLotNumberTransactional(order.client);
            order.lot = nextLot;
        }
    }

    // Chunk into batches of 450 to stay under Firestore's 500-operation limit
    const BATCH_LIMIT = 450;
    for (let i = 0; i < newOrders.length; i += BATCH_LIMIT) {
        const chunk = newOrders.slice(i, i + BATCH_LIMIT);
        const batch = createBatch();
        for (const order of chunk) {
            const docRef = ordersCol().doc();
            batch.set(docRef, {
                orderDate: order.orderDate || '',
                billingFrom: order.billingFrom || '',
                client: order.client || '',
                lot: order.lot || '',
                grade: order.grade || '',
                bagbox: order.bagbox || '',
                no: Number(order.no) || 0,
                kgs: Number(order.kgs) || 0,
                price: Number(order.price) || 0,
                brand: order.brand || '',
                status: 'Pending',
                notes: order.notes || '',
                createdBy: order.createdBy || '',
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString(),
                isDeleted: false,
                ...(order.idempotencyKey ? { idempotencyKey: order.idempotencyKey } : {}),
            });
        }
        await batch.commit();
    }

    await triggerStockRecalc();
    return { success: true, message: `${newOrders.length} orders added${skipped ? `, ${skipped} skipped (duplicate)` : ''}`, skipped };
}

// ============================================================================
// GET ORDERS — with shared 30s in-memory cache to avoid redundant collection scans
// ============================================================================

let _ordersCacheData = null;
let _ordersCacheTime = 0;
const ORDERS_CACHE_TTL = 30 * 1000; // 30 seconds

async function _fetchAllCollections() {
    const now = Date.now();
    if (_ordersCacheData && (now - _ordersCacheTime) < ORDERS_CACHE_TTL) {
        return _ordersCacheData;
    }
    const [ordSnap, cartSnap, packSnap] = await Promise.all([
        ordersCol().get(),
        cartCol().get(),
        packedCol().get(),
    ]);
    _ordersCacheData = { ordSnap, cartSnap, packSnap };
    _ordersCacheTime = now;
    return _ordersCacheData;
}

// Invalidate shared cache on writes (called from add/update/delete functions)
function _invalidateOrdersCache() {
    _ordersCacheData = null;
    _ordersCacheTime = 0;
}

async function getSortedOrders() {
    const grouped = {};
    const { ordSnap, cartSnap, packSnap } = await _fetchAllCollections();

    // 1. Pending orders
    activeDocs(ordSnap).forEach(doc => {
        const o = docToOrder(doc);
        if (!o.client) return;
        const dateKey = _formatDate(o.orderDate);
        if (!grouped[dateKey]) grouped[dateKey] = {};
        if (!grouped[dateKey][o.client]) grouped[dateKey][o.client] = [];
        const row = [o.orderDate, o.billingFrom, o.client, o.lot, o.grade, o.bagbox, o.no, o.kgs, o.price, o.brand, o.status, o.notes, `-${doc.id}`];
        grouped[dateKey][o.client].push(row);
    });

    // 2. Cart orders (On Progress) — from shared cache
    activeDocs(cartSnap).forEach(doc => {
        const o = docToOrder(doc);
        if (!o.client) return;
        const dateKey = _formatDate(o.orderDate);
        if (!grouped[dateKey]) grouped[dateKey] = {};
        if (!grouped[dateKey][o.client]) grouped[dateKey][o.client] = [];
        const row = [o.orderDate, o.billingFrom, o.client, o.lot, o.grade, o.bagbox, o.no, o.kgs, o.price, o.brand, o.status || 'On Progress', o.notes, doc.id];
        row.index = doc.id;
        grouped[dateKey][o.client].push(row);
    });

    // 3. Packed orders (Done/Billed) — from shared cache
    activeDocs(packSnap).forEach(doc => {
        const o = docToOrder(doc);
        if (!o.client) return;
        const dateKey = _formatDate(o.orderDate);
        if (!grouped[dateKey]) grouped[dateKey] = {};
        if (!grouped[dateKey][o.client]) grouped[dateKey][o.client] = [];
        const row = [o.orderDate, o.billingFrom, o.client, o.lot, o.grade, o.bagbox, o.no, o.kgs, o.price, o.brand, 'Billed', o.notes, doc.id, o.packedDate || ''];
        grouped[dateKey][o.client].push(row);
    });

    return grouped;
}

// ============================================================================
// GET FILTERED ORDERS — server-side filtering (mirrors getSalesSummary pattern)
// ============================================================================

/**
 * Get orders filtered server-side by status, client, billing, and grade.
 * Only queries the Firestore collection(s) matching the requested status,
 * then applies remaining filters on doc fields before grouping.
 *
 * @param {object} filters
 * @param {string} [filters.status]  - 'pending' | 'on progress' | 'billed'
 * @param {string} [filters.client]  - exact client name (case-insensitive)
 * @param {string} [filters.billing] - 'SYGT' | 'ESPL'
 * @param {string} [filters.grade]   - grade value
 * @returns {Promise<object>} { date: { client: [[row], ...] } }
 */
async function getFilteredOrders(filters = {}) {
    const grouped = {};
    const clientSet = new Set();   // All clients in queried collections (for dropdown)
    const statusRaw = (filters.status || '').toLowerCase().trim();
    const statusLower = statusRaw === 'all' ? '' : statusRaw;
    const clientLower = (filters.client || '').toLowerCase().trim();
    const billingLower = (filters.billing || '').toLowerCase();
    const gradeLower = (filters.grade || '').toLowerCase();

    const addRow = (doc, forcedStatus, includePackedDate) => {
        const o = docToOrder(doc);
        if (!o.client) return;
        // Collect ALL client names (before client-filter) so dropdown stays full
        clientSet.add(o.client.trim());
        // Apply filters on doc fields
        if (clientLower && o.client.toLowerCase().trim() !== clientLower) return;
        if (billingLower && (o.billingFrom || '').toLowerCase() !== billingLower) return;
        if (gradeLower && (o.grade || '').toLowerCase() !== gradeLower) return;

        const dateKey = _formatDate(o.orderDate);
        if (!grouped[dateKey]) grouped[dateKey] = {};
        if (!grouped[dateKey][o.client]) grouped[dateKey][o.client] = [];

        const status = forcedStatus || o.status;
        const row = [o.orderDate, o.billingFrom, o.client, o.lot, o.grade,
                     o.bagbox, o.no, o.kgs, o.price, o.brand, status,
                     o.notes, doc.id];
        if (includePackedDate) row.push(o.packedDate || '');
        grouped[dateKey][o.client].push(row);
    };

    // Use shared collection cache (avoids redundant Firestore reads)
    const { ordSnap, cartSnap, packSnap } = await _fetchAllCollections();

    if (!statusLower || statusLower === 'pending')
        activeDocs(ordSnap).forEach(doc => addRow(doc, null, false));
    if (!statusLower || statusLower === 'on progress')
        activeDocs(cartSnap).forEach(doc => addRow(doc, 'On Progress', false));
    if (!statusLower || statusLower === 'billed')
        activeDocs(packSnap).forEach(doc => addRow(doc, 'Billed', true));
    return { orders: grouped, clients: [...clientSet].sort((a, b) => a.localeCompare(b)) };
}

/**
 * Get paginated orders from both orders and cart_orders collections.
 * Returns a flat list with pagination envelope, grouped by date/client
 * on the returned page only (same shape as getSortedOrders but paginated).
 *
 * @param {object} params
 * @param {number} params.limit - Page size (default 25, max 100)
 * @param {string|null} params.cursor - Firestore doc ID to start after
 * @param {string} params.sortBy - Sort field (default 'orderDate')
 * @param {string} params.sortDir - Sort direction (default 'desc')
 * @returns {Promise<{ data: object, pagination: { cursor, hasMore, limit } }>}
 */
async function getPaginatedOrders({ limit = 25, cursor = null, sortBy = 'orderDate', sortDir = 'desc' } = {}) {
    limit = Math.max(1, Math.min(limit, 100));

    // Per-collection cursors to fix cross-collection pagination
    // cursor format: "ordCursor|cartCursor|packCursor" (base64-encoded JSON or pipe-separated IDs)
    let ordCursor = null, cartCursor = null, packCursor = null;
    if (cursor) {
        try {
            const parsed = JSON.parse(Buffer.from(cursor, 'base64').toString());
            ordCursor = parsed.ord || null;
            cartCursor = parsed.cart || null;
            packCursor = parsed.pack || null;
        } catch (e) {
            // Legacy single cursor — try in all collections
            ordCursor = cartCursor = packCursor = cursor;
        }
    }

    async function buildQuery(col, cursorId) {
        let q = col.orderBy(sortBy, sortDir).limit(limit + 1);
        if (cursorId) {
            try {
                const cursorDoc = await col.doc(cursorId).get();
                if (cursorDoc.exists) {
                    q = col.orderBy(sortBy, sortDir).startAfter(cursorDoc).limit(limit + 1);
                }
            } catch (e) { /* ignore */ }
        }
        return q;
    }

    const [ordSnap, cartSnap, packSnap] = await Promise.all([
        (await buildQuery(ordersCol(), ordCursor)).get(),
        (await buildQuery(cartCol(), cartCursor)).get(),
        (await buildQuery(packedCol(), packCursor)).get(),
    ]);

    // Merge and sort all docs, take limit (filter out soft-deleted)
    const allDocs = [];
    activeDocs(ordSnap).forEach(doc => {
        allDocs.push({ doc, source: 'orders' });
    });
    activeDocs(cartSnap).forEach(doc => {
        allDocs.push({ doc, source: 'cart' });
    });
    activeDocs(packSnap).forEach(doc => {
        allDocs.push({ doc, source: 'packed' });
    });

    // Sort merged docs
    allDocs.sort((a, b) => {
        const aVal = a.doc.data()[sortBy] || '';
        const bVal = b.doc.data()[sortBy] || '';
        if (sortDir === 'desc') return bVal > aVal ? 1 : bVal < aVal ? -1 : 0;
        return aVal > bVal ? 1 : aVal < bVal ? -1 : 0;
    });

    const pageDocs = allDocs.slice(0, limit);
    const hasMore = allDocs.length > limit;

    // Group by date/client (same structure as getSortedOrders)
    const grouped = {};
    pageDocs.forEach(({ doc, source }) => {
        const o = docToOrder(doc);
        if (!o.client) return;
        const dateKey = _formatDate(o.orderDate);
        if (!grouped[dateKey]) grouped[dateKey] = {};
        if (!grouped[dateKey][o.client]) grouped[dateKey][o.client] = [];

        if (source === 'orders') {
            const row = [o.orderDate, o.billingFrom, o.client, o.lot, o.grade, o.bagbox, o.no, o.kgs, o.price, o.brand, o.status, o.notes, `-${doc.id}`];
            grouped[dateKey][o.client].push(row);
        } else if (source === 'cart') {
            const row = [o.orderDate, o.billingFrom, o.client, o.lot, o.grade, o.bagbox, o.no, o.kgs, o.price, o.brand, o.status || 'On Progress', o.notes, doc.id];
            row.index = doc.id;
            grouped[dateKey][o.client].push(row);
        } else {
            // packed orders (Billed)
            const row = [o.orderDate, o.billingFrom, o.client, o.lot, o.grade, o.bagbox, o.no, o.kgs, o.price, o.brand, 'Billed', o.notes, doc.id];
            grouped[dateKey][o.client].push(row);
        }
    });

    // Build per-collection cursors from last doc of each source in pageDocs
    const lastBySource = {};
    pageDocs.forEach(({ doc, source }) => { lastBySource[source] = doc.id; });
    const nextCursor = hasMore ? Buffer.from(JSON.stringify({
        ord: lastBySource.orders || ordCursor,
        cart: lastBySource.cart || cartCursor,
        pack: lastBySource.packed || packCursor,
    })).toString('base64') : null;

    return {
        data: grouped,
        pagination: {
            cursor: nextCursor,
            hasMore,
            limit
        }
    };
}

async function getDropdownOptions() {
    const dropdownFb = require('./dropdown_fb');
    return dropdownFb.getDropdownOptions();
}

async function updateOrder(docId, updatedData, skipRebuild = false) {
    // docId is now a Firestore document ID (not a row index)
    // Use allowlist pattern (same as updatePackedOrder) to prevent data corruption
    const updateFields = { updatedAt: new Date().toISOString() };
    const allowedFields = ['orderDate', 'billingFrom', 'client', 'lot', 'grade', 'bagbox', 'no', 'kgs', 'price', 'brand', 'status', 'notes'];
    for (const field of allowedFields) {
        if (updatedData[field] !== undefined) {
            updateFields[field] = (field === 'no' || field === 'kgs' || field === 'price')
                ? Number(updatedData[field])
                : updatedData[field];
        }
    }
    // Add updatedBy if provided
    if (updatedData.updatedBy) {
        updateFields.updatedBy = updatedData.updatedBy;
    }
    // Check all 3 collections — order may be in orders, cart_orders, or packed_orders
    const id = String(docId);
    let existingData = null;
    let targetCol = null;

    const ordDoc = await ordersCol().doc(id).get();
    if (ordDoc.exists) {
        existingData = ordDoc.data();
        targetCol = ordersCol();
    } else {
        const cartDoc = await cartCol().doc(id).get();
        if (cartDoc.exists) {
            existingData = cartDoc.data();
            targetCol = cartCol();
        } else {
            const packDoc = await packedCol().doc(id).get();
            if (packDoc.exists) {
                existingData = packDoc.data();
                targetCol = packedCol();
            } else {
                throw new Error(`Order ${id} not found in any collection`);
            }
        }
    }

    // Track edit history — compare old vs new values for allowed fields
    const changes = [];
    for (const field of allowedFields) {
        if (updateFields[field] !== undefined) {
            const oldValue = existingData[field] !== undefined ? existingData[field] : null;
            const newValue = updateFields[field];
            if (String(oldValue) !== String(newValue)) {
                changes.push({ field, oldValue, newValue });
            }
        }
    }
    if (changes.length > 0) {
        const historyEntry = {
            orderId: id,
            changes,
            editedBy: updatedData.updatedBy || 'Unknown',
            editedAt: new Date().toISOString(),
        };
        await getDb().collection('order_edit_history').add(historyEntry);
    }

    await targetCol.doc(id).update(updateFields);
    if (!skipRebuild) await triggerStockRecalc();
    return { success: true };
}

/**
 * Update a billed (packed) order — supports changing packedDate and/or status.
 * If status changes, the order is moved to the appropriate collection:
 *   Pending → orders, On Progress → cart_orders, Billed → stays in packed_orders
 */
async function updatePackedOrder(docId, updatedData) {
    const id = String(docId);
    const newStatus = updatedData.status;

    // If status is changing away from Billed, move to another collection
    if (newStatus && newStatus.toLowerCase() !== 'billed') {
        const docRef = packedCol().doc(id);
        const doc = await docRef.get();
        if (!doc.exists) throw new Error(`Packed order ${id} not found`);

        const data = doc.data();
        // Merge any updated fields, remove billed-specific fields, set new status
        const movedData = { ...data, ...updatedData, status: newStatus, packedDate: '', updatedAt: new Date().toISOString() };
        // Ensure numeric fields are properly typed
        if (movedData.no !== undefined) movedData.no = Number(movedData.no);
        if (movedData.kgs !== undefined) movedData.kgs = Number(movedData.kgs);
        if (movedData.price !== undefined) movedData.price = Number(movedData.price);

        const targetCol = newStatus.toLowerCase() === 'pending' ? ordersCol() : cartCol();
        await targetCol.doc(id).set(movedData);
        await docRef.delete();
        await triggerStockRecalc();
        return { success: true, moved: true, newStatus };
    }

    // Update any provided fields on the existing packed order (superadmin full edit)
    const updateFields = { updatedAt: new Date().toISOString() };
    const allowedFields = ['orderDate', 'billingFrom', 'client', 'lot', 'grade', 'bagbox', 'no', 'kgs', 'price', 'brand', 'notes', 'packedDate'];
    for (const field of allowedFields) {
        if (updatedData[field] !== undefined) {
            updateFields[field] = (field === 'no' || field === 'kgs' || field === 'price')
                ? Number(updatedData[field])
                : updatedData[field];
        }
    }
    await packedCol().doc(id).update(updateFields);
    // Recalculate stock only when quantity-affecting fields change
    if (updatedData.no !== undefined || updatedData.kgs !== undefined || updatedData.grade !== undefined) {
        await triggerStockRecalc();
    }
    return { success: true };
}

/**
 * Delete a single order by document ID.
 *
 * No transaction needed: Firestore deletes are atomic single-document operations.
 * The subsequent stock recalculation (triggerStockRecalc -> calculateNetStock)
 * uses a transaction internally to prevent lost updates to net_stock_cache.
 */
async function deleteOrder(docId) {
    const id = String(docId);
    const now = new Date().toISOString();

    // Check all 3 collections to find where this order lives
    // Orders can be in: orders (Pending), cart_orders (On Progress), packed_orders (Billed)
    const [ordDoc, cartDoc, packDoc] = await Promise.all([
        ordersCol().doc(id).get(),
        cartCol().doc(id).get(),
        packedCol().doc(id).get(),
    ]);

    // Soft-delete: mark as deleted instead of removing the document.
    // This preserves the record for sync (clients can detect deletions via updatedAt).
    const softDeleteFields = { isDeleted: true, deletedAt: now, updatedAt: now };

    let deletedRow = null;
    if (ordDoc.exists) {
        deletedRow = ordDoc.data();
        await ordersCol().doc(id).update(softDeleteFields);
    } else if (cartDoc.exists) {
        deletedRow = cartDoc.data();
        await cartCol().doc(id).update(softDeleteFields);
    } else if (packDoc.exists) {
        deletedRow = packDoc.data();
        await packedCol().doc(id).update(softDeleteFields);
    } else {
        throw new Error(`Order ${id} not found in any collection`);
    }

    await triggerStockRecalc();
    return { success: true, deletedRow };
}

async function getPendingOrders() {
    // Use WHERE query to only fetch Pending orders (reduces Firestore reads)
    const snap = await ordersCol().where('status', '==', 'Pending').get();
    const today = new Date();
    const MS_PER_DAY = 1000 * 60 * 60 * 24;
    return activeDocs(snap).map(doc => {
        const order = docToOrder(doc);
        let daysSinceOrder = 0;
        const parsed = toDate(order.orderDate);
        if (parsed) {
            daysSinceOrder = Math.max(0, Math.floor((today - parsed) / MS_PER_DAY));
        }
        return { ...order, daysSinceOrder };
    });
}

async function getSalesSummary(filters = {}) {
    const summary = {};
    const clientSet = new Set();

    const processOrders = (docs) => {
        docs.filter(doc => doc.data().isDeleted !== true).forEach(doc => {
            const d = doc.data();
            const grade = d.grade, kgs = parseFloat(d.kgs) || 0, client = d.client || '';
            if (!grade || !kgs) return;
            if (client) clientSet.add(client.trim());
            if (filters.client && client.toLowerCase() !== filters.client.toLowerCase()) return;
            if (filters.billing && (d.billingFrom || '').toLowerCase() !== filters.billing.toLowerCase()) return;
            if (filters.date && _formatDate(d.orderDate) !== filters.date) return;
            // Support date range filtering (startDate/endDate in YYYY-MM-DD format)
            if (filters.startDate || filters.endDate) {
                const raw = d.orderDate || '';
                // Normalize dd/MM/yy to YYYY-MM-DD for comparison
                let isoDate = raw;
                const parts = raw.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/);
                if (parts) {
                    const yr = parts[3].length === 2 ? '20' + parts[3] : parts[3];
                    isoDate = `${yr}-${parts[2].padStart(2, '0')}-${parts[1].padStart(2, '0')}`;
                }
                if (filters.startDate && isoDate < filters.startDate) return;
                if (filters.endDate && isoDate > filters.endDate) return;
            }
            if (!summary[grade]) summary[grade] = { kgs: 0, count: 0 };
            summary[grade].kgs += kgs;
            summary[grade].count += 1;
        });
    };

    // Optimization: only query the collections matching the requested status filter
    const statusLower = (filters.status || '').toLowerCase();
    const queries = [];
    if (!statusLower || statusLower === 'pending')      queries.push(ordersCol().get());
    else queries.push(Promise.resolve({ docs: [] }));
    if (!statusLower || statusLower === 'on progress')   queries.push(cartCol().get());
    else queries.push(Promise.resolve({ docs: [] }));
    if (!statusLower || statusLower === 'billed')        queries.push(packedCol().get());
    else queries.push(Promise.resolve({ docs: [] }));

    const [ordSnap, cartSnap, packedSnap] = await Promise.all(queries);
    processOrders(ordSnap.docs);
    processOrders(cartSnap.docs);
    processOrders(packedSnap.docs);

    return { summary, clients: [...clientSet].sort((a, b) => a.localeCompare(b)) };
}

// ============================================================================
// GRADE DETAIL — Individual orders for a specific grade
// ============================================================================

async function getOrdersByGrade(grade, filters = {}) {
    const orders = [];
    const today = new Date();
    const MS_PER_DAY = 1000 * 60 * 60 * 24;

    const processOrders = (docs) => {
        docs.filter(doc => doc.data().isDeleted !== true).forEach(doc => {
            const d = doc.data();
            const docGrade = d.grade || '';
            const kgs = parseFloat(d.kgs) || 0;
            if (!docGrade || !kgs) return;
            if (docGrade.toLowerCase() !== grade.toLowerCase()) return;
            if (filters.client && (d.client || '').toLowerCase() !== filters.client.toLowerCase()) return;
            if (filters.billing && (d.billingFrom || '').toLowerCase() !== filters.billing.toLowerCase()) return;
            if (filters.date && _formatDate(d.orderDate) !== filters.date) return;

            const order = docToOrder(doc);
            let daysSinceOrder = 0;
            const parsed = toDate(order.orderDate);
            if (parsed) {
                daysSinceOrder = Math.max(0, Math.floor((today - parsed) / MS_PER_DAY));
            }
            orders.push({ ...order, daysSinceOrder });
        });
    };

    // Optimization: only query the collections matching the requested status filter
    const statusLower = (filters.status || '').toLowerCase();
    const queries = [];
    if (!statusLower || statusLower === 'pending')      queries.push(ordersCol().get());
    else queries.push(Promise.resolve({ docs: [] }));
    if (!statusLower || statusLower === 'on progress')   queries.push(cartCol().get());
    else queries.push(Promise.resolve({ docs: [] }));
    if (!statusLower || statusLower === 'billed')        queries.push(packedCol().get());
    else queries.push(Promise.resolve({ docs: [] }));

    const [ordSnap, cartSnap, packedSnap] = await Promise.all(queries);
    processOrders(ordSnap.docs);
    processOrders(cartSnap.docs);
    processOrders(packedSnap.docs);

    return orders;
}

// ============================================================================
// CART OPERATIONS
// ============================================================================

async function addToDailyCart(selectedOrders, cartDate, markBilled = false) {
    const today = formatSheetDate();
    const packedDate = cartDate ? normalizeSheetDate(cartDate) : today;
    const db = getDb();

    // If markBilled, write directly to packed_orders with 'Billed' status
    const targetCol = markBilled ? packedCol() : cartCol();
    const targetStatus = markBilled ? 'Billed' : 'On Progress';

    // Each order = 2 ops (1 set + 1 delete/update). Chunk at 225 orders to stay under 500-op limit.
    const CHUNK_SIZE = 225;
    for (let i = 0; i < selectedOrders.length; i += CHUNK_SIZE) {
        const chunk = selectedOrders.slice(i, i + CHUNK_SIZE);
        const batch = db.batch();

        for (const order of chunk) {
            // Preserve original doc ID for dispatch doc linkage and audit trail
            const docRef = order.index ? targetCol.doc(String(order.index)) : targetCol.doc();
            batch.set(docRef, {
                orderDate: order.orderDate, billingFrom: order.billingFrom || '',
                client: order.client, lot: order.lot, grade: order.grade,
                bagbox: order.bagbox, no: order.no, kgs: order.kgs,
                price: order.price, brand: order.brand,
                status: targetStatus, notes: order.notes || '', packedDate: packedDate,
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString(),
                isDeleted: false
            });

            // Soft-delete from orders (consistent with deleteOrder pattern)
            if (order.index) {
                const orderRef = ordersCol().doc(String(order.index));
                batch.update(orderRef, { isDeleted: true, deletedAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
            }
        }

        await batch.commit();
    }

    // Update packed_totals if going directly to Billed
    if (markBilled) {
        try {
            const stockFb = require('./stock_fb');
            await stockFb.incrementPackedTotals(selectedOrders);
        } catch (e) {
            console.warn('[addToDailyCart] incrementPackedTotals failed:', e.message);
        }
    }

    // Background stock recalc
    triggerStockRecalcBackground();

    return { success: true };
}

async function getTodayCart() {
    const today = formatSheetDate(); // IST-aware

    // Auto-archive old orders first
    await autoArchiveOldCartOrders();

    // Get today's orders
    const snap = await cartCol().get();
    const results = [];

    activeDocs(snap).forEach(doc => {
        const d = doc.data();
        const packedDate = d.packedDate;

        // Compare normalized dates (both use IST via formatSheetDate)
        const normalized = normalizeSheetDate(packedDate);
        if (normalized === today) {
            results.push(docToOrder(doc));
        }
    });

    return results;
}

async function autoArchiveOldCartOrders() {
    const today = formatSheetDate(); // IST-aware
    const snap = await cartCol().get();
    if (snap.empty) return;

    const toArchive = [];
    const toDelete = [];

    activeDocs(snap).forEach(doc => {
        const d = doc.data();
        const packedDate = d.packedDate;
        if (!packedDate) return;

        const normalized = normalizeSheetDate(packedDate);
        const isToday = normalized === today;

        if (!isToday) {
            toArchive.push({ ...d, status: 'Billed', packedDate: normalized, updatedAt: new Date().toISOString(), isDeleted: false });
            toDelete.push(doc.id);
        }
    });

    if (toArchive.length === 0) return;

    console.log(`[autoArchive-FB] Archiving ${toArchive.length} old cart orders`);

    // Batch: add to packed, delete from cart
    const db = getDb();
    // Firestore batch limit is 500, chunk if needed
    for (let i = 0; i < toArchive.length; i += 250) {
        const batch = db.batch();
        const chunk = toArchive.slice(i, i + 250);
        const deleteChunk = toDelete.slice(i, i + 250);

        chunk.forEach((order, idx) => {
            // Use the original cart doc ID to prevent duplicates if archive runs twice
            const originalId = deleteChunk[idx];
            batch.set(packedCol().doc(originalId), order);
        });
        const archiveNow = new Date().toISOString();
        deleteChunk.forEach(id => {
            // Soft-delete from cart (consistent with sync protocol)
            batch.update(cartCol().doc(id), { isDeleted: true, deletedAt: archiveNow, updatedAt: archiveNow });
        });

        await batch.commit();
    }

    // Update packed sale order
    try {
        const flags = require('../featureFlags');
        if (flags.useFirestore('saleAggregation')) {
            await getStockFb().incrementPackedTotals(toArchive);
            await getStockFb().calculateNetStock();
        } else {
            const headers = ['Order Date', 'Billing From', 'Client', 'Lot', 'Grade', 'Bag / Box', 'No', 'Kgs', 'Price', 'Brand', 'Status', 'Notes', 'Packed Date'];
            const rows = toArchive.map(o => [o.orderDate, o.billingFrom, o.client, o.lot, o.grade, o.bagbox, o.no, o.kgs, o.price, o.brand, o.status, o.notes, o.packedDate]);
            await getStockCalc().updatePackedSaleOrder(rows, headers);
        }
    } catch (err) {
        console.error('[autoArchive-FB] Error updating packed sale:', err.message);
    }

    console.log(`[autoArchive-FB] Archived ${toArchive.length} orders to packed_orders`);
}

async function removeFromPackedOrders(lot, client, billingFrom, docId) {
    let snap;
    // If docId is provided, target the specific document directly
    if (docId) {
        const docRef = cartCol().doc(String(docId));
        const docSnap = await docRef.get();
        if (!docSnap.exists) return { success: false, message: 'Order not found in cart' };
        snap = { empty: false, docs: [docSnap] };
    } else {
        // Fallback to lot+client query
        snap = await cartCol()
            .where('lot', '==', lot)
            .where('client', '==', client)
            .get();
    }

    if (snap.empty) return { success: false, message: 'Order not found in cart' };

    const itemsToRestore = [];
    const batch = createBatch();

    snap.docs.forEach(doc => {
        const d = doc.data();
        if (!docId && billingFrom !== undefined && d.billingFrom !== billingFrom) return;
        itemsToRestore.push({
            orderDate: d.orderDate, billingFrom: d.billingFrom, client: d.client,
            lot: d.lot, grade: d.grade, bagbox: d.bagbox, no: d.no, kgs: d.kgs,
            price: d.price, brand: d.brand, notes: d.notes
        });
        // Soft-delete from cart (consistent with sync protocol)
        const now = new Date().toISOString();
        batch.update(doc.ref, { isDeleted: true, deletedAt: now, updatedAt: now });
    });

    if (itemsToRestore.length === 0) return { success: false, message: 'No matching orders' };

    await batch.commit();
    await addOrders(itemsToRestore.map(i => ({ ...i, status: 'Pending' })));

    return { success: true, restoredCount: itemsToRestore.length };
}

async function batchRemoveFromPackedOrders(items) {
    if (!items || items.length === 0) return { success: true, message: 'No items to remove' };

    const db = getDb();
    const batch = db.batch();
    const itemsToRestore = [];

    for (const item of items) {
        if (!item.index) continue;
        const doc = await cartCol().doc(String(item.index)).get();
        if (!doc.exists) continue;
        const d = doc.data();
        if (d.lot !== item.lot || d.client !== item.client) continue;

        itemsToRestore.push({
            orderDate: d.orderDate, billingFrom: d.billingFrom, client: d.client,
            lot: d.lot, grade: d.grade, bagbox: d.bagbox, no: d.no, kgs: d.kgs,
            price: d.price, brand: d.brand, notes: d.notes
        });
        // Soft-delete from cart (consistent with sync protocol)
        const now = new Date().toISOString();
        batch.update(doc.ref, { isDeleted: true, deletedAt: now, updatedAt: now });
    }

    if (itemsToRestore.length === 0) return { success: false, message: 'No valid matches' };

    await batch.commit();
    await addOrders(itemsToRestore.map(i => ({ ...i, status: 'Pending' })));

    return { success: true, message: `Cancelled ${itemsToRestore.length} items`, cancelledCount: itemsToRestore.length };
}

// ============================================================================
// PARTIAL DISPATCH
// ============================================================================

async function partialDispatch(order, dispatchQty) {
    const originalKgs = parseFloat(order.kgs);
    const dispatchKgs = parseFloat(dispatchQty);
    const originalNo = parseFloat(order.no) || 0;

    if (isNaN(dispatchKgs) || dispatchKgs <= 0 || dispatchKgs >= originalKgs) {
        throw new Error('Invalid dispatch quantity.');
    }

    const multiplier = (() => {
        const val = order.bagbox;
        if (!val) return null;
        const n = String(val).toLowerCase().trim();
        if (n.includes('bag')) return 50;
        if (n.includes('box')) return 20;
        return null;
    })();

    const remainingKgs = originalKgs - dispatchKgs;
    const dispatchedNo = multiplier ? Math.round(dispatchKgs / multiplier) : Math.round((originalNo * dispatchKgs) / originalKgs);
    const remainingNo = multiplier ? Math.max(0, Math.round(remainingKgs / multiplier)) : Math.max(0, originalNo - dispatchedNo);

    if (!order.index) throw new Error('Order index (doc ID) missing.');

    // Get a new lot number for the remainder
    const { nextLot } = await getNextLotNumberTransactional(order.client);

    const today = formatSheetDate();
    const db = getDb();
    const batch = db.batch();

    // 1. Soft-delete original from orders (consistent with sync protocol)
    const now = new Date().toISOString();
    const originalDocId = String(order.index);
    const partialGroupId = `PD-${originalDocId}-${Date.now()}`;
    batch.update(ordersCol().doc(originalDocId), {
        isDeleted: true, deletedAt: now, updatedAt: now
    });

    // 2. Add dispatched portion to cart (preserves original doc ID for tracking)
    batch.set(cartCol().doc(originalDocId), {
        orderDate: order.orderDate, billingFrom: order.billingFrom || '', client: order.client,
        lot: order.lot, grade: order.grade, bagbox: order.bagbox,
        no: dispatchedNo, kgs: dispatchKgs, price: order.price, brand: order.brand,
        status: 'On Progress', notes: order.notes || '', packedDate: today,
        originalLot: order.lot, partialDispatchGroupId: partialGroupId,
        createdAt: now, updatedAt: now, isDeleted: false
    });

    // 3. Add remainder back to orders with NEW lot number (linked via groupId)
    batch.set(ordersCol().doc(), {
        orderDate: order.orderDate, billingFrom: order.billingFrom, client: order.client,
        lot: nextLot, grade: order.grade, bagbox: order.bagbox,
        no: remainingNo, kgs: remainingKgs, price: order.price, brand: order.brand,
        status: 'Pending', notes: order.notes || '',
        originalLot: order.lot, partialDispatchGroupId: partialGroupId,
        createdAt: now, updatedAt: now, isDeleted: false
    });

    await batch.commit();

    triggerStockRecalcBackground();

    return { success: true };
}

async function cancelPartialDispatch({ lot, client }) {
    // Find cart items for this lot/client
    const cartSnap = await cartCol().where('lot', '==', lot).where('client', '==', client).get();

    if (cartSnap.empty) return { success: false, message: 'No matching orders found in cart' };

    // Aggregate values
    let totalKgs = 0, totalNo = 0;
    let orderDate = '', billingFrom = '', grade = '', bagbox = '', brand = '', notes = '';
    // Weighted average price: accumulate (price * kgs) for each doc
    let priceWeightedSum = 0, priceWeightedKgs = 0;

    const prefer = (current, candidate) => {
        if (String(current || '').trim()) return current;
        if (String(candidate || '').trim()) return candidate;
        return '';
    };

    const accumulateDoc = (d) => {
        const kgs = parseFloat(d.kgs) || 0;
        const no = parseFloat(d.no) || 0;
        totalKgs += kgs;
        totalNo += no;
        orderDate = prefer(orderDate, d.orderDate);
        billingFrom = prefer(billingFrom, d.billingFrom);
        grade = prefer(grade, d.grade);
        bagbox = prefer(bagbox, d.bagbox);
        brand = prefer(brand, d.brand);
        notes = prefer(notes, d.notes);
        const p = parseFloat(d.price);
        if (!isNaN(p) && kgs > 0) {
            priceWeightedSum += p * kgs;
            priceWeightedKgs += kgs;
        }
    };

    const db = getDb();
    const batch = db.batch();

    // Collect groupId from cart items for precise remainder matching
    const groupIds = new Set();
    const softDeleteNow = new Date().toISOString();
    cartSnap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted) return; // Skip already soft-deleted
        accumulateDoc(d);
        // Soft-delete from cart (consistent with sync protocol)
        batch.update(doc.ref, { isDeleted: true, deletedAt: softDeleteNow, updatedAt: softDeleteNow });
        if (d.partialDispatchGroupId) groupIds.add(d.partialDispatchGroupId);
        if (d.originalLot) groupIds.add(d.originalLot);
    });

    // Find remainder in orders — use partialDispatchGroupId for precise matching
    const ordSnap = await ordersCol().where('client', '==', client).get();
    ordSnap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted) return;
        if (String(d.status || '').toLowerCase() !== 'pending') return;
        // Match by groupId (precise) or by originalLot/lot (fallback for legacy orders)
        const matchByGroup = d.partialDispatchGroupId && groupIds.has(d.partialDispatchGroupId);
        const matchByLot = d.originalLot === lot || d.lot === lot;
        if (matchByGroup || matchByLot) {
            accumulateDoc(d);
            batch.update(doc.ref, { isDeleted: true, deletedAt: softDeleteNow, updatedAt: softDeleteNow });
        }
    });

    // Compute weighted average price
    const price = priceWeightedKgs > 0
        ? String(Math.round(priceWeightedSum / priceWeightedKgs * 100) / 100)
        : '';

    // Create merged order
    const multiplier = (() => {
        if (!bagbox) return null;
        const n = String(bagbox).toLowerCase();
        if (n.includes('bag')) return 50;
        if (n.includes('box')) return 20;
        return null;
    })();
    const mergedNo = totalNo || (multiplier && totalKgs ? Math.round(totalKgs / multiplier) : 0);

    batch.set(ordersCol().doc(), {
        orderDate, billingFrom, client, lot, grade, bagbox: bagbox || '',
        no: mergedNo, kgs: totalKgs, price, brand, status: 'Pending', notes,
        createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), isDeleted: false
    });

    await batch.commit();
    await triggerStockRecalc();

    return { success: true };
}

// ============================================================================
// ARCHIVE
// ============================================================================

async function archiveCartToPackedOrders(targetDate = null) {
    const dateToArchive = targetDate || formatSheetDate((() => { const d = new Date(); d.setDate(d.getDate() - 1); return d; })());

    const snap = await cartCol().get();
    if (snap.empty) return { success: true, message: 'No orders to archive', archived: 0 };

    const toArchive = [];
    const toDelete = [];

    snap.docs.forEach(doc => {
        const d = doc.data();
        const normalized = normalizeSheetDate(d.packedDate);
        if (normalized === dateToArchive) {
            toArchive.push({ ...d, status: 'Billed', packedDate: normalized, updatedAt: new Date().toISOString(), isDeleted: false });
            toDelete.push(doc.id);
        }
    });

    if (toArchive.length === 0) return { success: true, message: `No orders for ${dateToArchive}`, archived: 0 };

    const db = getDb();
    for (let i = 0; i < toArchive.length; i += 250) {
        const batch = db.batch();
        const archiveChunk = toArchive.slice(i, i + 250);
        const deleteChunk = toDelete.slice(i, i + 250);
        // Use original cart doc ID as packed doc ID to prevent duplicates on re-run
        archiveChunk.forEach((order, idx) => batch.set(packedCol().doc(deleteChunk[idx]), order));
        const archiveNow = new Date().toISOString();
        deleteChunk.forEach(id => batch.update(cartCol().doc(id), { isDeleted: true, deletedAt: archiveNow, updatedAt: archiveNow }));
        await batch.commit();
    }

    // Update packed_totals materialized view (same as autoArchiveOldCartOrders)
    try {
        const stockFb = require('./stock_fb');
        await stockFb.incrementPackedTotals(toArchive);
    } catch (e) {
        console.warn('[archiveCart] incrementPackedTotals failed (non-fatal):', e.message);
    }

    triggerStockRecalcBackground();

    return { success: true, message: `Archived ${toArchive.length} order(s)`, archived: toArchive.length };
}

// ============================================================================
// CLIENT ORDERS
// ============================================================================

async function getClientOrders(clientName) {
    if (!clientName) return { pending: [], completed: [] };

    const [ordSnap, cartSnap] = await Promise.all([
        ordersCol().where('client', '==', clientName).get(),
        cartCol().where('client', '==', clientName).get()
    ]);

    const pending = activeDocs(ordSnap).map(docToOrder).filter(o => o.status.toLowerCase() === 'pending');
    const completed = activeDocs(cartSnap).map(docToOrder);

    return { pending, completed };
}

// ============================================================================
// LEDGER — Client summary for ledger view
// ============================================================================

async function getLedgerClients() {
    const clientMap = {};

    const processDoc = (doc) => {
        const d = doc.data();
        const client = (d.client || '').trim();
        if (!client) return;

        if (!clientMap[client]) {
            clientMap[client] = { client, totalOrders: 0, pendingOrders: 0, pendingKgs: 0, lastOrderDate: null };
        }
        const entry = clientMap[client];
        entry.totalOrders++;

        const st = (d.status || '').toLowerCase();
        if (st === 'pending' || st === '') {
            entry.pendingOrders++;
            entry.pendingKgs += Number(d.kgs) || 0;
        }

        const parsed = toDate(d.orderDate);
        if (parsed && (!entry.lastOrderDate || parsed > entry.lastOrderDate)) {
            entry.lastOrderDate = parsed;
        }
    };

    const [ordSnap, cartSnap, packSnap] = await Promise.all([
        ordersCol().get(),
        cartCol().get(),
        packedCol().get(),
    ]);

    activeDocs(ordSnap).forEach(processDoc);
    activeDocs(cartSnap).forEach(processDoc);
    activeDocs(packSnap).forEach(processDoc);

    const results = Object.values(clientMap).map(entry => ({
        client: entry.client,
        totalOrders: entry.totalOrders,
        pendingOrders: entry.pendingOrders,
        pendingKgs: entry.pendingKgs,
        lastOrderDate: entry.lastOrderDate ? _formatDate(entry.lastOrderDate) : '',
    }));

    results.sort((a, b) => a.client.localeCompare(b.client));
    return results;
}

// ============================================================================
// DROPDOWN MANAGEMENT — delegates to dropdown_fb.js (Firestore)
// ============================================================================

async function searchDropdownOptions(category, query) {
    const dropdownFb = require('./dropdown_fb');
    return dropdownFb.searchDropdownItems(category, query);
}

async function addDropdownOption(category, value) {
    const dropdownFb = require('./dropdown_fb');
    return dropdownFb.addDropdownItem(category, value);
}

async function deleteDropdownOption(category, value) {
    const dropdownFb = require('./dropdown_fb');
    return dropdownFb.deleteDropdownItem(category, value);
}

// ============================================================================
// UN-ARCHIVE WITH DUAL ADMIN APPROVAL
// ============================================================================

async function requestUnarchive(orderId, adminUsername) {
    const db = getDb();

    // Verify order exists in packed_orders
    const packedRef = db.collection('packed_orders').doc(orderId);
    const packedDoc = await packedRef.get();
    if (!packedDoc.exists) {
        throw new Error('Order not found in packed orders');
    }

    // Check for existing pending unarchive request
    const existing = await db.collection('unarchive_requests')
        .where('orderId', '==', orderId)
        .where('status', '==', 'pending')
        .get();
    if (!existing.empty) {
        throw new Error('An unarchive request already exists for this order');
    }

    // Create unarchive request
    const requestRef = db.collection('unarchive_requests').doc();
    await requestRef.set({
        id: requestRef.id,
        orderId,
        orderData: packedDoc.data(),
        requestedBy: adminUsername,
        status: 'pending',
        createdAt: new Date().toISOString(),
        approvedBy: null,
        approvedAt: null
    });

    return { success: true, requestId: requestRef.id };
}

async function approveUnarchive(requestId, secondAdminUsername) {
    const db = getDb();

    return await runTransaction(async (t) => {
        const requestRef = db.collection('unarchive_requests').doc(requestId);
        const requestDoc = await t.get(requestRef);

        if (!requestDoc.exists) throw new Error('Unarchive request not found');
        const request = requestDoc.data();

        if (request.status !== 'pending') throw new Error('Request is not pending');
        if (request.requestedBy === secondAdminUsername) {
            throw new Error('A different admin must approve the unarchive request');
        }

        // Move order from packed_orders back to orders
        const packedRef = db.collection('packed_orders').doc(request.orderId);
        const packedDoc = await t.get(packedRef);

        if (!packedDoc.exists) throw new Error('Packed order no longer exists');

        const orderData = packedDoc.data();
        const ordersRef = db.collection('orders').doc(request.orderId);

        // Restore to orders with Pending status
        t.set(ordersRef, {
            ...orderData,
            status: 'Pending',
            unarchivedAt: new Date().toISOString(),
            unarchivedBy: secondAdminUsername,
            unarchivedFrom: 'packed_orders',
            updatedAt: new Date().toISOString(),
            isDeleted: false
        });

        // Delete from packed_orders
        t.delete(packedRef);

        // Update request status
        t.update(requestRef, {
            status: 'approved',
            approvedBy: secondAdminUsername,
            approvedAt: new Date().toISOString()
        });

        return { success: true, orderId: request.orderId };
    });
}

async function rejectUnarchive(requestId, adminUsername, reason) {
    const requestRef = getDb().collection('unarchive_requests').doc(requestId);
    const doc = await requestRef.get();
    if (!doc.exists) throw new Error('Request not found');
    if (doc.data().status !== 'pending') throw new Error('Request not pending');

    await requestRef.update({
        status: 'rejected',
        rejectedBy: adminUsername,
        rejectedAt: new Date().toISOString(),
        rejectionReason: reason || ''
    });
    return { success: true };
}

async function getPendingUnarchiveRequests() {
    const snapshot = await getDb().collection('unarchive_requests')
        .where('status', '==', 'pending')
        .orderBy('createdAt', 'desc')
        .get();
    return snapshot.docs.map(doc => doc.data());
}

// ============================================================================
// DUPLICATE ORDER DETECTION
// ============================================================================

async function checkDuplicateOrder(orderData) {
    const { client, grade, kgs, price } = orderData;
    if (!client || !grade) return { hasDuplicates: false, matches: [] };

    const db = getDb();
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    const cutoffDate = thirtyDaysAgo.toISOString();

    // Search across all three collections
    const collections = ['orders', 'cart_orders', 'packed_orders'];
    const matches = [];

    for (const collName of collections) {
        const snapshot = await db.collection(collName)
            .where('client', '==', client)
            .where('grade', '==', grade)
            .get();

        snapshot.forEach(doc => {
            const data = doc.data();
            const createdAt = data.createdAt || data.orderDate || '';
            if (createdAt < cutoffDate) return; // Skip old orders

            // Check quantity similarity (within 10% tolerance)
            const orderKgs = parseFloat(data.kgs) || 0;
            const inputKgs = parseFloat(kgs) || 0;
            if (inputKgs > 0 && orderKgs > 0) {
                const ratio = Math.abs(orderKgs - inputKgs) / inputKgs;
                if (ratio <= 0.10) {
                    matches.push({
                        orderId: doc.id,
                        collection: collName,
                        client: data.client,
                        grade: data.grade,
                        kgs: data.kgs,
                        price: data.price,
                        status: data.status,
                        createdAt: createdAt,
                        similarity: `${Math.round((1 - ratio) * 100)}%`
                    });
                }
            }
        });
    }

    return {
        hasDuplicates: matches.length > 0,
        matches,
        warning: matches.length > 0
            ? `Found ${matches.length} similar order(s) for ${client} - ${grade} in the last 30 days`
            : null
    };
}

// ============================================================================
// STOCK DRIFT DETECTION & ANALYSIS
// ============================================================================

async function detectStockDrift() {
    const db = getDb();
    const drifts = [];

    // Get current net stock cache (read all type-specific documents)
    const cacheSnap = await db.collection('net_stock_cache').get();
    const cachedStock = {};
    cacheSnap.forEach(doc => {
        cachedStock[doc.id] = doc.data().netAbsolute || {};
    });

    // Recalculate expected stock from source data
    // Get live stock entries
    const liveStockSnap = await db.collection('live_stock_entries').get();
    let totalPurchased = {};
    liveStockSnap.forEach(doc => {
        const data = doc.data();
        // Aggregate by type/grade
        ['boldQty', 'floatQty', 'mediumQty'].forEach(field => {
            if (data[field]) {
                const key = field.replace('Qty', '');
                totalPurchased[key] = (totalPurchased[key] || 0) + parseFloat(data[field] || 0);
            }
        });
    });

    // Get adjustments
    const adjSnap = await db.collection('stock_adjustments').get();
    let totalAdjustments = {};
    adjSnap.forEach(doc => {
        const data = doc.data();
        const key = `${data.type}|${data.grade}`;
        totalAdjustments[key] = (totalAdjustments[key] || 0) + parseFloat(data.deltaKgs || 0);
    });

    // Get all sale orders (orders + cart + packed)
    let totalSold = {};
    for (const coll of ['orders', 'cart_orders', 'packed_orders']) {
        const snap = await db.collection(coll).get();
        snap.forEach(doc => {
            const data = doc.data();
            const gradeText = String(data.grade || '').toLowerCase();
            let type = 'Unknown';
            if (gradeText.includes('colour') || gradeText.includes('color')) type = 'Colour Bold';
            else if (gradeText.includes('fruit')) type = 'Fruit Bold';
            else if (gradeText.includes('rejection') || gradeText.includes('split') || gradeText.includes('sick')) type = 'Rejection';
            const key = `${type}|${data.grade || 'Unknown'}`;
            totalSold[key] = (totalSold[key] || 0) + parseFloat(data.kgs || 0);
        });
    }

    // Compare cached vs calculated
    // For each type/grade in cache, check if it matches expectations
    if (cachedStock && typeof cachedStock === 'object') {
        Object.entries(cachedStock).forEach(([type, grades]) => {
            if (typeof grades === 'object') {
                Object.entries(grades).forEach(([grade, cachedQty]) => {
                    const key = `${type}|${grade}`;
                    const sold = totalSold[key] || 0;
                    const adjusted = totalAdjustments[key] || 0;

                    // Simple drift check: if cached differs from (purchased + adjusted - sold) by more than 5%
                    const expectedApprox = adjusted - sold; // simplified
                    const diff = Math.abs(cachedQty - expectedApprox);
                    const threshold = Math.abs(cachedQty) * 0.05;

                    if (diff > threshold && diff > 10) { // minimum 10kg drift to flag
                        const possibleReasons = [];
                        if (sold > 0 && !cachedStock[type]) possibleReasons.push('Unrecorded sales detected');
                        if (diff > cachedQty * 0.2) possibleReasons.push('Possible data entry error');
                        if (adjusted !== 0) possibleReasons.push('Manual adjustments may have caused drift');
                        possibleReasons.push('Weight measurement variance during packing');
                        if (grade.includes('to') || grade.includes('-')) possibleReasons.push('Grade reclassification between similar grades');

                        drifts.push({
                            type,
                            grade,
                            cachedQty,
                            calculatedQty: expectedApprox,
                            drift: diff,
                            driftPercent: cachedQty ? `${((diff / Math.abs(cachedQty)) * 100).toFixed(1)}%` : 'N/A',
                            possibleReasons,
                            severity: diff > cachedQty * 0.1 ? 'high' : 'medium'
                        });
                    }
                });
            }
        });
    }

    return {
        timestamp: new Date().toISOString(),
        totalDrifts: drifts.length,
        drifts: drifts.sort((a, b) => b.drift - a.drift),
        summary: drifts.length > 0
            ? `Found ${drifts.length} stock drift(s). ${drifts.filter(d => d.severity === 'high').length} high severity.`
            : 'No significant stock drifts detected.'
    };
}

// ============================================================================
// DATA INTEGRITY CHECKS
// ============================================================================

async function checkUserDataIntegrity() {
    const db = getDb();
    const warnings = [];

    const usersSnap = await db.collection('users').get();
    const users = [];
    const usernames = new Set();

    usersSnap.forEach(doc => {
        const data = { id: doc.id, ...doc.data() };
        users.push(data);

        // Check duplicate usernames
        if (usernames.has(data.username)) {
            warnings.push({
                type: 'duplicate_username',
                severity: 'high',
                message: `Duplicate username found: "${data.username}"`,
                affectedIds: [doc.id]
            });
        }
        usernames.add(data.username);

        // Check missing role
        if (!data.role || !['admin', 'superadmin', 'ops', 'employee', 'user', 'client'].includes(data.role)) {
            warnings.push({
                type: 'missing_role',
                severity: 'high',
                message: `User "${data.username}" has invalid or missing role: "${data.role}"`,
                affectedIds: [doc.id]
            });
        }

        // Check missing pageAccess
        if (!data.pageAccess || typeof data.pageAccess !== 'object') {
            warnings.push({
                type: 'missing_page_access',
                severity: 'medium',
                message: `User "${data.username}" has no pageAccess configuration`,
                affectedIds: [doc.id]
            });
        }

        // Check client role without clientId
        if (data.role === 'client' && !data.clientId) {
            warnings.push({
                type: 'orphaned_client_user',
                severity: 'medium',
                message: `Client user "${data.username}" has no linked clientId`,
                affectedIds: [doc.id]
            });
        }
    });

    // Check for orphaned references
    const clientsSnap = await db.collection('clients').get();
    const clientIds = new Set();
    clientsSnap.forEach(doc => clientIds.add(doc.id));

    users.filter(u => u.role === 'client' && u.clientId).forEach(user => {
        if (!clientIds.has(user.clientId)) {
            warnings.push({
                type: 'orphaned_reference',
                severity: 'high',
                message: `User "${user.username}" references non-existent client "${user.clientId}"`,
                affectedIds: [user.id]
            });
        }
    });

    return {
        timestamp: new Date().toISOString(),
        totalWarnings: warnings.length,
        warnings: warnings.sort((a, b) => {
            const severityOrder = { high: 0, medium: 1, low: 2 };
            return (severityOrder[a.severity] || 2) - (severityOrder[b.severity] || 2);
        }),
        summary: warnings.length > 0
            ? `Found ${warnings.length} data integrity issue(s). ${warnings.filter(w => w.severity === 'high').length} high severity.`
            : 'All data integrity checks passed.'
    };
}

// ============================================================================
// ============================================================================
// DEDUPLICATION: Find and remove duplicate packed (billed) orders
// ============================================================================

/**
 * Scans packed_orders for exact duplicates based on:
 * client + grade + lot + kgs + price + orderDate + billingFrom
 * Returns duplicates found. If dryRun=false, deletes the duplicates (keeps first).
 */
async function deduplicatePackedOrders(dryRun = true) {
    const snap = await packedCol().get();
    if (snap.empty) return { duplicatesFound: 0, removed: 0, details: [] };

    const seen = new Map(); // key -> first doc id
    const duplicates = [];  // { docId, data }

    snap.docs.forEach(doc => {
        const d = doc.data();
        // Build a fingerprint from the core fields that identify a unique order
        const key = [
            (d.client || '').trim().toLowerCase(),
            (d.grade || '').trim().toLowerCase(),
            (d.lot || '').trim().toLowerCase(),
            String(Number(d.kgs) || 0),
            String(Number(d.price) || 0),
            (d.orderDate || '').trim(),
            (d.billingFrom || '').trim().toLowerCase(),
        ].join('|');

        if (seen.has(key)) {
            duplicates.push({
                docId: doc.id,
                keepDocId: seen.get(key),
                client: d.client,
                grade: d.grade,
                lot: d.lot,
                kgs: d.kgs,
                price: d.price,
                orderDate: d.orderDate,
            });
        } else {
            seen.set(key, doc.id);
        }
    });

    let removed = 0;
    if (!dryRun && duplicates.length > 0) {
        // Batch delete duplicates (keep the first occurrence)
        const db = getDb();
        for (let i = 0; i < duplicates.length; i += 250) {
            const batch = db.batch();
            const chunk = duplicates.slice(i, i + 250);
            chunk.forEach(dup => {
                batch.delete(packedCol().doc(dup.docId));
            });
            await batch.commit();
            removed += chunk.length;
        }
        await triggerStockRecalc();
    }

    return {
        duplicatesFound: duplicates.length,
        removed,
        dryRun,
        details: duplicates,
    };
}

// EXPORTS (same surface as ../orderBook.js)
// ============================================================================

module.exports = {
    assignLotNumbers, addOrder, addOrders, getSortedOrders, getFilteredOrders, getPaginatedOrders, getDropdownOptions,
    searchDropdownOptions, addDropdownOption, deleteDropdownOption,
    updateOrder, updatePackedOrder, getSalesSummary, getOrdersByGrade, getPendingOrders, addToDailyCart, getTodayCart,
    removeFromPackedOrders, batchRemoveFromPackedOrders, deleteOrder,
    partialDispatch, cancelPartialDispatch, getNextLotNumber, getNextLotNumberTransactional,
    archiveCartToPackedOrders, getClientOrders, getLedgerClients,
    // Un-archive with dual admin approval
    requestUnarchive, approveUnarchive, rejectUnarchive, getPendingUnarchiveRequests,
    // Duplicate order detection
    checkDuplicateOrder,
    // Deduplication
    deduplicatePackedOrders,
    // Stock drift detection
    detectStockDrift,
    // Data integrity checks
    checkUserDataIntegrity,
    // Integrity checks (delegate to existing module for now)
    validateNoOrderOverlap: (...args) => getIntegrityCheck().validateNoOrderOverlap(...args),
    getIntegrityReport: (...args) => getIntegrityCheck().getIntegrityReport(...args),
    validateSaleOrderIntegrity: (...args) => getIntegrityCheck().validateSaleOrderIntegrity(...args),
    storeChecksums: (...args) => getIntegrityCheck().storeChecksums(...args),
    validateChecksums: (...args) => getIntegrityCheck().validateChecksums(...args),
    logAuditEvent: (...args) => getIntegrityCheck().logAuditEvent(...args),
    getAuditLog: (...args) => getIntegrityCheck().getAuditLog(...args),

    // Test-only exports (internal functions exposed for unit testing)
    _test: {
        docToOrder,
        _formatDate,
        ORDERS_COL,
        CART_COL,
        PACKED_COL,
    },
    // Sync support: expose collection refs and helpers for sync_fb.js
    _sync: {
        ordersCol,
        cartCol,
        packedCol,
        activeDocs,
        isActiveDoc,
    }
};
