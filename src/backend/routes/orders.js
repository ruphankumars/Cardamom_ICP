const router = require('express').Router();
const orderBook = require('../../../backend/firebase/orderBook_fb');
const stockCalc = require('../../../backend/firebase/stock_fb');
const pushNotifications = require('../../../backend/firebase/push_notifications_fb');
const transportAssignments = require('../../../backend/firebase/transport_assignments_fb');
const packedBoxes = require('../../../backend/firebase/packed_boxes_fb');
const audit = require('../../../backend/audit_log');
const featureFlags = require('../../../backend/featureFlags');
const clientContactsFb = require('../../../backend/firebase/client_contacts_fb');
const syncFb = require('../../../backend/firebase/sync_fb');
const { requireAdmin, requireSuperAdmin, requirePageAccess } = require('../../../backend/middleware/auth');
const { getCachedResponse, setCachedResponse } = require('../middleware/apiCache');

// ============================================================================
// ORDER ROUTES
// Auth middleware (authenticateToken) is applied at mount time in index.ts.
// EXCEPTION: GET /dropdowns is PUBLIC — needs auth exemption at the router
// mount level. See comment on that route below.
// ============================================================================

// GET / — List orders (filtered, paginated, or all)
router.get('/', async (req, res) => {
    try {
        const cacheKey = '/api/orders?' + JSON.stringify(req.query);
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        let data;

        // Server-side filtered query — used by View Orders screen
        const hasFilters = req.query.status || req.query.client || req.query.billing || req.query.grade;
        if (hasFilters) {
            data = await orderBook.getFilteredOrders({
                status: req.query.status || '',
                client: req.query.client || '',
                billing: req.query.billing || '',
                grade: req.query.grade || '',
            });
        } else if (req.query.all === 'true' || !featureFlags.usePagination()) {
            // Full unfiltered load (backward compatible)
            data = await orderBook.getSortedOrders();
        } else {
            // Paginated query
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const sortBy = req.query.sortBy || 'orderDate';
            const sortDir = req.query.sortDir || 'desc';
            data = await orderBook.getPaginatedOrders({ limit, cursor, sortBy, sortDir });
        }
        setCachedResponse(cacheKey, data);
        return res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST / — Create a single order
router.post('/', async (req, res) => {
    try {
        // Non-admin users must go through approval workflow
        const userRole = req.user.role?.toLowerCase();
        if (userRole !== 'admin' && userRole !== 'superadmin') {
            return res.status(403).json({
                success: false,
                error: 'Non-admin users must submit orders through the approval workflow'
            });
        }

        const result = await orderBook.addOrder(req.body);
        // Audit log for order creation
        await audit.logAction(req.user.username || 'Unknown', 'CREATE', 'Order', { orderData: req.body });
        // Push notification to other admins (fire-and-forget)
        pushNotifications.notifyNewOrders(req.user.id, req.user.username || 'Admin', [req.body])
            .catch(err => console.error('[FCM] Push error:', err.message));
        // Mandatory WhatsApp: notify client + dad on every new order
        _sendOrderWhatsApp([req.body]).catch(err =>
            console.error('[WhatsApp] Server-side auto-send failed (non-fatal):', err.message)
        );
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /batch — Create multiple orders at once
router.post('/batch', async (req, res) => {
    try {
        // Non-admin users must go through approval workflow for bulk operations
        const userRole = req.user.role?.toLowerCase();
        if (userRole !== 'admin' && userRole !== 'superadmin') {
            return res.status(403).json({
                success: false,
                error: 'Non-admin users must submit batch orders through the approval workflow'
            });
        }

        // Accept both raw array and {orders: [...]} (offline queue wraps in Map)
        const rawBody = req.body;
        const orders = Array.isArray(rawBody) ? rawBody : (Array.isArray(rawBody?.orders) ? rawBody.orders : null);
        if (!orders) return res.status(400).json({ success: false, error: 'Request body must be an array of orders' });
        const result = await orderBook.addOrders(orders);

        // Audit log for batch order creation
        await audit.logAction(req.user.username || 'Unknown', 'BULK_CREATE', `Orders (${orders.length} items)`, { itemCount: orders.length });
        // Push notification to other admins (fire-and-forget)
        pushNotifications.notifyNewOrders(req.user.id, req.user.username || 'Admin', orders)
            .catch(err => console.error('[FCM] Push error:', err.message));

        // Mandatory WhatsApp: notify client + dad on every new order
        if (orders.length > 0 && (!result.skipped || result.skipped < orders.length)) {
            _sendOrderWhatsApp(orders).catch(err =>
                console.error('[WhatsApp] Server-side auto-send failed (non-fatal):', err.message)
            );
        }

        // Invalidate sync cache so other clients see new orders
        syncFb.invalidateSyncCache(['orders']);

        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// PUT /packed/:docId — Update packed date on a billed order (superadmin only)
router.put('/packed/:docId', async (req, res) => {
    if (req.user.role?.toLowerCase() !== 'superadmin') {
        return res.status(403).json({ success: false, error: 'Superadmin access required' });
    }
    try {
        const docId = req.params.docId;
        const result = await orderBook.updatePackedOrder(docId, req.body);
        const action = req.body.status && req.body.status.toLowerCase() !== 'billed' ? 'UPDATE_BILLED_STATUS' : 'UPDATE_BILLED_ORDER';
        await audit.logAction(req.user.username || 'Unknown', action, `Packed order ${docId}`, req.body);
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// PUT /:rowIndex — Update an order
router.put('/:rowIndex', requireAdmin, requirePageAccess('edit_orders'), async (req, res) => {
    try {
        const docId = req.params.rowIndex; // Firestore document ID (string)
        const result = await orderBook.updateOrder(docId, { ...req.body, updatedBy: req.user.username });
        // Audit log for order update
        await audit.logAction(req.user.username || 'Unknown', 'UPDATE', `Order ${docId}`, { changedData: req.body });
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// DELETE /:rowIndex — Delete an order
router.delete('/:rowIndex', requireAdmin, requirePageAccess('delete_orders'), async (req, res) => {
    try {
        const docId = req.params.rowIndex; // Firestore document ID (string)
        // Phase 4.3: Audit Logging for Order Deletion
        const deleteResult = await orderBook.deleteOrder(docId);
        await audit.logAction(req.user.username || 'Unknown', 'DELETE', `Order ${docId}`, { orderData: deleteResult.deletedRow });
        res.json({ success: true });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /deduplicate — Find and remove duplicate packed/billed orders
router.post('/deduplicate', requireAdmin, async (req, res) => {
    try {
        const dryRun = req.body.dryRun !== false; // Default to dry run (safe)
        const result = await orderBook.deduplicatePackedOrders(dryRun);
        console.log(`[Deduplicate] ${result.duplicatesFound} duplicates found, ${result.removed} removed (dryRun: ${dryRun})`);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[Deduplicate] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============================================================================
// INTELLIGENT ORDER FLAGGING
// ============================================================================

// GET /similar — Get similar previous orders for comparison
router.get('/similar', async (req, res) => {
    try {
        const { client, grade, limit = 5 } = req.query;
        if (!client || !grade) {
            return res.status(400).json({ success: false, error: 'client and grade are required' });
        }

        // Get recent orders for this client+grade combination
        const allOrders = await orderBook.getOrders();
        const similarOrders = allOrders
            .filter(o => o.client === client && o.grade === grade && o.status !== 'Cancelled')
            .sort((a, b) => new Date(b.orderDate || 0) - new Date(a.orderDate || 0))
            .slice(0, parseInt(limit, 10));

        res.json({ success: true, orders: similarOrders });
    } catch (err) {
        console.error('[GET /api/orders/similar] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /check-drift — Check for price/qty drift against recent orders
router.post('/check-drift', async (req, res) => {
    try {
        const { client, grade, price, kgs } = req.body;
        if (!client || !grade || price === undefined) {
            return res.status(400).json({ success: false, error: 'client, grade, and price are required' });
        }

        // Get similar orders
        const allOrders = await orderBook.getOrders();
        const similarOrders = allOrders
            .filter(o => o.client === client && o.grade === grade && o.status !== 'Cancelled' && o.price > 0)
            .sort((a, b) => new Date(b.orderDate || 0) - new Date(a.orderDate || 0))
            .slice(0, 5);

        if (similarOrders.length === 0) {
            return res.json({ success: true, flags: [], avgPrice: null, avgKgs: null });
        }

        // Calculate averages
        const avgPrice = similarOrders.reduce((sum, o) => sum + (o.price || 0), 0) / similarOrders.length;
        const avgKgs = similarOrders.reduce((sum, o) => sum + (o.kgs || 0), 0) / similarOrders.length;

        const flags = [];
        const priceDeviation = Math.abs(price - avgPrice) / avgPrice * 100;

        // Flag if price deviates more than 15% from average
        if (priceDeviation > 15) {
            const direction = price > avgPrice ? 'higher' : 'lower';
            flags.push({
                type: 'PRICE_DRIFT',
                severity: priceDeviation > 30 ? 'HIGH' : 'MEDIUM',
                message: `Price ₹${price} is ${priceDeviation.toFixed(1)}% ${direction} than recent avg ₹${avgPrice.toFixed(0)}`
            });
        }

        // Flag if quantity deviates more than 50% from average
        if (kgs && avgKgs > 0) {
            const kgsDeviation = Math.abs(kgs - avgKgs) / avgKgs * 100;
            if (kgsDeviation > 50) {
                const direction = kgs > avgKgs ? 'higher' : 'lower';
                flags.push({
                    type: 'QTY_DRIFT',
                    severity: kgsDeviation > 100 ? 'HIGH' : 'MEDIUM',
                    message: `Quantity ${kgs}kg is ${kgsDeviation.toFixed(0)}% ${direction} than recent avg ${avgKgs.toFixed(0)}kg`
                });
            }
        }

        res.json({
            success: true,
            flags,
            avgPrice: avgPrice.toFixed(2),
            avgKgs: avgKgs.toFixed(2),
            recentOrderCount: similarOrders.length
        });
    } catch (err) {
        console.error('[POST /api/orders/check-drift] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /dropdowns — PUBLIC route (no auth required)
// NOTE: This route needs auth exemption in index.ts. When mounting this router
// behind authenticateToken, /dropdowns must be excluded from auth middleware.
router.get('/dropdowns', async (req, res) => {
    try {
        const { dropdownCache } = require('../../../backend/utils/cache');
        const cacheKey = 'dropdown:all';
        let data = dropdownCache.get(cacheKey);
        if (!data) {
            data = await orderBook.getDropdownOptions();
            dropdownCache.set(cacheKey, data);
        }

        // ETag support for conditional requests
        const crypto = require('crypto');
        const etag = crypto.createHash('md5').update(JSON.stringify(data)).digest('hex');
        res.setHeader('ETag', `"${etag}"`);
        if (req.headers['if-none-match'] === `"${etag}"`) {
            return res.status(304).end();
        }

        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /next-lot — Get next lot number for a client
router.get('/next-lot', async (req, res) => {
    try {
        const { client } = req.query;
        if (!client) {
            return res.status(400).json({ success: false, error: 'client parameter is required' });
        }
        const data = await orderBook.getNextLotNumber(client);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /ledger-clients — Get list of clients with ledger data
router.get('/ledger-clients', async (req, res) => {
    try {
        const cacheKey = '/api/orders/ledger-clients';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);

        const data = await orderBook.getLedgerClients();
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error('[ledger-clients]', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /client-summary — Get order summary for a specific client
router.get('/client-summary', async (req, res) => {
    try {
        const { clientName } = req.query;
        if (!clientName) {
            return res.status(400).json({ success: false, error: 'clientName parameter is required' });
        }
        const data = await orderBook.getClientOrders(clientName);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /sales-summary — Aggregated sales summary with filters
router.get('/sales-summary', async (req, res) => {
    try {
        const cacheKey = '/api/orders/sales-summary' + JSON.stringify(req.query);
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const filters = {};
        if (req.query.status) filters.status = req.query.status;
        if (req.query.client) filters.client = req.query.client;
        if (req.query.date) filters.date = req.query.date;
        if (req.query.billingFrom || req.query.billing) filters.billing = req.query.billingFrom || req.query.billing;
        // Support date range filtering from web (startDate/endDate)
        if (req.query.startDate) filters.startDate = req.query.startDate;
        if (req.query.endDate) filters.endDate = req.query.endDate;
        const data = await orderBook.getSalesSummary(filters);
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /by-grade — Get orders filtered by grade
router.get('/by-grade', async (req, res) => {
    try {
        const grade = req.query.grade;
        if (!grade) return res.status(400).json({ success: false, error: 'grade parameter is required' });
        const cacheKey = '/api/orders/by-grade?' + JSON.stringify(req.query);
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const filters = {};
        if (req.query.status) filters.status = req.query.status;
        if (req.query.client) filters.client = req.query.client;
        if (req.query.date) filters.date = req.query.date;
        if (req.query.billingFrom || req.query.billing) filters.billing = req.query.billingFrom || req.query.billing;
        const data = await orderBook.getOrdersByGrade(grade, filters);
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /pending — Get pending orders
router.get('/pending', async (req, res) => {
    try {
        const cacheKey = '/api/orders/pending';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const data = await orderBook.getPendingOrders();
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /today-cart — Get today's cart (packed orders for today)
router.get('/today-cart', async (req, res) => {
    try {
        const cacheKey = '/api/orders/today-cart';
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const data = await orderBook.getTodayCart();
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /add-to-cart — Add selected orders to daily cart
router.post('/add-to-cart', requireAdmin, async (req, res) => {
    try {
        const { selectedOrders, cartDate, markBilled } = req.body;
        await orderBook.addToDailyCart(selectedOrders, cartDate, markBilled);
        // Audit log for adding orders to cart
        await audit.logAction(req.user.username || 'Unknown', 'ADD_TO_CART', `Added ${selectedOrders?.length || 0} orders to cart`, { itemCount: selectedOrders?.length || 0 });
        res.json({ success: true });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /remove-from-cart — Remove a single order from packed orders
router.post('/remove-from-cart', requireAdmin, async (req, res) => {
    const { lot, client, billingFrom, docId } = req.body;
    try {
        const result = await orderBook.removeFromPackedOrders(lot, client, billingFrom, docId);
        // Audit log for removing order from cart
        await audit.logAction(req.user.username || 'Unknown', 'REMOVE_FROM_CART', `Removed order (Lot: ${lot}, Client: ${client})`, { lot, client, billingFrom });
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /batch-remove-from-cart — Bulk remove orders from packed orders
router.post('/batch-remove-from-cart', requireAdmin, async (req, res) => {
    try {
        const { items } = req.body;
        const result = await orderBook.batchRemoveFromPackedOrders(items);
        // Audit log for bulk delete operation
        await audit.logAction(req.user.username || 'Unknown', 'BULK_DELETE', `Removed ${items?.length || 0} orders from cart`, { itemCount: items?.length || 0 });
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /archive-cart — Archive cart orders to packed orders
router.post('/archive-cart', requireAdmin, async (req, res) => {
    try {
        const { targetDate } = req.body;
        const result = await orderBook.archiveCartToPackedOrders(targetDate);
        // Audit log for archiving cart orders
        await audit.logAction(req.user.username || 'Unknown', 'ARCHIVE_CART', `Archived cart orders for ${targetDate || 'today'}`, { targetDate });
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ========== Transport Assignments (daily client -> transport mapping) ==========

// GET /transport-assignments — Get transport assignments for a date
router.get('/transport-assignments', async (req, res) => {
    try {
        const { date } = req.query;
        if (!date) return res.status(400).json({ success: false, error: 'date parameter is required (YYYY-MM-DD)' });
        const assignments = await transportAssignments.getAssignments(date);
        res.json({ success: true, assignments });
    } catch (err) {
        console.error('[GET /api/orders/transport-assignments]', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// PUT /transport-assignments — Save transport assignments for a date
// NOTE: Socket.IO emit removed (not available on ICP)
router.put('/transport-assignments', async (req, res) => {
    try {
        const { date, assignments, removals } = req.body;
        if (!date || !assignments) {
            return res.status(400).json({ success: false, error: 'date and assignments are required' });
        }
        if (typeof assignments !== 'object' || assignments === null || Array.isArray(assignments)) {
            return res.status(400).json({ success: false, error: 'assignments must be a non-null object (not an array)' });
        }
        if (removals !== undefined && !Array.isArray(removals)) {
            return res.status(400).json({ success: false, error: 'removals must be an array if provided' });
        }
        const username = req.user?.username || 'unknown';
        await transportAssignments.saveAssignments(date, assignments, username, removals || []);
        // Socket.IO broadcast removed — not available on ICP
        res.json({ success: true });
    } catch (err) {
        console.error('[PUT /api/orders/transport-assignments]', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /partial-dispatch — Partially dispatch an order
router.post('/partial-dispatch', requireAdmin, async (req, res) => {
    try {
        const { order, dispatchQty } = req.body;
        if (!order) return res.status(400).json({ success: false, error: 'order is required' });
        if (!dispatchQty || dispatchQty <= 0) return res.status(400).json({ success: false, error: 'dispatchQty must be greater than 0' });
        const result = await orderBook.partialDispatch(order, dispatchQty);
        // Audit log for partial dispatch
        await audit.logAction(req.user.username || 'Unknown', 'PARTIAL_DISPATCH', `Dispatched ${dispatchQty}kg from order`, { order, dispatchQty });
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /cancel-partial-dispatch — Cancel partial dispatch and merge back
router.post('/cancel-partial-dispatch', requireAdmin, async (req, res) => {
    try {
        const { lot, client } = req.body;
        const result = await orderBook.cancelPartialDispatch({ lot, client });
        // Audit log for canceling partial dispatch
        await audit.logAction(req.user.username || 'Unknown', 'CANCEL_DISPATCH', `Cancelled partial dispatch for Lot: ${lot}, Client: ${client}`, { lot, client });
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============================================================================
// Helper: server-side WhatsApp for batch orders (fire-and-forget)
// NOTE: Uses external Meta Cloud API via axios — may not work on ICP.
// ============================================================================
async function _sendOrderWhatsApp(orders) {
    const clientName = orders[0]?.client;
    if (!clientName) return;

    // Look up client phone
    const contact = await clientContactsFb.getClientContact(clientName);
    if (!contact) {
        console.log(`[WhatsApp] No contact found for client "${clientName}" — skipping`);
        return;
    }

    const rawPhones = contact.phones || (contact.phone ? [contact.phone] : []);
    const phones = rawPhones.map(p => {
        let n = String(p || '').replace(/[^\d+]/g, '');
        if (n && !n.startsWith('+') && !n.startsWith('91') && n.length === 10) n = '91' + n;
        return n.replace(/^\+/, '');
    }).filter(Boolean);

    // Always notify dad (9600308400) on every new order
    const DAD_PHONE = '919600308400';
    if (!phones.includes(DAD_PHONE)) {
        phones.push(DAD_PHONE);
    }

    if (phones.length === 0) {
        console.log(`[WhatsApp] Client "${clientName}" has no phone numbers — skipping`);
        return;
    }

    // Build text summary of orders
    const billingFrom = (orders[0]?.billingFrom || 'SYGT').toUpperCase();
    const companyName = billingFrom === 'ESPL' ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';
    const orderDate = orders[0]?.orderDate || new Date().toLocaleDateString('en-IN');

    const lines = orders.map((o, i) =>
        `${o.lot || `#${i+1}`}: ${o.grade} - ${o.no} ${o.bagbox} - ${o.kgs}kg × ₹${o.price}${o.brand ? ` (${o.brand})` : ''}`
    );
    const summary = `📋 *${companyName}*\n👤 ${clientName} | 📅 ${orderDate}\n\n${lines.join('\n')}`;

    // Send via Meta Cloud API (dual WABA: SYGT primary + ESPL secondary)
    const META_TOKEN = process.env.META_WHATSAPP_TOKEN;
    const META_SYGT_PHONE_ID = process.env.META_WHATSAPP_SYGT_PHONE_ID;
    const META_ESPL_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;

    if (!META_TOKEN || (!META_SYGT_PHONE_ID && !META_ESPL_PHONE_ID)) {
        console.log('[WhatsApp] Meta Cloud API not configured — skipping server-side send');
        return;
    }

    const axios = require('axios');
    // SYGT WABA templates (primary sender: +916006560069)
    const sygtTemplateName = billingFrom === 'ESPL'
        ? 'order_details_espl_hx7df95ed3a1bf3e209a41c3ba920a16c1'
        : 'order_details_sygt_hxb338f8ebd49e1f6eacccd992d77372eb';
    // ESPL WABA templates (secondary sender: +919790005649)
    const esplTemplateName = billingFrom === 'ESPL' ? 'order_details_espl_v1' : 'order_details_sygt_v1';
    const logoUrl = 'https://cardamom-ysgf.onrender.com/images/brand/espl_logo.png';

    for (const phone of phones) {
        const tasks = [];

        // Primary: SYGT WABA (+916006560069)
        if (META_SYGT_PHONE_ID && phone !== '916006560069') {
            tasks.push((async () => {
                try {
                    await axios.post(
                        `https://graph.facebook.com/v22.0/${META_SYGT_PHONE_ID}/messages`,
                        {
                            messaging_product: 'whatsapp', to: phone, type: 'template',
                            template: {
                                name: sygtTemplateName, language: { code: 'en' },
                                components: [
                                    { type: 'header', parameters: [{ type: 'image', image: { link: logoUrl } }] },
                                    { type: 'body', parameters: [{ type: 'text', text: clientName }] },
                                ],
                            },
                        },
                        { headers: { Authorization: `Bearer ${META_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
                    );
                    console.log(`[WhatsApp] SYGT order confirmation sent to ${phone} for ${clientName}`);
                } catch (err) {
                    console.error(`[WhatsApp] SYGT failed for ${phone}: ${err.response?.data?.error?.message || err.message}`);
                }
            })());
        }

        // Secondary: ESPL WABA (+919790005649)
        if (META_ESPL_PHONE_ID && phone !== '919790005649') {
            tasks.push((async () => {
                try {
                    await axios.post(
                        `https://graph.facebook.com/v22.0/${META_ESPL_PHONE_ID}/messages`,
                        {
                            messaging_product: 'whatsapp', to: phone, type: 'template',
                            template: {
                                name: esplTemplateName, language: { code: 'en' },
                                components: [
                                    { type: 'header', parameters: [{ type: 'image', image: { link: logoUrl } }] },
                                    { type: 'body', parameters: [{ type: 'text', text: clientName }] },
                                ],
                            },
                        },
                        { headers: { Authorization: `Bearer ${META_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
                    );
                    console.log(`[WhatsApp] ESPL order confirmation sent to ${phone} for ${clientName}`);
                } catch (err) {
                    console.error(`[WhatsApp] ESPL failed for ${phone}: ${err.response?.data?.error?.message || err.message}`);
                }
            })());
        }

        await Promise.allSettled(tasks);
    }
}

module.exports = router;
