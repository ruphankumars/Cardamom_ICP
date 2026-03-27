const router = require('express').Router();

const dashboard = require('../../../backend/firebase/dashboard_fb');
const orderBook = require('../../../backend/firebase/orderBook_fb');
const stockCalc = require('../../../backend/firebase/stock_fb');
const approvalRequests = require('../../../backend/firebase/approval_requests_fb');
const settingsFb = require('../../../backend/firebase/settings_fb');
const syncFb = require('../../../backend/firebase/sync_fb');
const clientRequests = require('../../../backend/firebase/client_requests_fb');
const users = require('../../../backend/firebase/users_fb');
const pushNotifications = require('../../../backend/firebase/push_notifications_fb');
const admin = require('../../../backend/admin');
const audit = require('../../../backend/audit_log');

const featureFlags = require('../../../backend/featureFlags');
const { requireAdmin, requireSuperAdmin } = require('../../../backend/middleware/auth');
const { getCachedResponse, setCachedResponse } = require('../middleware/apiCache');
const { getQueryMetrics } = require('../../../backend/utils/paginate');
const { dropdownCache, dashboardCache, countCache } = require('../../../backend/utils/cache');

// Helper: extract user info from JWT-authenticated request
function getUserFromRequest(req) {
    if (req.user) {
        return { username: req.user.username, role: req.user.role };
    }
    // Never trust headers for auth — return unknown if JWT not present
    return { username: 'unknown', role: 'unknown' };
}

// ==================== ADMIN SETTINGS ====================

