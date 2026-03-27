/**
 * Sync Module — Incremental data sync for offline-first Flutter app
 *
 * Single endpoint that returns data changed since a given timestamp.
 * Supports per-collection delta queries using updatedAt fields.
 *
 * GET /api/sync?collections=orders,dropdowns&since=2024-01-01T00:00:00.000Z
 *
 * Returns:
 * {
 *   collections: {
 *     orders: { data: [...], deletedIds: [...] },
 *     dropdowns: { data: [...], deletedIds: [] },
 *   },
 *   syncTimestamp: "2024-01-15T12:00:00.000Z"
 * }
 */

const { getDb } = require('../firebaseClient');
const { TTLCache } = require('../utils/cache');

// ── Sync-level cache: prevents repeated Firestore reads within TTL window ──
const syncCache = new TTLCache({ defaultTTL: 5 * 60 * 1000, maxEntries: 50 });

// Per-collection cache TTLs (slow-changing data gets longer cache)
const SYNC_CACHE_TTL = {
    orders: 2 * 60 * 1000,  // 2 min (changes with order activity)
    dropdowns: 30 * 60 * 1000,  // 30 min (rarely changes)
    client_contacts: 10 * 60 * 1000,  // 10 min
    tasks: 2 * 60 * 1000,  // 2 min
    workers: 10 * 60 * 1000,  // 10 min (rarely changes)
    expenses: 10 * 60 * 1000,  // 10 min
    gate_passes: 5 * 60 * 1000,  // 5 min
    dispatch_documents: 5 * 60 * 1000,  // 5 min
    approval_requests: 2 * 60 * 1000,  // 2 min
};

// ── Collection handlers ─────────────────────────────────────────────────
// Each handler returns { data: [...], deletedIds: [...] } for a given `since` timestamp.

/**
 * Orders: combines orders + cart_orders + packed_orders.
 * Tags each doc with _collection so the client knows the source.
 */
async function _syncOrders(since) {
    const db = getDb();
    const collections = [
        { name: 'orders', tag: 'orders' },
        { name: 'cart_orders', tag: 'cart_orders' },
        { name: 'packed_orders', tag: 'packed_orders' },
    ];

    const data = [];
    const deletedIds = [];

    for (const { name, tag } of collections) {
        const colRef = db.collection(name);
        let query;
        if (since) {
            query = colRef.where('updatedAt', '>', since);
        } else {
            query = colRef;
        }

        const snap = await query.get();
        snap.docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted === true) {
                deletedIds.push({ id: doc.id, _collection: tag });
            } else {
                data.push({ id: doc.id, _collection: tag, ...d });
            }
        });
    }

    return { data, deletedIds };
}

/** Dropdowns: 5 category docs, rarely changes. Uses lastUpdated field. */
async function _syncDropdowns(since) {
    const colRef = getDb().collection('dropdown_data');
    let query;
    if (since) {
        query = colRef.where('lastUpdated', '>', since);
    } else {
        query = colRef;
    }

    const snap = await query.get();
    const data = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
    return { data, deletedIds: [] };
}

/** Client contacts: uses _updatedAt field. */
async function _syncClientContacts(since) {
    const colRef = getDb().collection('client_contacts');
    let query;
    if (since) {
        query = colRef.where('_updatedAt', '>', since);
    } else {
        query = colRef;
    }

    const snap = await query.get();
    const data = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
    return { data, deletedIds: [] };
}

/** Tasks: uses updatedAt field. */
async function _syncTasks(since) {
    const colRef = getDb().collection('tasks');
    let query;
    if (since) {
        query = colRef.where('updatedAt', '>', since);
    } else {
        query = colRef;
    }

    const snap = await query.get();
    const data = [];
    const deletedIds = [];

    snap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted === true) {
            deletedIds.push(doc.id);
        } else {
            data.push({ id: doc.id, ...d });
        }
    });

    return { data, deletedIds };
}

/** Workers: no updatedAt — always return all active workers. Uses deletedAt for soft-delete. */
async function _syncWorkers(since) {
    const colRef = getDb().collection('workers');
    // Workers don't have updatedAt, so always return full set
    const snap = await colRef.get();
    const data = [];
    const deletedIds = [];

    snap.docs.forEach(doc => {
        const d = doc.data();
        if (d.deletedAt) {
            deletedIds.push(doc.id);
        } else {
            data.push({ id: doc.id, ...d });
        }
    });

    return { data, deletedIds };
}

/** Expenses: uses updatedAt on expense sheets. */
async function _syncExpenses(since) {
    const colRef = getDb().collection('expenses');
    let query;
    if (since) {
        query = colRef.where('updatedAt', '>', since);
    } else {
        query = colRef;
    }

    const snap = await query.get();
    const data = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
    return { data, deletedIds: [] };
}

/** Gate passes: uses updatedAt. */
async function _syncGatePasses(since) {
    const colRef = getDb().collection('gate_passes');
    let query;
    if (since) {
        query = colRef.where('updatedAt', '>', since);
    } else {
        query = colRef;
    }

    const snap = await query.get();
    const data = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
    return { data, deletedIds: [] };
}

