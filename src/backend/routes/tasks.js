const router = require('express').Router();
const taskManager = require('../../../backend/firebase/taskManager_fb');
const { requireAdmin } = require('../../../backend/middleware/auth');
const { getCachedResponse, setCachedResponse } = require('../middleware/apiCache');
const featureFlags = require('../../../backend/featureFlags');

// GET /api/tasks -> GET /
router.get('/', async (req, res) => {
    try {
        const cacheKey = '/api/tasks?' + JSON.stringify(req.query);
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        let data;
        const { assigneeId } = req.query;
        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            data = await taskManager.getTasksPaginated({ limit, cursor, assigneeId });
        } else {
            data = await taskManager.getTasks(assigneeId);
        }
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.post('/', requireAdmin, async (req, res) => {
    try {
        const result = await taskManager.createTask(req.body);
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.put('/:id', requireAdmin, async (req, res) => {
    try {
        const result = await taskManager.updateTask(req.params.id, req.body);
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.delete('/:id', requireAdmin, async (req, res) => {
    try {
        const result = await taskManager.deleteTask(req.params.id);
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.get('/stats', async (req, res) => {
    try {
        const cacheKey = '/api/tasks/stats';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const stats = await taskManager.getTaskStats();
        setCachedResponse(cacheKey, stats);
        res.json(stats);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
