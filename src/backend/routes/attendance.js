const router = require('express').Router();
const workersAttendance = require('../../../backend/firebase/workersAttendance_fb');
const { requireAdmin } = require('../../../backend/middleware/auth');

// Mark attendance via face scan
router.post('/face-mark', async (req, res) => {
    try {
        const result = await workersAttendance.markAttendance(req.body);
        res.json(result);
    } catch (err) {
        console.error('[Face] Face attendance error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get attendance for a date range (wage calculation)
router.get('/range', async (req, res) => {
    try {
        const { dateFrom, dateTo } = req.query;
        if (!dateFrom || !dateTo) return res.status(400).json({ success: false, error: 'dateFrom and dateTo are required' });

        // Generate date strings between dateFrom and dateTo
        const start = new Date(dateFrom);
        const end = new Date(dateTo);
        const allRecords = [];

        for (let d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
            const dateStr = d.toISOString().split('T')[0];
            const dayRecords = await workersAttendance.getAttendanceByDate(dateStr);
            for (const record of dayRecords) {
                const wage = record.finalWage || record.wagePaid || workersAttendance.calculateWage(
                    record.baseDailyWage || 0, record.status, record.otHours || 0
                );
                allRecords.push({ ...record, calculatedWage: wage });
            }
        }

        // Aggregate by worker
        const workerTotals = {};
        for (const r of allRecords) {
            if (!workerTotals[r.workerId]) {
                workerTotals[r.workerId] = { workerId: r.workerId, workerName: r.workerName, totalPay: 0, daysWorked: 0, records: [] };
            }
            workerTotals[r.workerId].totalPay += r.calculatedWage || 0;
            const workStatuses = ['full', 'half_am', 'half_pm', 'ot', 'present', 'half_day', 'half-day', 'overtime'];
            if (workStatuses.includes(r.status)) {
                workerTotals[r.workerId].daysWorked++;
            }
            workerTotals[r.workerId].records.push(r);
        }

        res.json({ success: true, dateFrom, dateTo, workers: Object.values(workerTotals), totalRecords: allRecords.length });
    } catch (err) {
        console.error('[Attendance] Range error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get attendance for a specific date
router.get('/:date', async (req, res) => {
    try {
        const attendance = await workersAttendance.getAttendanceByDate(req.params.date);
        res.json(attendance);
    } catch (err) {
        console.error('[Attendance] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get attendance summary for a date
router.get('/:date/summary', async (req, res) => {
    try {
        const summary = await workersAttendance.getAttendanceSummary(req.params.date);
        res.json(summary);
    } catch (err) {
        console.error('[Attendance] Summary error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Mark attendance
router.post('/', async (req, res) => {
    try {
        const result = await workersAttendance.markAttendance(req.body);
        res.json(result);
    } catch (err) {
        console.error('[Attendance] Mark error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Remove attendance record
router.delete('/:date/:workerId', async (req, res) => {
    try {
        const result = await workersAttendance.removeAttendance(req.params.date, req.params.workerId);
        res.json(result);
    } catch (err) {
        console.error('[Attendance] Remove error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Copy previous day's workers
router.post('/copy-previous', async (req, res) => {
    try {
        const { fromDate, toDate, markedBy } = req.body;
        const result = await workersAttendance.copyPreviousDayWorkers(fromDate, toDate, markedBy);
        res.json(result);
    } catch (err) {
        console.error('[Attendance] Copy error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get calendar data for a month
router.get('/calendar/:year/:month', async (req, res) => {
    try {
        const calendar = await workersAttendance.getAttendanceCalendar(
            parseInt(req.params.year),
            parseInt(req.params.month)
        );
        res.json(calendar);
    } catch (err) {
        console.error('[Attendance] Calendar error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Check if a date's attendance is locked
router.get('/:date/lock-status', async (req, res) => {
    try {
        const lockStatus = workersAttendance.isRecordLocked(req.params.date);
        res.json(lockStatus);
    } catch (err) {
        console.error('[Attendance] Lock status error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
