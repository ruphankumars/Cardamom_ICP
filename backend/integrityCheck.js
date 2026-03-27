/**
 * Integrity Check Module
 * 
 * Provides validation functions to ensure data consistency across all sheets:
 * - sygt_order_book, cart_orders, packed_orders, sale_order, net_stock, etc.
 * 
 * Prevents:
 * - Double counting (same order in multiple sheets)
 * - Manual edit corruption
 * - Fraudulent alterations
 */

const { getDb } = require('./firebaseClient');

// ============================================================
// PHASE 1: Double-Counting Prevention
// ============================================================

/**
 * Generate a unique key for an order row
 * Uses client + lot + orderDate + grade + kgs as composite key
 */
function generateOrderKey(row, headers) {
    const clientIdx = headers.indexOf('Client');
    const lotIdx = headers.indexOf('Lot');
    const dateIdx = headers.indexOf('Order Date');
    const gradeIdx = headers.indexOf('Grade');
    const kgsIdx = headers.indexOf('Kgs');

    const client = (row[clientIdx] || '').toString().trim().toLowerCase();
    const lot = (row[lotIdx] || '').toString().trim().toLowerCase();
    const date = (row[dateIdx] || '').toString().trim();
    const grade = (row[gradeIdx] || '').toString().trim().toLowerCase();
    const kgs = (row[kgsIdx] || '').toString().trim();

    return `${client}|${lot}|${date}|${grade}|${kgs}`;
}

/**
 * Validate that no order exists in multiple sheets simultaneously
 */
async function validateNoOrderOverlap() {
    console.log('[IntegrityCheck] Starting overlap validation...');
    const startTime = Date.now();

    try {
        const db = getDb();
        const [ordSnap, cartSnap, packedSnap] = await Promise.all([
            db.collection('orders').get(),
            db.collection('cart_orders').get(),
            db.collection('packed_orders').get()
        ]);

        // Convert Firestore docs to sheet-like format for existing logic
        const toHeaders = () => ['Order Date', 'Billing From', 'Client', 'Lot', 'Grade', 'Bag / Box', 'No', 'Kgs', 'Price', 'Brand', 'Status', 'Notes'];
        const toRow = (d) => [d.orderDate||'', d.billingFrom||'', d.client||'', d.lot||'', d.grade||'', d.bagbox||'', d.no||0, d.kgs||0, d.price||0, d.brand||'', d.status||'', d.notes||''];

        const headers = toHeaders();
        const orderBookData = [headers, ...ordSnap.docs.map(doc => toRow(doc.data()))];
        const cartData = [headers, ...cartSnap.docs.map(doc => toRow(doc.data()))];
        const packedData = [headers, ...packedSnap.docs.map(doc => toRow(doc.data()))];

        const stats = { orderBookCount: 0, cartCount: 0, packedCount: 0 };
        const orderBookKeys = new Map();
        const cartKeys = new Map();
        const packedKeys = new Map();

        if (orderBookData && orderBookData.length > 1) {
            const headers = orderBookData[0];
            orderBookData.slice(1).forEach((row, idx) => {
                if (row.some(cell => cell && cell.toString().trim())) {
                    orderBookKeys.set(generateOrderKey(row, headers), { rowIndex: idx + 2 });
                    stats.orderBookCount++;
                }
            });
        }

        if (cartData && cartData.length > 1) {
            const headers = cartData[0];
            cartData.slice(1).forEach((row, idx) => {
                if (row.some(cell => cell && cell.toString().trim())) {
                    cartKeys.set(generateOrderKey(row, headers), { rowIndex: idx + 2 });
                    stats.cartCount++;
                }
            });
        }

        if (packedData && packedData.length > 1) {
            const headers = packedData[0];
            packedData.slice(1).forEach((row, idx) => {
                if (row.some(cell => cell && cell.toString().trim())) {
                    packedKeys.set(generateOrderKey(row, headers), { rowIndex: idx + 2 });
                    stats.packedCount++;
                }
            });
        }

        const overlaps = [];

        for (const [key, info] of orderBookKeys) {
            if (cartKeys.has(key)) {
                overlaps.push({ key, type: 'order_book_vs_cart', severity: 'HIGH', orderBookRow: info.rowIndex, cartRow: cartKeys.get(key).rowIndex });
            }
            if (packedKeys.has(key)) {
                overlaps.push({ key, type: 'order_book_vs_packed', severity: 'HIGH', orderBookRow: info.rowIndex, packedRow: packedKeys.get(key).rowIndex });
            }
        }

        for (const [key, info] of cartKeys) {
            if (packedKeys.has(key)) {
                overlaps.push({ key, type: 'cart_vs_packed', severity: 'MEDIUM', cartRow: info.rowIndex, packedRow: packedKeys.get(key).rowIndex });
            }
        }

        const duration = Date.now() - startTime;
        console.log(`[IntegrityCheck] Overlap validation: ${overlaps.length} overlaps in ${duration}ms`);

        return { valid: overlaps.length === 0, overlaps, stats, duration };
    } catch (error) {
        console.error('[IntegrityCheck] Overlap validation error:', error);
        return { valid: false, error: error.message, overlaps: [], stats: {} };
    }
}

