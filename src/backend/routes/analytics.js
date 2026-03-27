const express = require('express');
const analyticsRouter = express.Router();
const aiRouter = express.Router();

const { requireAdmin, requireSuperAdmin } = require('../../../backend/middleware/auth');

const analytics = require('../../../backend/firebase/analytics_fb');
const predictive = require('../../../backend/firebase/predictive_analytics_fb');
const aiBrain = require('../../../backend/firebase/ai_brain_fb');
const pricing = require('../../../backend/pricing_intelligence');
const audit = require('../../../backend/audit_log');
const featureFlags = require('../../../backend/featureFlags');
const clientRequests = require('../../../backend/firebase/client_requests_fb');
const { getCachedResponse, setCachedResponse } = require('../middleware/apiCache');

// ==================== ANALYTICS ROUTES ====================

// GET /rejected-offers - Query rejected offers with filters
analyticsRouter.get('/rejected-offers', requireAdmin, async (req, res) => {
    try {
        const { clientId, grade, dateFrom, dateTo, limit } = req.query;
        const filters = {};
        if (clientId) filters.clientId = clientId;
        if (grade) filters.grade = grade;
        if (dateFrom) filters.dateFrom = dateFrom;
        if (dateTo) filters.dateTo = dateTo;
        if (limit) filters.limit = Math.max(1, Math.min(parseInt(limit, 10) || 50, 500));

        const offers = await clientRequests.getRejectedOffers(filters);
        res.json({ success: true, offers });
    } catch (err) {
        console.error('[GET /api/analytics/rejected-offers] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /rejected-offers/summary - Aggregated analytics
analyticsRouter.get('/rejected-offers/summary', requireAdmin, async (req, res) => {
    try {
        const { dateFrom, dateTo } = req.query;
        const filters = {};
        if (dateFrom) filters.dateFrom = dateFrom;
        if (dateTo) filters.dateTo = dateTo;

        const analytics = await clientRequests.getRejectedOffersAnalytics(filters);
        res.json({ success: true, analytics });
    } catch (err) {
        console.error('[GET /api/analytics/rejected-offers/summary] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Analytics API - Phase 3 Intelligence Features (superadmin only)
analyticsRouter.get('/stock-forecast', requireSuperAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/analytics/stock-forecast';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await analytics.getStockForecast();
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[Analytics] Stock forecast error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

analyticsRouter.get('/client-scores', requireSuperAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/analytics/client-scores';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await analytics.getClientScores();
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[Analytics] Client scores error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

analyticsRouter.get('/insights', requireSuperAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/analytics/insights';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await analytics.getProactiveInsights();
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[Analytics] Insights error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Predictive Analytics - Phase 4 (superadmin only)
analyticsRouter.get('/demand-trends', requireSuperAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/analytics/demand-trends';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await predictive.getDemandTrends();
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[Predictive] Demand trends error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

analyticsRouter.get('/seasonal-analysis', requireSuperAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/analytics/seasonal-analysis';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await predictive.getSeasonalAnalysis();
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[Predictive] Seasonal analysis error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Product Pricing - Phase 4.2 (superadmin only)
analyticsRouter.get('/suggested-prices', requireSuperAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/analytics/suggested-prices';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await pricing.getSuggestedPrices();
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[Pricing] Suggested prices error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Audit Logs (superadmin only)
analyticsRouter.get('/audit-logs', requireSuperAdmin, async (req, res) => {
    try {
        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await audit.getPaginatedLogs({ limit, cursor });
            return res.json({ success: true, logs: result.data, pagination: result.pagination });
        }
        const logs = await audit.getRecentLogs(Math.max(1, Math.min(parseInt(req.query.limit) || 50, 200)));
        res.json({ success: true, logs });
    } catch (err) {
        console.error('[Audit] Fetch error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== AI ROUTES ====================

// AI Brain - Intelligent Decision Engine (superadmin only)
aiRouter.get('/daily-briefing', requireSuperAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/ai/daily-briefing';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await aiBrain.generateDailyBriefing();
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[AI Brain] Daily briefing error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

aiRouter.get('/grade-analysis/:grade', requireSuperAdmin, async (req, res) => {
    try {
        const { grade } = req.params;
        const cacheKey = `/api/ai/grade-analysis/${grade}`;
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await aiBrain.analyzeGrade(decodeURIComponent(grade));
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[AI Brain] Grade analysis error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

aiRouter.get('/client-analysis/:name', requireSuperAdmin, async (req, res) => {
    try {
        const { name } = req.params;
        const cacheKey = `/api/ai/client-analysis/${name}`;
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await aiBrain.analyzeClient(decodeURIComponent(name));
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[AI Brain] Client analysis error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

aiRouter.get('/recommendations', requireSuperAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/ai/recommendations';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const result = await aiBrain.getAllRecommendations();
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[AI Brain] Recommendations error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = { analyticsRouter, aiRouter };
