/**
 * Simple In-Memory TTL Cache
 *
 * Lightweight Map-based cache with TTL expiration.
 * Used for caching slowly-changing data like dropdown options,
 * dashboard summary counts, and collection count estimates.
 *
 * No external dependencies required.
 */

class TTLCache {
    /**
     * @param {object} options
     * @param {number} options.defaultTTL - Default TTL in milliseconds (default: 60000 = 1 minute)
     * @param {number} options.maxEntries - Max cache entries before oldest are evicted (default: 100)
     */
    constructor({ defaultTTL = 60000, maxEntries = 100 } = {}) {
        this._cache = new Map();
        this._defaultTTL = defaultTTL;
        this._maxEntries = maxEntries;
        this._hits = 0;
        this._misses = 0;
    }

    /**
     * Get a cached value. Returns undefined if not found or expired.
     * @param {string} key
     * @returns {*|undefined}
     */
    get(key) {
        const entry = this._cache.get(key);
        if (!entry) {
            this._misses++;
            return undefined;
        }
        if (Date.now() > entry.expiresAt) {
            this._cache.delete(key);
            this._misses++;
            return undefined;
        }
        this._hits++;
        return entry.value;
    }

    /**
     * Set a cached value with optional TTL override.
     * @param {string} key
     * @param {*} value
     * @param {number} [ttl] - TTL in milliseconds (uses default if not provided)
     */
    set(key, value, ttl) {
        // Evict oldest entries if at capacity
        if (this._cache.size >= this._maxEntries && !this._cache.has(key)) {
            const firstKey = this._cache.keys().next().value;
            this._cache.delete(firstKey);
        }

        this._cache.set(key, {
            value,
            expiresAt: Date.now() + (ttl || this._defaultTTL),
        });
    }

    /**
     * Delete a cached entry.
     * @param {string} key
     */
    delete(key) {
        this._cache.delete(key);
    }

    /**
     * Delete all entries matching a key prefix.
     * Useful for invalidating a category of cached data.
     * @param {string} prefix
     */
    invalidateByPrefix(prefix) {
        for (const key of this._cache.keys()) {
            if (key.startsWith(prefix)) {
                this._cache.delete(key);
            }
        }
    }

    /**
     * Clear all cached entries.
     */
    clear() {
        this._cache.clear();
    }

    /**
     * Get cache statistics.
     */
    getStats() {
        const total = this._hits + this._misses;
        return {
            entries: this._cache.size,
            hits: this._hits,
            misses: this._misses,
            hitRate: total > 0 ? ((this._hits / total) * 100).toFixed(1) + '%' : '0%',
        };
    }
}

// Singleton cache instances for different TTL needs
const dropdownCache = new TTLCache({ defaultTTL: 5 * 60 * 1000 });  // 5 minutes
const dashboardCache = new TTLCache({ defaultTTL: 60 * 1000 });      // 60 seconds
const countCache = new TTLCache({ defaultTTL: 5 * 60 * 1000 });      // 5 minutes
const aiCache = new TTLCache({ defaultTTL: 5 * 60 * 1000, maxEntries: 50 }); // 5 minutes for AI endpoints

module.exports = {
    TTLCache,
    dropdownCache,
    dashboardCache,
    countCache,
    aiCache,
};