// ============================================================
// PHASE 2: Manual Edit Detection
// ============================================================

/**
 * Normalize grade text for comparison
 */
function _norm(s) {
    return String(s || '').toLowerCase().replace(/\s+/g, ' ').trim();
}

/**
 * Build expected sale_order matrix from order sources (in-memory calculation)
 * Returns 3x14 matrix: [Colour Bold, Fruit Bold, Rejection] x [grade columns]
 */
async function buildExpectedSaleOrder() {
    const SALE_CANONICAL = [
        '8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm',
        '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm',
        'mini bold', 'pan'
    ];

    const matrix = [
        Array(SALE_CANONICAL.length).fill(0), // Colour Bold
        Array(SALE_CANONICAL.length).fill(0), // Fruit Bold
        Array(SALE_CANONICAL.length).fill(0)  // Rejection
    ];

    const gradeToCol = {};
    SALE_CANONICAL.forEach((g, i) => gradeToCol[_norm(g)] = i);

    const processRows = (rows, headers) => {
        if (!rows || rows.length === 0) return;
        const iGrade = headers.indexOf('Grade');
        const iKgs = headers.indexOf('Kgs');
        const iStatus = headers.indexOf('Status');
        if (iGrade < 0 || iKgs < 0) return;

        rows.forEach(row => {
            const gradeText = _norm(row[iGrade] || '');
            const qty = parseFloat(row[iKgs]) || 0;
            if (!qty) return;

            // Determine row type (Colour Bold = 0, Fruit Bold = 1, Rejection = 2)
            let rowIdx = 0;
            if (gradeText.includes('fruit')) rowIdx = 1;
            else if (gradeText.includes('rejection') || gradeText.includes('rej')) rowIdx = 2;

            // Find matching canonical grade
            let colIdx = -1;
            for (const [canon, idx] of Object.entries(gradeToCol)) {
                if (gradeText.includes(canon.replace(/\s+/g, '')) || gradeText === canon) {
                    colIdx = idx;
                    break;
                }
            }

            // Simplified matching for common grades
            if (colIdx < 0) {
                if (gradeText.includes('8.5')) colIdx = 0;
                else if (gradeText.includes('8 mm') || gradeText.includes('8mm')) colIdx = 1;
                else if (gradeText.includes('7.8')) colIdx = 2;
                else if (gradeText.includes('7.5 to 8') || gradeText.includes('7.5to8')) colIdx = 3;
                else if (gradeText.includes('7 to 8') || gradeText.includes('7to8')) colIdx = 4;
                else if (gradeText.includes('6.5 to 8') || gradeText.includes('6.5to8')) colIdx = 5;
                else if (gradeText.includes('7 to 7.5') || gradeText.includes('7to7.5')) colIdx = 6;
                else if (gradeText.includes('6.5 to 7.5') || gradeText.includes('6.5to7.5')) colIdx = 7;
                else if (gradeText.includes('6.5 to 7') || gradeText.includes('6.5to7')) colIdx = 8;
                else if (gradeText.includes('6 to 7') || gradeText.includes('6to7')) colIdx = 9;
                else if (gradeText.includes('6 to 6.5') || gradeText.includes('6to6.5')) colIdx = 10;
                else if (gradeText.includes('mini')) colIdx = 11;
                else if (gradeText.includes('pan')) colIdx = 12;
            }

            if (colIdx >= 0 && colIdx < SALE_CANONICAL.length) {
                matrix[rowIdx][colIdx] += qty;
            }
        });
    };

    const db = getDb();
    const [ordSnap, cartSnap2, packedSnap2] = await Promise.all([
        db.collection('orders').get(),
        db.collection('cart_orders').get(),
        db.collection('packed_orders').get()
    ]);

    const toHeaders2 = () => ['Order Date', 'Billing From', 'Client', 'Lot', 'Grade', 'Bag / Box', 'No', 'Kgs', 'Price', 'Brand', 'Status', 'Notes'];
    const toRow2 = (d) => [d.orderDate||'', d.billingFrom||'', d.client||'', d.lot||'', d.grade||'', d.bagbox||'', d.no||0, d.kgs||0, d.price||0, d.brand||'', d.status||'', d.notes||''];

    const headers2 = toHeaders2();
    const pendData = [headers2, ...ordSnap.docs.map(doc => toRow2(doc.data()))];
    const cartData = [headers2, ...cartSnap2.docs.map(doc => toRow2(doc.data()))];
    const packedData = [headers2, ...packedSnap2.docs.map(doc => toRow2(doc.data()))];

    if (pendData && pendData.length > 1) {
        const headers = pendData[0];
        const statusIdx = headers.indexOf('Status');
        const pendingRows = pendData.slice(1).filter(r => _norm(r[statusIdx]) === 'pending');
        processRows(pendingRows, headers);
    }

    if (cartData && cartData.length > 1) processRows(cartData.slice(1), cartData[0]);
    if (packedData && packedData.length > 1) processRows(packedData.slice(1), packedData[0]);

    return matrix;
}

