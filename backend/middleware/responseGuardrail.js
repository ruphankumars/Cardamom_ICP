/**
 * Response Size Guardrail Middleware
 *
 * Monitors and caps API response sizes to prevent OOM crashes
 * on the Render.com hobby tier (512 MB RAM).
 *
 * - Logs warnings for responses > 1 MB
 * - Truncates array data in responses > 2 MB and sets pagination.truncated = true
 */

const MAX_RESPONSE_SIZE = 2 * 1024 * 1024; // 2 MB
const WARN_RESPONSE_SIZE = 1 * 1024 * 1024; // 1 MB

// Track response size metrics
const sizeMetrics = {
    totalResponses: 0,
    oversizedResponses: 0,
    truncatedResponses: 0,
    largestResponseBytes: 0,
};

/**
 * Express middleware that intercepts res.json() to monitor and cap response sizes.
 */
function responseGuardrail(req, res, next) {
    const originalJson = res.json.bind(res);

    res.json = function (body) {
        sizeMetrics.totalResponses++;

        try {
            const jsonStr = JSON.stringify(body);
            const sizeBytes = Buffer.byteLength(jsonStr, 'utf8');

            if (sizeBytes > sizeMetrics.largestResponseBytes) {
                sizeMetrics.largestResponseBytes = sizeBytes;
            }

            if (sizeBytes > WARN_RESPONSE_SIZE) {
                const sizeMB = (sizeBytes / (1024 * 1024)).toFixed(2);
                console.warn(`[ResponseGuardrail] Large response: ${req.method} ${req.path} = ${sizeMB} MB`);
                sizeMetrics.oversizedResponses++;
            }

            if (sizeBytes > MAX_RESPONSE_SIZE) {
                console.error(`[ResponseGuardrail] Response exceeds 2 MB limit: ${req.method} ${req.path}`);
                sizeMetrics.truncatedResponses++;

                // Try to truncate data array if present
                if (body && typeof body === 'object') {
                    const truncated = truncateResponse(body);
                    return originalJson(truncated);
                }
            }
        } catch (err) {
            // If serialization fails, send original body
            console.error('[ResponseGuardrail] Error checking response size:', err.message);
        }

        return originalJson(body);
    };

    next();
}

/**
 * Attempt to truncate the response body to fit within the size limit.
 * Looks for common data array patterns and truncates them.
 */
function truncateResponse(body) {
    // Pattern 1: { data: [...], pagination: {...} }
    if (Array.isArray(body.data)) {
        const truncatedData = body.data.slice(0, Math.floor(body.data.length / 2));
        return {
            ...body,
            data: truncatedData,
            pagination: {
                ...(body.pagination || {}),
                truncated: true,
                originalCount: body.data.length,
                returnedCount: truncatedData.length
            }
        };
    }

    // Pattern 2: { success: true, requests: [...] }
    for (const key of ['requests', 'entries', 'logs', 'tasks', 'passes']) {
        if (Array.isArray(body[key])) {
            const truncatedArr = body[key].slice(0, Math.floor(body[key].length / 2));
            return {
                ...body,
                [key]: truncatedArr,
                pagination: {
                    ...(body.pagination || {}),
                    truncated: true,
                    originalCount: body[key].length,
                    returnedCount: truncatedArr.length
                }
            };
        }
    }

    // Pattern 3: grouped object (orders) - return as-is with warning
    return {
        ...body,
        _warning: 'Response size exceeds 2 MB limit. Enable pagination to reduce response size.'
    };
}

/**
 * Get response size metrics for the stats endpoint.
 */
function getResponseMetrics() {
    return {
        ...sizeMetrics,
        largestResponseMB: (sizeMetrics.largestResponseBytes / (1024 * 1024)).toFixed(2),
    };
}

module.exports = { responseGuardrail, getResponseMetrics };
