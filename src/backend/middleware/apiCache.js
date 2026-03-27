/**
 * API Response Cache — TTL-based with LRU eviction
 *
 * Extracted from server.js. Reduces database reads by caching GET responses
 * for short durations with targeted invalidation on writes.
 */

const _apiCache = new Map(); // key -> { data, expiresAt, lastAccess }
const API_CACHE_MAX_SIZE = 500;

// TTL config: exact path match first, then prefix match for parameterized routes
const API_CACHE_TTL = {
    // Core data (2 min)
    '/api/dashboard': 120 * 1000,
    '/api/stock/net': 120 * 1000,
    '/api/orders/sales-summary': 120 * 1000,
    '/api/orders/by-grade': 120 * 1000,
    '/api/orders/pending': 120 * 1000,
    '/api/orders/today-cart': 120 * 1000,
    '/api/orders/ledger-clients': 120 * 1000,
    '/api/orders': 120 * 1000,
    // Stock health (2 min)
    '/api/stock/health': 120 * 1000,
    '/api/stock/negative-check': 120 * 1000,
    // Analytics (5 min)
    '/api/analytics/stock-forecast': 300 * 1000,
    '/api/analytics/client-scores': 300 * 1000,
    '/api/analytics/insights': 300 * 1000,
    '/api/analytics/demand-trends': 300 * 1000,
    '/api/analytics/seasonal-analysis': 300 * 1000,
    '/api/analytics/suggested-prices': 300 * 1000,
    // AI Brain (5 min)
    '/api/ai/daily-briefing': 300 * 1000,
    '/api/ai/recommendations': 300 * 1000,
    // Tasks / Approval (2 min)
    '/api/tasks': 120 * 1000,
    '/api/tasks/stats': 120 * 1000,
    '/api/approval-requests': 120 * 1000,
    // Outstanding payments (5 min)
    '/api/outstanding': 300 * 1000,
    '/api/outstanding/name-mappings': 300 * 1000,
    // Documents (5 min)
    '/api/dispatch-documents': 300 * 1000,
    '/api/transport-documents': 300 * 1000,
    // Sync (2 min)
    '/api/sync': 120 * 1000,
    // Contacts (5 min)
    '/api/clients/contacts/all': 300 * 1000,
};

const API_CACHE_TTL_PREFIX = [
    { prefix: '/api/ai/grade-analysis/', ttl: 120 * 1000 },
    { prefix: '/api/ai/client-analysis/', ttl: 120 * 1000 },
];

function _getTtl(key) {
    const basePath = key.split('?')[0].split('{')[0];
    if (API_CACHE_TTL[basePath]) return API_CACHE_TTL[basePath];
    for (const { prefix, ttl } of API_CACHE_TTL_PREFIX) {
        if (basePath.startsWith(prefix)) return ttl;
    }
    return 0;
}

function getCachedResponse(key) {
    const entry = _apiCache.get(key);
    if (!entry) return null;
    if (Date.now() > entry.expiresAt) { _apiCache.delete(key); return null; }
    entry.lastAccess = Date.now();
    return entry.data;
}

function setCachedResponse(key, data) {
    const ttl = _getTtl(key);
    if (!ttl) return;
    if (_apiCache.size >= API_CACHE_MAX_SIZE) {
        let oldestKey = null, oldestTime = Infinity;
        for (const [k, v] of _apiCache) {
            if (v.lastAccess < oldestTime) { oldestTime = v.lastAccess; oldestKey = k; }
        }
        if (oldestKey) _apiCache.delete(oldestKey);
    }
    _apiCache.set(key, { data, expiresAt: Date.now() + ttl, lastAccess: Date.now() });
}

function invalidateApiCache() {
    _apiCache.clear();
}

function invalidateCachePrefix(prefix) {
    for (const key of _apiCache.keys()) {
        if (key.startsWith(prefix)) _apiCache.delete(key);
    }
}

// Periodic sweep of expired entries (every 5 minutes)
// Deferred to avoid 'setInterval is not defined' outside Azle Server() callback
if (typeof setInterval !== 'undefined') {
    setInterval(() => {
        const now = Date.now();
        for (const [key, entry] of _apiCache) {
            if (now > entry.expiresAt) _apiCache.delete(key);
        }
    }, 5 * 60 * 1000);
}

/**
 * Targeted cache invalidation middleware for write operations.
 * Clears API + sync caches related to the modified resource.
 */
function cacheInvalidationMiddleware(syncFb) {
    return (req, res, next) => {
        if (['POST', 'PUT', 'DELETE'].includes(req.method) && req.path.startsWith('/api/')) {
            const p = req.path;
            if (p.startsWith('/api/orders') || p.startsWith('/api/stock')) {
                invalidateCachePrefix('/api/orders');
                invalidateCachePrefix('/api/stock');
                invalidateCachePrefix('/api/dashboard');
                if (syncFb) syncFb.invalidateSyncCache(['orders']);
            }
            if (p.startsWith('/api/tasks')) {
                invalidateCachePrefix('/api/tasks');
                if (syncFb) syncFb.invalidateSyncCache(['tasks']);
            }
            if (p.startsWith('/api/approval')) {
                invalidateCachePrefix('/api/approval');
                if (syncFb) syncFb.invalidateSyncCache(['approval_requests']);
            }
            if (p.startsWith('/api/outstanding')) {
                invalidateCachePrefix('/api/outstanding');
            }
            if (p.startsWith('/api/dispatch-documents')) {
                invalidateCachePrefix('/api/dispatch-documents');
                if (syncFb) syncFb.invalidateSyncCache(['dispatch_documents']);
            }
            if (p.startsWith('/api/transport-documents')) {
                invalidateCachePrefix('/api/transport-documents');
            }
            if (p.startsWith('/api/clients')) {
                invalidateCachePrefix('/api/clients');
                if (syncFb) syncFb.invalidateSyncCache(['client_contacts']);
            }
            if (p.startsWith('/api/attendance')) {
                invalidateCachePrefix('/api/attendance');
                invalidateCachePrefix('/api/dashboard');
                if (syncFb) syncFb.invalidateSyncCache(['attendance']);
            }
            if (p.startsWith('/api/expenses')) {
                invalidateCachePrefix('/api/expenses');
                invalidateCachePrefix('/api/dashboard');
                if (syncFb) syncFb.invalidateSyncCache(['expenses']);
            }
            if (p.startsWith('/api/gate-passes')) {
                invalidateCachePrefix('/api/gate-passes');
                if (syncFb) syncFb.invalidateSyncCache(['gate_passes']);
            }
            if (p.startsWith('/api/notifications')) {
                invalidateCachePrefix('/api/notifications');
            }
            if (p.startsWith('/api/dropdown')) {
                invalidateCachePrefix('/api/dropdown');
                if (syncFb) syncFb.invalidateSyncCache(['dropdowns']);
            }
            if (p.includes('transport-assignments')) {
                invalidateCachePrefix('/api/orders/today-cart');
                invalidateCachePrefix('/api/orders/transport-assignments');
            }
        }
        next();
    };
}

module.exports = {
    getCachedResponse,
    setCachedResponse,
    invalidateApiCache,
    invalidateCachePrefix,
    cacheInvalidationMiddleware,
};