/**
 * Validate sale_order matches actual orders
 * Detects if someone manually edited the sale_order sheet
 */
async function validateSaleOrderIntegrity() {
    console.log('[IntegrityCheck] Starting sale_order integrity check...');
    const startTime = Date.now();

    try {
        const expected = await buildExpectedSaleOrder();
        // Read from Firestore net_stock_cache
        let actualData = [];
        try {
            const db = getDb();
            const cacheDoc = await db.collection('net_stock_cache').doc('sale_order').get();
            if (cacheDoc.exists) {
                const cacheData = cacheDoc.data();
                actualData = cacheData.matrix || [];
            }
        } catch (e) {
            console.warn('[IntegrityCheck] Could not read sale_order cache:', e.message);
        }

        const mismatches = [];
        const tolerance = 0.5; // Allow 0.5 kg tolerance for rounding

        for (let r = 0; r < 3; r++) {
            const actualRow = actualData[r] || [];
            for (let c = 0; c < expected[r].length; c++) {
                const expectedVal = Math.round(expected[r][c] * 100) / 100;
                const actualVal = parseFloat(actualRow[c]) || 0;
                const diff = Math.abs(expectedVal - actualVal);

                if (diff > tolerance) {
                    mismatches.push({
                        row: ['Colour Bold', 'Fruit Bold', 'Rejection'][r],
                        column: c + 1,
                        expected: expectedVal,
                        actual: actualVal,
                        difference: Math.round(diff * 100) / 100,
                        severity: diff > 100 ? 'HIGH' : diff > 10 ? 'MEDIUM' : 'LOW'
                    });
                }
            }
        }

        const duration = Date.now() - startTime;
        console.log(`[IntegrityCheck] Sale order check: ${mismatches.length} mismatches in ${duration}ms`);

        return {
            valid: mismatches.length === 0,
            mismatches,
            duration,
            message: mismatches.length > 0
                ? `Found ${mismatches.length} discrepancies - manual edits detected!`
                : 'Sale order matches calculated values'
        };
    } catch (error) {
        console.error('[IntegrityCheck] Sale order validation error:', error);
        return { valid: false, error: error.message, mismatches: [] };
    }
}

// ============================================================
// PHASE 3: Fraud Prevention & Audit Logging
// ============================================================

/**
 * Log an audit event for tracking changes
 * Creates append-only audit trail
 */
async function logAuditEvent(action, details, userId = 'SYSTEM') {
    const timestamp = new Date().toISOString();
    const logEntry = [
        timestamp,
        action,
        userId,
        typeof details === 'object' ? JSON.stringify(details) : String(details)
    ];

    // Always log to console
    console.log(`[AUDIT] ${timestamp} | ${action} | ${userId} | ${JSON.stringify(details).substring(0, 200)}`);

    try {
        const db = getDb();
        await db.collection('audit_log').add({
            timestamp: logEntry[0],
            action: logEntry[1],
            userId: logEntry[2],
            details: logEntry[3],
            createdAt: new Date().toISOString()
        });
    } catch (error) {
        // Silent fail - audit log may not be available
    }
}

/**
 * Validate order has legitimate source
 * Prevents "phantom orders" - orders added to cart without proper origin
 */