/** Dispatch documents: uses updatedAt, supports isDeleted soft-delete. */
async function _syncDispatchDocuments(since) {
    const colRef = getDb().collection('dispatch_documents');
    let query;
    if (since) {
        query = colRef.where('updatedAt', '>', since);
    } else {
        query = colRef;
    }

    const snap = await query.get();
    const data = [];
    const deletedIds = [];

    snap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted === true) {
            deletedIds.push(doc.id);
        } else {
            data.push({ id: doc.id, ...d });
        }
    });

    return { data, deletedIds };
}

/** Approval requests: uses updatedAt. */
async function _syncApprovalRequests(since) {
    const colRef = getDb().collection('approval_requests');
    let query;
    if (since) {
        query = colRef.where('updatedAt', '>', since);
    } else {
        query = colRef;
    }

    const snap = await query.get();
    const data = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
    return { data, deletedIds: [] };
}

// ── Handler registry ────────────────────────────────────────────────────
const SYNC_HANDLERS = {
    orders: _syncOrders,
    dropdowns: _syncDropdowns,
    client_contacts: _syncClientContacts,
    tasks: _syncTasks,
    workers: _syncWorkers,
    expenses: _syncExpenses,
    gate_passes: _syncGatePasses,
    dispatch_documents: _syncDispatchDocuments,
    approval_requests: _syncApprovalRequests,
};

// ── Main sync function ──────────────────────────────────────────────────

/**
 * Get sync data for requested collections.
 *
 * @param {string} collectionsStr - Comma-separated collection names (e.g. "orders,tasks,dropdowns")
 *                                   Use "all" to sync everything.
 * @param {string|null} since - ISO timestamp. null = full dump.
 * @returns {Promise<{ collections: object, syncTimestamp: string, availableCollections: string[] }>}
 */
// Employee-allowed collections (server-side defense in depth)
const EMPLOYEE_ALLOWED = new Set([
    'dropdowns', 'orders', 'tasks', 'workers', 'gate_passes',
]);

/**
 * Get sync data for requested collections.
 *
 * @param {string} collectionsStr - Comma-separated collection names or "all"
 * @param {string|null} since - Global ISO timestamp fallback. null = full dump.
 * @param {object|null} sinceMap - Per-collection timestamps (e.g. { orders: "2026-...", tasks: null })
 * @param {string|null} role - User role for server-side collection filtering
 * @returns {Promise<{ collections: object, syncTimestamp: string, availableCollections: string[] }>}
 */
async function getSyncData(collectionsStr, since = null, sinceMap = null, role = null) {
    const syncTimestamp = new Date().toISOString();

    // Parse requested collections
    let requestedKeys;
    if (!collectionsStr || collectionsStr === 'all') {
        requestedKeys = Object.keys(SYNC_HANDLERS);
    } else {
        requestedKeys = collectionsStr.split(',').map(s => s.trim()).filter(s => SYNC_HANDLERS[s]);
    }

    // Server-side role filtering: employees can only access allowed collections
    if (role === 'employee') {
        requestedKeys = requestedKeys.filter(k => EMPLOYEE_ALLOWED.has(k));
    }

    // Execute all requested handlers in parallel — with per-collection caching
    const results = {};
    const promises = requestedKeys.map(async (key) => {
        try {
            // Determine the 'since' timestamp for this specific collection
            const collectionSince = (sinceMap && sinceMap[key] !== undefined)
                ? sinceMap[key]  // per-collection timestamp (null = full dump for this collection)
                : since;         // fallback to global since

            // Build cache key from collection name + since timestamp
            const cacheKey = `sync:${key}:${collectionSince || 'full'}`;
            const cached = syncCache.get(cacheKey);
            if (cached) {
                results[key] = cached;
                return; // Cache hit — zero Firestore reads
            }

            const handler = SYNC_HANDLERS[key];
            const result = await handler(collectionSince);
            results[key] = result;

            // Cache the result with per-collection TTL
            const ttl = SYNC_CACHE_TTL[key] || 5 * 60 * 1000;
            syncCache.set(cacheKey, result, ttl);
        } catch (err) {
            console.error(`[Sync] Error syncing ${key}:`, err.message);
            results[key] = { data: [], deletedIds: [], error: err.message };
        }
    });

    await Promise.all(promises);

    return {
        collections: results,
        syncTimestamp,
        availableCollections: Object.keys(SYNC_HANDLERS),
    };
}

/**
 * Invalidate sync cache for specific collections.
 * Called by the API write middleware so fresh data is served on next sync.
 * @param {string[]} collections - e.g. ['orders', 'tasks']
 */
function invalidateSyncCache(collections) {
    for (const col of collections) {
        syncCache.invalidateByPrefix(`sync:${col}:`);
    }
}

module.exports = {
    getSyncData,
    SYNC_HANDLERS,
    invalidateSyncCache,
};
