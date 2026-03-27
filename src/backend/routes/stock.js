const router = require('express').Router();
const stockCalc = require('../../../backend/firebase/stock_fb');
const { requireAdmin } = require('../../../backend/middleware/auth');
const { getCachedResponse, setCachedResponse } = require('../middleware/apiCache');

// Helper: extract user info from JWT-authenticated request
function getUserFromRequest(req) {
    if (req.user) {
        return { username: req.user.username, role: req.user.role };
    }
    // Never trust headers for auth — return unknown if JWT not present
    return { username: 'unknown', role: 'unknown' };
}

// GET /net
router.get('/net', async (req, res) => {
    try {
        const cacheKey = '/api/stock/net';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const data = await stockCalc.getNetStockForUi();
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /purchase
router.post('/purchase', requireAdmin, async (req, res) => {
    try {
        const { qtyArray, date } = req.body;
        if (!Array.isArray(qtyArray)) return res.status(400).json({ success: false, error: 'qtyArray must be an array' });
        const result = await stockCalc.addTodayPurchase(qtyArray, date);
        // Automatically recalculate stock after adding purchase
        await stockCalc.updateAllStocks();
        res.json({ message: result });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /recalc
router.post('/recalc', requireAdmin, async (req, res) => {
    try {
        const result = await stockCalc.updateAllStocks();
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Clear all Rejection stock adjustments
// POST /clear-rejection
router.post('/clear-rejection', async (req, res) => {
    try {
        const result = await stockCalc.clearRejectionAdjustments();
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Manual stock adjustment
// POST /adjust
router.post('/adjust', requireAdmin, async (req, res) => {
    try {
        // Ensure we always return JSON, even on errors
        res.setHeader('Content-Type', 'application/json');
        const user = getUserFromRequest(req);
        const result = await stockCalc.addStockAdjustment({
            ...(req.body || {}),
            userRole: user.role,
            requesterName: user.username,
            requesterId: req.user?.userId || req.user?.id || '',
        });
        res.json(result);
    } catch (err) {
        console.error('[POST /api/stock/adjust] Error:', err);
        // Always return JSON error, never HTML
        res.status(500).json({
            success: false,
            error: err.message || 'Unknown error occurred',
            details: process.env.NODE_ENV === 'development' ? err.stack : undefined
        });
    }
});

// GET /delta-status
router.get('/delta-status', async (req, res) => {
    try {
        const html = await stockCalc.getDeltaStatusHtml();
        res.send(html);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Stock Health & Validation
// GET /health
router.get('/health', async (req, res) => {
    try {
        const cacheKey = '/api/stock/health';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const data = { success: true, ...(await stockCalc.getStockSummary()) };
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error('[Stock Health] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /negative-check
router.get('/negative-check', async (req, res) => {
    try {
        const cacheKey = '/api/stock/negative-check';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const data = { success: true, ...(await stockCalc.detectNegativeStock()) };
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error('[Negative Check] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /validate-sufficiency
router.post('/validate-sufficiency', async (req, res) => {
    try {
        const { type, grade, requiredKgs } = req.body;
        if (!type || !grade || !requiredKgs) {
            return res.status(400).json({ success: false, error: 'Missing type, grade, or requiredKgs' });
        }
        const result = await stockCalc.validateStockSufficiency(type, grade, parseFloat(requiredKgs));
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[Validate Sufficiency] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Stock History
// GET /purchase-history
router.get('/purchase-history', requireAdmin, async (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 100;
        const startDate = req.query.startDate || null;
        const endDate = req.query.endDate || null;
        const result = await stockCalc.getPurchaseHistory(limit, startDate, endDate);
        res.json({ success: true, entries: result });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /adjustment-history
router.get('/adjustment-history', requireAdmin, async (req, res) => {
    try {
        const limit = parseInt(req.query.limit) || 100;
        const startDate = req.query.startDate || null;
        const endDate = req.query.endDate || null;
        const result = await stockCalc.getAdjustmentHistory(limit, startDate, endDate);
        res.json({ success: true, entries: result });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
