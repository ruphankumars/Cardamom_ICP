/**
 * Feature Flags for Phased Migration (Phase 8) + Performance Features
 */

const MODULE_FLAGS = {
    // Phase 7 (hybrid)
    stock:           'FB_STOCK',

    // Phase 8
    dropdown:        'FB_DROPDOWN',
    stockEngine:     'FB_STOCK_ENGINE',
    saleAggregation: 'FB_SALE_AGGREGATION',
    analytics:       'FB_ANALYTICS',
    dashboard:       'FB_DASHBOARD',
    predictive:      'FB_PREDICTIVE',
    aiBrain:         'FB_AI_BRAIN',

    // Fully migrated (always Firestore)
    users:           'FB_USERS',
    approvals:       'FB_APPROVALS',
    clientRequests:  'FB_CLIENT_REQUESTS',
    orders:          'FB_ORDERS',
    tasks:           'FB_TASKS',
    attendance:      'FB_ATTENDANCE',
    expenses:        'FB_EXPENSES',
    gatepasses:      'FB_GATEPASSES',

    // Performance features
    paginatedEndpoints: 'PAGINATED_ENDPOINTS',
};

function useFirestore(moduleName) {
    // All modules now use Firestore exclusively (Phase 8 migration complete).
    // This function is retained for backward compatibility but always returns true.
    return true;
}

/**
 * Check if paginated endpoints are enabled.
 * Controlled by PAGINATED_ENDPOINTS env var. Defaults to true.
 * Set PAGINATED_ENDPOINTS=false to disable pagination and revert to full collection loads.
 */
function usePagination() {
    const envVal = process.env.PAGINATED_ENDPOINTS;
    if (envVal === 'false' || envVal === '0') return false;
    return true;  // Default: enabled
}

function getStatus() {
    const status = {};
    for (const [module, envVar] of Object.entries(MODULE_FLAGS)) {
        status[module] = {
            envVar,
            backend: useFirestore(module) ? 'FIRESTORE' : 'SHEETS',
        };
    }
    return status;
}

function logStatus() {
    console.log('[FeatureFlags] Current backend configuration:');
    for (const [module, envVar] of Object.entries(MODULE_FLAGS)) {
        const backend = useFirestore(module) ? 'FIRESTORE' : 'SHEETS';
        console.log(`  ${module.padEnd(18)} → ${backend}`);
    }
}

module.exports = { useFirestore, usePagination, getStatus, logStatus, MODULE_FLAGS };