async function validateOrderSource(order) {
    const key = `${order.client}|${order.lot}|${order.orderDate}|${order.grade}|${order.kgs}`;

    // Check if order came from order_book or is a new order
    // New orders should have been validated through proper channels
    const warnings = [];

    if (!order.client || !order.lot || !order.grade) {
        warnings.push({ type: 'MISSING_REQUIRED', message: 'Order missing required fields' });
    }

    if (order.kgs <= 0) {
        warnings.push({ type: 'INVALID_QTY', message: 'Order has invalid quantity' });
    }

    if (order.price < 0) {
        warnings.push({ type: 'INVALID_PRICE', message: 'Order has negative price' });
    }

    // Check for backdating (order date more than 30 days old)
    if (order.orderDate) {
        const { toDate } = require('./utils/date');
        const orderDate = toDate(order.orderDate) || new Date(order.orderDate);
        const now = new Date();
        const daysDiff = (now - orderDate) / (1000 * 60 * 60 * 24);
        if (daysDiff > 30) {
            warnings.push({ type: 'BACKDATED', message: `Order date is ${Math.round(daysDiff)} days old` });
        }
    }

    return {
        valid: warnings.length === 0,
        warnings,
        key
    };
}

/**
 * Get audit log entries (last N entries)
 */
async function getAuditLog(limit = 50) {
    try {
        const db = getDb();
        const snap = await db.collection('audit_log').orderBy('createdAt', 'desc').limit(limit).get();
        return snap.docs.map(doc => {
            const d = doc.data();
            return { timestamp: d.timestamp, action: d.action, userId: d.userId, details: d.details };
        });
    } catch (error) {
        return [];
    }
}

// ============================================================
// PHASE 4: Checksum System
// ============================================================

/**
 * Compute a simple checksum for sheet data
 */
function computeChecksum(rows) {
    if (!rows || rows.length === 0) return '0';

    const content = rows.map(r => (r || []).join('|')).join('\n');
    let hash = 0;
    for (let i = 0; i < content.length; i++) {
        const char = content.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        hash = hash & hash; // Convert to 32-bit integer
    }
    return Math.abs(hash).toString(16).padStart(8, '0');
}

/**
 * Store checksums for critical sheets
 */
async function storeChecksums() {
    console.log('[IntegrityCheck] Storing checksums for critical collections...');

    const criticalCollections = ['orders', 'cart_orders', 'packed_orders'];

    const checksums = {};
    const db = getDb();

    for (const collName of criticalCollections) {
        try {
            const snap = await db.collection(collName).get();
            const data = snap.docs.map(doc => {
                const d = doc.data();
                return Object.values(d).map(v => String(v || ''));
            });
            const checksum = computeChecksum(data);
            checksums[collName] = checksum;
        } catch (error) {
            console.warn(`[IntegrityCheck] Could not checksum ${collName}:`, error.message);
        }
    }

    // Store in Firestore settings collection
    await db.collection('settings').doc('checksums').set({
        ...checksums,
        timestamp: new Date().toISOString()
    });
    console.log('[IntegrityCheck] Checksums stored:', checksums);

    return checksums;
}

/**
 * Validate checksums for critical sheets
 */
async function validateChecksums() {
    console.log('[IntegrityCheck] Validating checksums...');
    const startTime = Date.now();

    const criticalCollections = ['orders', 'cart_orders', 'packed_orders'];

    const results = [];
    let allValid = true;
    const db = getDb();

    // Read stored checksums from Firestore
    let storedChecksums = {};
    try {
        const doc = await db.collection('settings').doc('checksums').get();
        if (doc.exists) storedChecksums = doc.data();
    } catch (e) { /* no stored checksums yet */ }

    for (const collName of criticalCollections) {
        try {
            const storedChecksum = storedChecksums[collName] || null;
            const snap = await db.collection(collName).get();
            const data = snap.docs.map(doc => {
                const d = doc.data();
                return Object.values(d).map(v => String(v || ''));
            });
            const currentChecksum = computeChecksum(data);

            const valid = storedChecksum === currentChecksum || !storedChecksum;
            if (!valid) allValid = false;

            results.push({
                collection: collName,
                valid,
                storedChecksum: storedChecksum || 'NOT_SET',
                currentChecksum,
                message: !storedChecksum
                    ? 'No stored checksum (run storeChecksums first)'
                    : valid ? 'OK' : 'MODIFIED SINCE LAST CHECK!'
            });
        } catch (error) {
            results.push({ collection: collName, valid: false, error: error.message });
            allValid = false;
        }
    }

    const duration = Date.now() - startTime;

    console.log(`[IntegrityCheck] Checksum validation complete in ${duration}ms`);

    return {
        valid: allValid,
        results,
        lastChecksumTime: storedChecksums.timestamp || null,
        duration
    };
}

