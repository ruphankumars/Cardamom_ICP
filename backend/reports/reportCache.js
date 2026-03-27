/**
 * Report Cache & Concurrency Limiter
 *
 * LRU cache for generated reports (max 50 entries, 15-min TTL).
 * Semaphore-based concurrency limiter (max 3 concurrent generations).
 * Prevents memory spikes on Render.com free tier (512MB RAM).
 */

const crypto = require('crypto');

// ============================================================================
// LRU CACHE
// ============================================================================

const MAX_CACHE_SIZE = 50;
const CACHE_TTL_MS = 15 * 60 * 1000; // 15 minutes

class ReportCache {
    constructor() {
        this._cache = new Map(); // key -> { buffer, contentType, createdAt }
    }

    /**
     * Generate a cache key from report type, parameters, and format
     */
    static makeKey(reportType, params, format) {
        const raw = JSON.stringify({ reportType, params, format });
        return crypto.createHash('md5').update(raw).digest('hex');
    }

    /**
     * Get a cached report buffer, or null if not found / expired
     */
    get(key) {
        const entry = this._cache.get(key);
        if (!entry) return null;

        // Check TTL
        if (Date.now() - entry.createdAt > CACHE_TTL_MS) {
            this._cache.delete(key);
            return null;
        }

        // Move to end (most recently used)
        this._cache.delete(key);
        this._cache.set(key, entry);
        return entry;
    }

    /**
     * Store a report in the cache
     */
    set(key, buffer, contentType, filename) {
        // Evict oldest if at capacity
        if (this._cache.size >= MAX_CACHE_SIZE) {
            const oldestKey = this._cache.keys().next().value;
            this._cache.delete(oldestKey);
        }

        this._cache.set(key, {
            buffer,
            contentType,
            filename,
            createdAt: Date.now()
        });
    }

    /**
     * Clear all cached reports
     */
    clear() {
        this._cache.clear();
    }

    get size() {
        return this._cache.size;
    }
}

// ============================================================================
// CONCURRENCY LIMITER (Semaphore)
// ============================================================================

const MAX_CONCURRENT = 3;

class ConcurrencyLimiter {
    constructor(limit = MAX_CONCURRENT) {
        this._limit = limit;
        this._running = 0;
        this._queue = [];
    }

    /**
     * Acquire a slot. Returns a promise that resolves when a slot is available.
     * The resolved value is a release function that MUST be called when done.
     */
    acquire() {
        return new Promise((resolve) => {
            const tryAcquire = () => {
                if (this._running < this._limit) {
                    this._running++;
                    resolve(() => {
                        this._running--;
                        if (this._queue.length > 0) {
                            const next = this._queue.shift();
                            next();
                        }
                    });
                } else {
                    this._queue.push(tryAcquire);
                }
            };
            tryAcquire();
        });
    }

    get running() {
        return this._running;
    }

    get queued() {
        return this._queue.length;
    }
}

// Singleton instances
const reportCache = new ReportCache();
const concurrencyLimiter = new ConcurrencyLimiter();

module.exports = {
    ReportCache,
    ConcurrencyLimiter,
    reportCache,
    concurrencyLimiter
};