// GET /settings/notification-numbers
router.get('/settings/notification-numbers', async (req, res) => {
    try {
        const data = await settingsFb.getNotificationNumbers();
        res.json({ success: true, ...data });
    } catch (err) {
        console.error('[GET /api/admin/settings/notification-numbers] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// PUT /settings/notification-numbers
router.put('/settings/notification-numbers', requireAdmin, async (req, res) => {
    try {
        const { phones } = req.body;
        if (!Array.isArray(phones)) {
            return res.status(400).json({ success: false, error: 'phones must be an array' });
        }
        const updatedBy = req.user?.username || 'unknown';
        const result = await settingsFb.updateNotificationNumbers(phones, updatedBy);
        res.json(result);
    } catch (err) {
        console.error('[PUT /api/admin/settings/notification-numbers] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== ADMIN OPERATIONS ====================

// POST /recalc
router.post('/recalc', requireAdmin, async (req, res) => {
    try {
        const result = await admin.recalcDeltaFromMenu();
        await audit.logAction(req.user.username || 'Unknown', 'ADMIN_RECALC', 'Recalculated delta from menu', {});
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /rebuild
router.post('/rebuild', requireAdmin, async (req, res) => {
    try {
        const result = await admin.rebuildFromScratchFromMenu();
        await audit.logAction(req.user.username || 'Unknown', 'ADMIN_REBUILD', 'Rebuilt database from scratch', {});
        res.json({ message: result });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /reset-pointer
router.post('/reset-pointer', requireAdmin, async (req, res) => {
    try {
        const result = await admin.resetDeltaPointerFromMenu();
        await audit.logAction(req.user.username || 'Unknown', 'ADMIN_RESET_POINTER', 'Reset delta pointer', {});
        res.json({ message: result });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /pointer
router.get('/pointer', requireAdmin, (req, res) => {
    try {
        const result = admin.showDeltaPointer();
        res.json({ message: result });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== INTEGRITY CHECKS ====================

// GET /integrity
router.get('/integrity', requireAdmin, async (req, res) => {
    try {
        const report = await orderBook.getIntegrityReport();
        res.json({ success: true, report });
    } catch (err) {
        console.error('[IntegrityCheck] API Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /integrity/overlaps
router.get('/integrity/overlaps', requireAdmin, async (req, res) => {
    try {
        const result = await orderBook.validateNoOrderOverlap();
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[IntegrityCheck] Overlap API Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /integrity/sale-order
router.get('/integrity/sale-order', requireAdmin, async (req, res) => {
    try {
        const result = await orderBook.validateSaleOrderIntegrity();
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[IntegrityCheck] Sale order validation error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /integrity/order-quantities
router.get('/integrity/order-quantities', requireAdmin, async (req, res) => {
    try {
        const result = await stockCalc.verifyOrderIntegrity();
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[IntegrityCheck] Order quantity verification error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /integrity/checksums
router.get('/integrity/checksums', requireAdmin, async (req, res) => {
    try {
        const result = await orderBook.validateChecksums();
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[IntegrityCheck] Checksum validation error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /integrity/checksums/store
router.post('/integrity/checksums/store', requireAdmin, async (req, res) => {
    try {
        const checksums = await orderBook.storeChecksums();
        await audit.logAction(req.user.username || 'Unknown', 'STORE_CHECKSUMS', 'Stored integrity checksums', {});
        res.json({ success: true, message: 'Checksums stored successfully', checksums });
    } catch (err) {
        console.error('[IntegrityCheck] Store checksum error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== AUDIT LOG ====================

// GET /audit-log
router.get('/audit-log', requireAdmin, async (req, res) => {
    try {
        if (featureFlags.usePagination() && req.query.cursor) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 50, 100));
            const result = await audit.getPaginatedLogs({ limit, cursor: req.query.cursor });
            return res.json({ success: true, ...result });
        }
        const limit = parseInt(req.query.limit) || 50;
        const entries = await orderBook.getAuditLog(limit);
        res.json({ success: true, entries, count: entries.length });
    } catch (err) {
        console.error('[IntegrityCheck] Audit log error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== SYNC ALL ORDERS ====================

// POST /sync-allorders
router.post('/sync-allorders', requireAdmin, async (req, res) => {
    try {
        const { syncAllOrders } = require('../../../backend/scripts/sync_all_orders_to_sheet');
        const summary = await syncAllOrders();
        await audit.logAction(req.user.username || 'Unknown', 'SYNC_ALL_ORDERS', 'Synced all orders to sheets', summary);
        res.json({ success: true, ...summary });
    } catch (err) {
        console.error('[SyncAllOrders] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== FEATURE FLAGS ====================

// GET /feature-flags
router.get('/feature-flags', requireAdmin, (req, res) => {
    res.json({ success: true, flags: featureFlags.getStatus() });
});

// ==================== PAGINATION STATS ====================

// GET /pagination-stats
router.get('/pagination-stats', requireAdmin, (req, res) => {
    res.json({
        success: true,
        pagination: {
            enabled: featureFlags.usePagination(),
            queryMetrics: getQueryMetrics(),
        },
        caches: {
            dropdown: dropdownCache.getStats(),
            dashboard: dashboardCache.getStats(),
            count: countCache.getStats(),
        },
        serverUptime: Math.round(process.uptime()),
    });
});

// ==================== ADMIN CLIENT REQUESTS ====================

// GET /client-requests - Get all requests (admin inbox with filters)
router.get('/client-requests', requireAdmin, async (req, res) => {
    try {
        const { status, client, type, clientUsername } = req.query;

        const filters = {};
        if (status) filters.status = status;
        if (client) filters.client = client;
        if (type) filters.type = type;
        if (clientUsername) filters.clientUsername = clientUsername;

        const requests = await clientRequests.getRequestsForAdmin(filters);
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[GET /api/admin/client-requests] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /client-requests/:id/start-draft - Admin starts editing draft
router.post('/client-requests/:id/start-draft', requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;

        const result = await clientRequests.adminStartDraft(id);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/start-draft] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /client-requests/:id/draft - Save draft panel (admin)
router.post(['/client-requests/:id/draft', '/client-requests/:id/save-draft'], requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const { panelDraft } = req.body;

        if (!panelDraft) {
            return res.status(400).json({ success: false, error: 'panelDraft required' });
        }

        const result = await clientRequests.saveDraftPanel(id, 'ADMIN', panelDraft);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/save-draft] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /client-requests/:id/send - Send panel message (admin)
router.post(['/client-requests/:id/send', '/client-requests/:id/send-panel'], requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const { panelSnapshot, optionalText } = req.body;
        const { username } = getUserFromRequest(req);

        if (!panelSnapshot) {
            return res.status(400).json({ success: false, error: 'panelSnapshot required' });
        }

        const result = await clientRequests.sendPanelMessage(id, 'ADMIN', username, panelSnapshot, optionalText);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/send-panel] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /client-requests/:id/confirm - Confirm request (admin)
router.post('/client-requests/:id/confirm', requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const { username } = getUserFromRequest(req);
        const result = await clientRequests.confirmRequest(id, 'ADMIN', username);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/confirm] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /client-requests/:id/cancel - Cancel request (admin)
router.post('/client-requests/:id/cancel', requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const { reason } = req.body;
        const { username } = getUserFromRequest(req);
        const result = await clientRequests.cancelRequest(id, 'ADMIN', reason, username);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/cancel] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /client-requests/:id/reinitiate - Reinitiate expired negotiation (admin)
router.post('/client-requests/:id/reinitiate', requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const result = await clientRequests.reinitiateNegotiation(id, 'ADMIN');
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/reinitiate] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /client-requests/:id/convert-to-order - Convert confirmed request to order
router.post(['/client-requests/:id/convert-to-order', '/client-requests/:id/convert'], requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const { billingFrom, brand, orders } = req.body;

        const result = await clientRequests.convertConfirmedToOrder(id, billingFrom, brand, orders);
        res.json({ success: true, ...result });

        // Push notification to other admins (fire-and-forget)
        pushNotifications.notifyNewOrders(req.user.id, req.user.username || 'Admin', orders || [])
            .catch(err => console.error('[FCM] Push error (admin convert):', err.message));
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/convert] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== DASHBOARD (mounted at /api/dashboard) ====================

// GET /dashboard
router.get('/dashboard', async (req, res) => {
    try {
        const cached = getCachedResponse('/api/dashboard');
        if (cached) return res.json(cached);
        const data = await dashboard.getDashboardPayload();
        setCachedResponse('/api/dashboard', data);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== SYNC (mounted at /api/sync) ====================

// GET /sync
router.get('/sync', async (req, res) => {
    try {
        const { collections, since, sinceMap, role } = req.query;
        const sinceTs = since || null;

        // Parse per-collection timestamps if provided
        let parsedSinceMap = null;
        if (sinceMap) {
            try {
                parsedSinceMap = JSON.parse(sinceMap);
            } catch (e) {
                // ignore parse error, fall back to global since
            }
        }

        const data = await syncFb.getSyncData(
            collections || 'all',
            sinceTs,
            parsedSinceMap,
            role || null
        );
        res.json({ success: true, ...data });
    } catch (err) {
        console.error('[Sync] GET error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