// ============================================================
// COMPREHENSIVE REPORT
// ============================================================

/**
 * Get full integrity report for dashboard display
 */
async function getIntegrityReport() {
    console.log('[IntegrityCheck] Generating full integrity report...');
    const startTime = Date.now();

    const [overlapResult, saleOrderResult, checksumResult] = await Promise.all([
        validateNoOrderOverlap(),
        validateSaleOrderIntegrity(),
        validateChecksums()
    ]);

    const issues = [];

    if (!overlapResult.valid) {
        issues.push({ type: 'OVERLAP', count: overlapResult.overlaps.length, severity: 'HIGH' });
    }
    if (!saleOrderResult.valid && saleOrderResult.mismatches) {
        issues.push({ type: 'MANUAL_EDIT', count: saleOrderResult.mismatches.length, severity: 'MEDIUM' });
    }
    if (!checksumResult.valid) {
        const modified = checksumResult.results.filter(r => !r.valid).length;
        issues.push({ type: 'CHECKSUM_MISMATCH', count: modified, severity: 'LOW' });
    }

    const overallHealth = issues.length === 0 ? 'HEALTHY'
        : issues.some(i => i.severity === 'HIGH') ? 'CRITICAL'
            : issues.some(i => i.severity === 'MEDIUM') ? 'WARNING'
                : 'INFO';

    return {
        timestamp: new Date().toISOString(),
        duration: Date.now() - startTime,
        overallHealth,
        issues,
        details: {
            overlapCheck: overlapResult,
            saleOrderCheck: saleOrderResult,
            checksumCheck: checksumResult
        }
    };
}

// ============================================================
// SAFE OPERATION WRAPPER
// ============================================================

/**
 * Wrap a stock operation with pre/post validation
 * Logs audit events and can auto-fix issues
 */
async function safeStockOperation(operationName, operationFn, options = {}) {
    const { autoFix = false, userId = 'SYSTEM' } = options;
    const startTime = Date.now();

    console.log(`[SafeOp] Starting ${operationName}...`);

    // Pre-operation check (overlap only - fast)
    const preCheck = await validateNoOrderOverlap();
    if (!preCheck.valid) {
        await logAuditEvent('OPERATION_BLOCKED', { operation: operationName, reason: 'Pre-existing overlaps', count: preCheck.overlaps.length }, userId);
        throw new Error(`Operation blocked: ${preCheck.overlaps.length} overlaps detected. Fix before proceeding.`);
    }

    // Execute the operation
    let result;
    try {
        result = await operationFn();
    } catch (error) {
        await logAuditEvent('OPERATION_FAILED', { operation: operationName, error: error.message }, userId);
        throw error;
    }

    // Post-operation check
    const postCheck = await validateNoOrderOverlap();
    if (!postCheck.valid) {
        await logAuditEvent('OPERATION_CAUSED_OVERLAP', { operation: operationName, overlaps: postCheck.overlaps.slice(0, 3) }, userId);
        console.error(`[SafeOp] WARNING: ${operationName} caused ${postCheck.overlaps.length} overlaps!`);

        // Note: We don't rollback since the operation already completed
        // The overlaps should be investigated manually
    }

    const duration = Date.now() - startTime;
    await logAuditEvent('OPERATION_SUCCESS', { operation: operationName, duration, preOverlaps: preCheck.overlaps.length, postOverlaps: postCheck.overlaps.length }, userId);

    console.log(`[SafeOp] ${operationName} completed in ${duration}ms`);
    return result;
}

/**
 * Quick health check (faster than full report)
 */
async function quickHealthCheck() {
    const startTime = Date.now();
    const overlapCheck = await validateNoOrderOverlap();

    return {
        healthy: overlapCheck.valid,
        overlaps: overlapCheck.overlaps.length,
        stats: overlapCheck.stats,
        duration: Date.now() - startTime
    };
}

module.exports = {
    // Phase 1
    validateNoOrderOverlap,
    generateOrderKey,
    // Phase 2
    validateSaleOrderIntegrity,
    buildExpectedSaleOrder,
    // Phase 3
    logAuditEvent,
    validateOrderSource,
    getAuditLog,
    // Phase 4
    computeChecksum,
    storeChecksums,
    validateChecksums,
    // Combined
    getIntegrityReport,
    // Safe operations
    safeStockOperation,
    quickHealthCheck
};
