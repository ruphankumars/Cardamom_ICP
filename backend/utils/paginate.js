/**
 * Pagination Utility — Cursor-based Firestore Pagination
 *
 * Provides standardized pagination across all list endpoints using
 * Firestore's native startAfter/limit cursor semantics.
 *
 * Response envelope:
 * {
 *   data: [...],
 *   pagination: { cursor, hasMore, limit }
 * }
 */

// Track query metrics for observability
const queryMetrics = {
    totalQueries: 0,
    totalDocs: 0,
    totalTimeMs: 0,
    // Per-endpoint breakdown for detailed stats
    byEndpoint: {},
};

/**
 * Parse pagination parameters from Express query params.
 * Clamps limit to [1, 100], defaults to 25.
 *
 * @param {object} query - req.query object
 * @param {object} defaults - endpoint-specific defaults for sortBy
 * @returns {{ limit: number, cursor: string|null, sortBy: string, sortDir: string }}
 */
function parsePaginationParams(query = {}, defaults = {}) {
    const limit = Math.max(1, Math.min(parseInt(query.limit) || defaults.limit || 25, 100));
    const cursor = query.cursor || null;
    const sortBy = query.sortBy || defaults.sortBy || 'createdAt';
    const sortDir = (query.sortDir === 'asc') ? 'asc' : (defaults.sortDir || 'desc');

    return { limit, cursor, sortBy, sortDir };
}

/**
 * Execute a paginated Firestore query using cursor-based pagination.
 * Fetches limit + 1 documents to determine if more pages exist.
 *
 * @param {FirebaseFirestore.CollectionReference} colRef - Firestore collection reference
 * @param {object} options
 * @param {number} options.limit - Page size
 * @param {string|null} options.cursor - Document ID to start after
 * @param {string} options.sortBy - Field to sort by
 * @param {string} options.sortDir - Sort direction ('asc' or 'desc')
 * @param {function} options.docTransform - Function to convert Firestore doc to response object
 * @param {Array<{field: string, op: string, value: *}>} [options.filters] - Optional Firestore where clauses
 * @param {string} [options.endpoint] - Endpoint name for per-route metrics tracking
 * @returns {Promise<{ data: Array, pagination: { cursor: string|null, hasMore: boolean, limit: number } }>}
 */
async function paginateQuery(colRef, options) {
    const { limit, cursor, sortBy, sortDir, docTransform, filters, endpoint } = options;
    const startTime = Date.now();

    // Build base query with optional filters
    let query = colRef;
    if (filters && Array.isArray(filters)) {
        for (const f of filters) {
            query = query.where(f.field, f.op, f.value);
        }
    }

    // Apply ordering and limit (fetch one extra to detect hasMore)
    query = query.orderBy(sortBy, sortDir).limit(limit + 1);

    // Apply cursor if provided
    if (cursor) {
        try {
            const cursorDoc = await colRef.doc(cursor).get();
            if (cursorDoc.exists) {
                query = colRef;
                // Re-apply filters after cursor
                if (filters && Array.isArray(filters)) {
                    for (const f of filters) {
                        query = query.where(f.field, f.op, f.value);
                    }
                }
                query = query.orderBy(sortBy, sortDir).startAfter(cursorDoc).limit(limit + 1);
            }
            // If cursor doc doesn't exist, just fetch from beginning
        } catch (err) {
            console.warn('[Paginate] Invalid cursor, fetching from beginning:', err.message);
        }
    }

    const snap = await query.get();
    const docs = snap.docs.slice(0, limit);
    const hasMore = snap.docs.length > limit;

    // Track metrics
    const elapsed = Date.now() - startTime;
    queryMetrics.totalQueries++;
    queryMetrics.totalDocs += docs.length;
    queryMetrics.totalTimeMs += elapsed;

    // Track per-endpoint metrics
    if (endpoint) {
        if (!queryMetrics.byEndpoint[endpoint]) {
            queryMetrics.byEndpoint[endpoint] = { queries: 0, docs: 0, totalTimeMs: 0 };
        }
        queryMetrics.byEndpoint[endpoint].queries++;
        queryMetrics.byEndpoint[endpoint].docs += docs.length;
        queryMetrics.byEndpoint[endpoint].totalTimeMs += elapsed;
    }

    // Performance logging for slow queries (>500ms)
    if (elapsed > 500) {
        console.warn(`[Paginate] Slow query: ${endpoint || 'unknown'} took ${elapsed}ms, returned ${docs.length} docs`);
    }

    return {
        data: docs.map(docTransform),
        pagination: {
            cursor: hasMore ? docs[docs.length - 1].id : null,
            hasMore,
            limit
        }
    };
}

/**
 * Get pagination query metrics for observability.
 * @returns {{ totalQueries: number, totalDocs: number, totalTimeMs: number, avgTimeMs: number }}
 */
function getQueryMetrics() {
    // Build per-endpoint summary with computed averages
    const endpointStats = {};
    for (const [name, stats] of Object.entries(queryMetrics.byEndpoint)) {
        endpointStats[name] = {
            ...stats,
            avgTimeMs: stats.queries > 0 ? Math.round(stats.totalTimeMs / stats.queries) : 0,
            avgDocsPerQuery: stats.queries > 0 ? Math.round(stats.docs / stats.queries) : 0,
        };
    }

    return {
        totalQueries: queryMetrics.totalQueries,
        totalDocs: queryMetrics.totalDocs,
        totalTimeMs: queryMetrics.totalTimeMs,
        avgTimeMs: queryMetrics.totalQueries > 0
            ? Math.round(queryMetrics.totalTimeMs / queryMetrics.totalQueries)
            : 0,
        avgDocsPerQuery: queryMetrics.totalQueries > 0
            ? Math.round(queryMetrics.totalDocs / queryMetrics.totalQueries)
            : 0,
        byEndpoint: endpointStats,
    };
}

/**
 * Reset query metrics (useful for testing).
 */
function resetQueryMetrics() {
    queryMetrics.totalQueries = 0;
    queryMetrics.totalDocs = 0;
    queryMetrics.totalTimeMs = 0;
    queryMetrics.byEndpoint = {};
}

module.exports = {
    parsePaginationParams,
    paginateQuery,
    getQueryMetrics,
    resetQueryMetrics
};
