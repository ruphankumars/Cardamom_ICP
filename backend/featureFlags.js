/**
 * Feature Flags for ICP Migration
 *
 * All modules now use SQLite (via sqliteClient.js) on ICP.
 * Firebase/Firestore is no longer used.
 */

const MODULE_FLAGS = {
    // All modules use ICP/SQLite backend
    stock:           'ICP_STOCK',
    dropdown:        'ICP_DROPDOWN',
    stockEngine:     'ICP_STOCK_ENGINE',
    saleAggregation: 'ICP_SALE_AGGREGATION',
    analytics:       'ICP_ANALYTICS',
    dashboard:       'ICP_DASHBOARD',
    predictive:      'ICP_PREDICTIVE',
    aiBrain:         'ICP_AI_BRAIN',
    users:           'ICP_USERS',
    approvals:       'ICP_APPROVALS',
    clientRequests:  'ICP_CLIENT_REQUESTS',
    orders:          'ICP_ORDERS',
    tasks:           'ICP_TASKS',
    attendance:      'ICP_ATTENDANCE',
    expenses:        'ICP_EXPENSES',
    gatepasses:      'ICP_GATEPASSES',

    // Performance features
    paginatedEndpoints: 'PAGINATED_ENDPOINTS',
};

/**
 * @deprecated — All modules now use SQLite on ICP. Retained for backward compatibility.
 * Always returns false (Firestore is not used).
 */
function useFirestore(moduleName) {
    return false;
}

/**
 * Check if the ICP/SQLite backend is active.
 * Always returns true on this deployment.
 */
function useIcp(moduleName) {
    return true;
}

/**
 * Check if paginated endpoints are enabled.
 * Controlled by PAGINATED_ENDPOINTS env var. Defaults to true.
 */
function usePagination() {
    const envVal = process.env.PAGINATED_ENDPOINTS;
    if (envVal === 'false' || envVal === '0') return false;
    return true;
}

function getStatus() {
    const status = {};
    for (const [module, envVar] of Object.entries(MODULE_FLAGS)) {
        status[module] = {
            envVar,
            backend: 'ICP_SQLITE',
        };
    }
    return status;
}

function logStatus() {
    console.log('[FeatureFlags] Current backend configuration:');
    for (const [module] of Object.entries(MODULE_FLAGS)) {
        console.log(`  ${module.padEnd(18)} → ICP_SQLITE`);
    }
}

module.exports = { useFirestore, useIcp, usePagination, getStatus, logStatus, MODULE_FLAGS };
