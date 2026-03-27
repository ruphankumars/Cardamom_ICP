const express = require('express');
const router = express.Router();

const { requireAdmin } = require('../../../backend/middleware/auth');

// Lazy-load report modules to avoid pdfkit/fontkit init at module load time (ICP WASM compat)
const _lazy = {};
function getReport(name) {
    if (!_lazy[name]) _lazy[name] = require(`../../../backend/reports/${name}`);
    return _lazy[name];
}
const { reportCache, concurrencyLimiter, ReportCache } = require('../../../backend/reports/reportCache');

/**
 * Helper: wrap a report generator with caching, concurrency limiting, and timeout.
 * Returns an Express route handler.
 */
function reportHandler(reportType, generator, contentTypeForFormat, filenameGenerator) {
    return async (req, res) => {
        const params = req.body || {};
        const format = params.format || 'pdf';

        // Check cache first
        const cacheKey = ReportCache.makeKey(reportType, params, format);
        const cached = reportCache.get(cacheKey);
        if (cached) {
            res.setHeader('Content-Type', cached.contentType);
            res.setHeader('Content-Disposition', `attachment; filename="${cached.filename}"`);
            res.setHeader('X-Report-Cache', 'HIT');
            return res.send(cached.buffer);
        }

        // Acquire concurrency slot
        let release;
        try {
            release = await concurrencyLimiter.acquire();
        } catch (err) {
            return res.status(503).json({ success: false, error: 'Report generation queue full. Please try again.' });
        }

        // Set timeout
        const timeout = setTimeout(() => {
            if (!res.headersSent) {
                if (release) release();
                res.status(504).json({ success: false, error: 'Report generation timed out (30s limit)' });
            }
        }, 30000);

        try {
            const buffer = await generator(params);

            clearTimeout(timeout);
            if (res.headersSent) return; // timeout already fired

            const contentType = typeof contentTypeForFormat === 'function'
                ? contentTypeForFormat(format)
                : contentTypeForFormat;
            const filename = typeof filenameGenerator === 'function'
                ? filenameGenerator(params, format)
                : filenameGenerator;

            // Cache the result
            reportCache.set(cacheKey, buffer, contentType, filename);

            res.setHeader('Content-Type', contentType);
            res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
            res.setHeader('X-Report-Cache', 'MISS');
            res.send(buffer);
        } catch (err) {
            clearTimeout(timeout);
            if (!res.headersSent) {
                console.error(`[Reports] ${reportType} error:`, err.message);
                res.status(500).json({ success: false, error: err.message });
            }
        } finally {
            if (release) release();
        }
    };
}

function contentTypeForFormat(format) {
    if (format === 'excel') return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    return 'application/pdf';
}

// Invoice
router.post('/invoice', requireAdmin,
    reportHandler('invoice', (...a) => getReport('invoiceReport').generate(...a), 'application/pdf',
        (params) => `invoice_${Date.now()}.pdf`));

// Dispatch Summary
router.post('/dispatch-summary', requireAdmin,
    reportHandler('dispatch-summary', (...a) => getReport('dispatchReport').generate(...a), 'application/pdf',
        (params) => `dispatch_${params.date || 'summary'}.pdf`));

// Stock Position
router.post('/stock-position', requireAdmin,
    reportHandler('stock-position', (...a) => getReport('stockPositionReport').generate(...a), contentTypeForFormat,
        (params, fmt) => `stock_position.${fmt === 'excel' ? 'xlsx' : 'pdf'}`));

// Stock Movement
router.post('/stock-movement', requireAdmin,
    reportHandler('stock-movement', (...a) => getReport('stockMovementReport').generate(...a),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        (params) => `stock_movement_${params.startDate}_${params.endDate}.xlsx`));

// Client Statement
router.post('/client-statement', requireAdmin,
    reportHandler('client-statement', (...a) => getReport('clientStatementReport').generate(...a), 'application/pdf',
        (params) => `statement_${(params.client || 'client').replace(/\s+/g, '_')}.pdf`));

// Client Statement Bulk (ZIP)
router.post('/client-statement/bulk', requireAdmin,
    reportHandler('client-statement-bulk', (...a) => getReport('clientStatementReport').generateBulk(...a), 'application/zip',
        (params) => `client_statements_${params.startDate}_${params.endDate}.zip`));

// Sales Summary
router.post('/sales-summary', requireAdmin,
    reportHandler('sales-summary', (...a) => getReport('salesSummaryReport').generate(...a), contentTypeForFormat,
        (params, fmt) => `sales_summary_${params.startDate}_${params.endDate}.${fmt === 'excel' ? 'xlsx' : 'pdf'}`));

// Attendance
router.post('/attendance', requireAdmin,
    reportHandler('attendance', (...a) => getReport('attendanceReport').generate(...a),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        (params) => `attendance_${params.month || 'report'}.xlsx`));

// Expenses
router.post('/expenses', requireAdmin,
    reportHandler('expenses', (...a) => getReport('expenseReport').generate(...a),
        (fmt) => fmt === 'monthly' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'application/pdf',
        (params) => params.type === 'monthly' ? `expenses_${params.month}.xlsx` : `expenses_${params.date}.pdf`));

module.exports = router;
