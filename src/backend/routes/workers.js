const router = require('express').Router();
const workersAttendance = require('../../../backend/firebase/workersAttendance_fb');
const { requireAdmin } = require('../../../backend/middleware/auth');

// GET /api/workers -> GET /
router.get('/', async (req, res) => {
    try {
        const includeInactive = req.query.includeInactive === 'true';
        const workers = await workersAttendance.getWorkers(includeInactive);
        res.json(workers);
    } catch (err) {
        console.error('[Workers] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Search workers with fuzzy matching
router.get('/search', async (req, res) => {
    try {
        const { q } = req.query;
        if (!q) {
            return res.status(400).json({ success: false, error: 'Query parameter q is required' });
        }
        const result = await workersAttendance.searchWorkers(q);
        res.json(result);
    } catch (err) {
        console.error('[Workers] Search error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get worker teams
router.get('/teams', async (req, res) => {
    try {
        const teams = await workersAttendance.getWorkerTeams();
        res.json(teams);
    } catch (err) {
        console.error('[Workers] Teams error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Add new worker
router.post('/', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.addWorker(req.body);
        res.json(result);
    } catch (err) {
        console.error('[Workers] Add error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Force add worker (skip duplicate check)
router.post('/force', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.forceAddWorker(req.body);
        res.json(result);
    } catch (err) {
        console.error('[Workers] Force add error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Update worker
router.put('/:id', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.updateWorker(req.params.id, req.body);
        res.json(result);
    } catch (err) {
        console.error('[Workers] Update error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete worker (soft delete - marks as Inactive)
router.delete('/:id', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.deleteWorker(req.params.id);
        res.json(result);
    } catch (err) {
        console.error('[Workers] Delete error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ====== FACE ATTENDANCE ROUTES ======

// Get all enrolled face data (for roll call matching)
router.get('/face-data', requireAdmin, async (req, res) => {
    try {
        const data = await workersAttendance.getAllFaceData();
        res.json(data);
    } catch (err) {
        console.error('[Face] Get all face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Store face data for a worker (enrollment)
router.post('/:workerId/face-data', requireAdmin, async (req, res) => {
    try {
        const { faceData } = req.body;
        if (!faceData) return res.status(400).json({ success: false, error: 'faceData is required' });
        const result = await workersAttendance.storeFaceData(req.params.workerId, faceData);
        res.json(result);
    } catch (err) {
        console.error('[Face] Store face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete face data for a worker (admin only)
router.delete('/:workerId/face-data', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.clearFaceData(req.params.workerId);
        res.json(result);
    } catch (err) {
        console.error('[Face] Delete worker face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
