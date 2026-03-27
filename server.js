const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const compression = require('compression');
const path = require('path');
const http = require('http');
const { Server } = require('socket.io');
require('dotenv').config();

const featureFlags = require('./backend/featureFlags');
const { generateToken, authenticateToken, requireAdmin, requireSuperAdmin, requireClient, requirePageAccess } = require('./backend/middleware/auth');

// All modules now use Firebase Firestore directly
const dashboard = require('./backend/firebase/dashboard_fb');
const admin = require('./backend/admin');
const analytics = require('./backend/firebase/analytics_fb');
const predictive = require('./backend/firebase/predictive_analytics_fb');
const audit = require('./backend/audit_log');
const pricing = require('./backend/pricing_intelligence');
const aiBrain = require('./backend/firebase/ai_brain_fb');
const clientContactsFb = require('./backend/firebase/client_contacts_fb');
const users = require('./backend/firebase/users_fb');
const approvalRequests = require('./backend/firebase/approval_requests_fb');
const clientRequests = require('./backend/firebase/client_requests_fb');
const orderBook = require('./backend/firebase/orderBook_fb');
const taskManager = require('./backend/firebase/taskManager_fb');
const workersAttendance = require('./backend/firebase/workersAttendance_fb');
const expenses = require('./backend/firebase/expenses_fb');
const gatepasses = require('./backend/firebase/gatepasses_fb');
const dropdownFb = require('./backend/firebase/dropdown_fb');
const stockCalc = require('./backend/firebase/stock_fb');
const pushNotifications = require('./backend/firebase/push_notifications_fb');
const offerPrice = require('./backend/firebase/offer_price_fb');
const settingsFb = require('./backend/firebase/settings_fb');
const outstanding = require('./backend/firebase/outstanding_fb');
const syncFb = require('./backend/firebase/sync_fb');
const dispatchDocuments = require('./backend/firebase/dispatch_documents_fb');
const transportDocuments = require('./backend/firebase/transport_documents_fb');
const transportAssignments = require('./backend/firebase/transport_assignments_fb');
const whatsappLogs = require('./backend/firebase/whatsapp_logs_fb');
const packedBoxes = require('./backend/firebase/packed_boxes_fb');

// Report generators
const invoiceReport = require('./backend/reports/invoiceReport');
const dispatchReport = require('./backend/reports/dispatchReport');
const stockPositionReport = require('./backend/reports/stockPositionReport');
const stockMovementReport = require('./backend/reports/stockMovementReport');
const clientStatementReport = require('./backend/reports/clientStatementReport');
const salesSummaryReport = require('./backend/reports/salesSummaryReport');
const attendanceReport = require('./backend/reports/attendanceReport');
const expenseReport = require('./backend/reports/expenseReport');
const { reportCache, concurrencyLimiter, ReportCache } = require('./backend/reports/reportCache');

const app = express();
app.set('trust proxy', 1);
const httpServer = http.createServer(app);

// ---------------------------------------------------------------------------
// Simple API response cache (TTL-based, auto-invalidate on writes)
// Reduces Firestore reads by caching GET responses for short durations.
// ---------------------------------------------------------------------------
const _apiCache = new Map(); // key -> { data, expiresAt, lastAccess }
const API_CACHE_MAX_SIZE = 500; // LRU eviction to prevent unbounded memory

// TTL config: exact path match first, then prefix match for parameterized routes
const API_CACHE_TTL = {
    // Core data (2 min — balances freshness vs. Firestore quota)
    '/api/dashboard': 120 * 1000,
    '/api/stock/net': 120 * 1000,
    '/api/orders/sales-summary': 120 * 1000,
    '/api/orders/by-grade': 120 * 1000,
    '/api/orders/pending': 120 * 1000,
    '/api/orders/today-cart': 120 * 1000,
    '/api/orders/ledger-clients': 120 * 1000,
    '/api/orders': 120 * 1000,
    // Stock health (2 min — less volatile)
    '/api/stock/health': 120 * 1000,
    '/api/stock/negative-check': 120 * 1000,
    // Analytics (5 min — expensive computations, rarely stale)
    '/api/analytics/stock-forecast': 300 * 1000,
    '/api/analytics/client-scores': 300 * 1000,
    '/api/analytics/insights': 300 * 1000,
    '/api/analytics/demand-trends': 300 * 1000,
    '/api/analytics/seasonal-analysis': 300 * 1000,
    '/api/analytics/suggested-prices': 300 * 1000,
    // AI Brain (5 min — very expensive, data doesn't change fast)
    '/api/ai/daily-briefing': 300 * 1000,
    '/api/ai/recommendations': 300 * 1000,
    // Tasks / Approval (2 min)
    '/api/tasks': 120 * 1000,
    '/api/tasks/stats': 120 * 1000,
    '/api/approval-requests': 120 * 1000,
    // Outstanding payments (5 min — external Google Sheets)
    '/api/outstanding': 300 * 1000,
    '/api/outstanding/name-mappings': 300 * 1000,
    // Documents (5 min)
    '/api/dispatch-documents': 300 * 1000,
    '/api/transport-documents': 300 * 1000,
    // Sync (2 min — sync module has its own per-collection cache too)
    '/api/sync': 120 * 1000,
    // Contacts (5 min — rarely changes)
    '/api/clients/contacts/all': 300 * 1000,
};

// Prefix-based TTL for parameterized routes (e.g., /api/ai/grade-analysis/8MM)
const API_CACHE_TTL_PREFIX = [
    { prefix: '/api/ai/grade-analysis/', ttl: 120 * 1000 },
    { prefix: '/api/ai/client-analysis/', ttl: 120 * 1000 },
];

function _getTtl(key) {
    // Strip query string for exact match lookup
    const basePath = key.split('?')[0].split('{')[0];
    if (API_CACHE_TTL[basePath]) return API_CACHE_TTL[basePath];
    for (const { prefix, ttl } of API_CACHE_TTL_PREFIX) {
        if (basePath.startsWith(prefix)) return ttl;
    }
    return 0;
}

function getCachedResponse(key) {
    const entry = _apiCache.get(key);
    if (!entry) return null;
    if (Date.now() > entry.expiresAt) { _apiCache.delete(key); return null; }
    entry.lastAccess = Date.now(); // Track for LRU
    return entry.data;
}

function setCachedResponse(key, data) {
    const ttl = _getTtl(key);
    if (!ttl) return;
    // LRU eviction: remove oldest entry if at capacity
    if (_apiCache.size >= API_CACHE_MAX_SIZE) {
        let oldestKey = null, oldestTime = Infinity;
        for (const [k, v] of _apiCache) {
            if (v.lastAccess < oldestTime) { oldestTime = v.lastAccess; oldestKey = k; }
        }
        if (oldestKey) _apiCache.delete(oldestKey);
    }
    _apiCache.set(key, { data, expiresAt: Date.now() + ttl, lastAccess: Date.now() });
}

function invalidateApiCache() {
    _apiCache.clear();
}

// Targeted invalidation: only clear caches matching a prefix
function invalidateCachePrefix(prefix) {
    for (const key of _apiCache.keys()) {
        if (key.startsWith(prefix)) _apiCache.delete(key);
    }
}

// Periodic sweep of expired cache entries (every 5 minutes)
// .unref() allows Node/Jest to exit without waiting for this timer
setInterval(() => {
    const now = Date.now();
    for (const [key, entry] of _apiCache) {
        if (now > entry.expiresAt) _apiCache.delete(key);
    }
}, 5 * 60 * 1000).unref();

// CORS Configuration: Restrict to trusted origins only
const allowedOrigins = process.env.ALLOWED_ORIGINS?.split(',') || [
    'http://localhost:3000',
    'http://localhost:8080',
    'http://172.20.10.4:3000',
    'https://cardamom-api.onrender.com',
    'https://cardamom-ysgf.onrender.com'
];

const io = new Server(httpServer, {
    cors: {
        origin: allowedOrigins,
        methods: ['GET', 'POST', 'PUT', 'DELETE'],
        credentials: true
    },
    transports: ['websocket', 'polling']
});
const PORT = process.env.PORT || 3000;

// Track connected users by userId for targeted notifications
const connectedUsers = new Map();

// Socket.IO connection handling
io.on('connection', (socket) => {
    console.log(`🔌 [Socket.IO] Client connected: ${socket.id}`);

    socket.on('register', (data) => {
        const userId = data.userId || data;
        const role = data.role || 'unknown';
        connectedUsers.set(userId, { socketId: socket.id, role });
        socket.userId = userId;
        console.log(`✅ [Socket.IO] User registered: ${userId} (${role})`);

        // Join admin room if admin
        if (role === 'admin') {
            socket.join('admins');
            console.log(`👑 [Socket.IO] Admin joined 'admins' room: ${userId}`);
        }
    });

    socket.on('disconnect', () => {
        // O(1) cleanup using userId stored during register
        if (socket.userId) {
            const entry = connectedUsers.get(socket.userId);
            if (entry && entry.socketId === socket.id) {
                connectedUsers.delete(socket.userId);
                console.log(`🔌 [Socket.IO] User disconnected: ${socket.userId}`);
            }
        }
    });
});


// Middleware

// Security headers (before CORS so headers are always set)
// Security headers (before CORS so headers are always set)
app.use(helmet({
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            scriptSrc: ["'self'", "'unsafe-inline'", "'unsafe-eval'", "'wasm-unsafe-eval'", "https://www.gstatic.com", "https://*.googleapis.com"],
            styleSrc: ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"],
            fontSrc: ["'self'", "https://fonts.gstatic.com", "data:"],
            connectSrc: ["'self'", "https://www.gstatic.com", "https://*.googleapis.com", "https://fonts.googleapis.com", "https://fonts.gstatic.com", "https://cardamom-ysgf.onrender.com", "https://cardamom-api.onrender.com"],
            imgSrc: ["'self'", "data:", "blob:", "https://*.gstatic.com"],
            frameSrc: ["'self'"],
            workerSrc: ["'self'", "blob:"]
        }
    }
}));

app.use(cors({
    origin: allowedOrigins,
    credentials: true
}));
app.use(bodyParser.json({ limit: '10mb' }));
app.use(bodyParser.urlencoded({ limit: '10mb', extended: true }));
app.use(compression());

// Response size guardrail (logs warnings > 1 MB, truncates > 2 MB)
const { responseGuardrail } = require('./backend/middleware/responseGuardrail');
app.use(responseGuardrail);

app.use(express.static(path.join(__dirname, 'public')));

// Fallback file serving for Render disk uploads (when Firebase Storage is unavailable)
app.use('/api/files', express.static(path.join(__dirname, 'uploads')));

// Targeted cache invalidation on write operations
// Only clears API + sync caches related to the modified resource
app.use((req, res, next) => {
    if (['POST', 'PUT', 'DELETE'].includes(req.method) && req.path.startsWith('/api/')) {
        const p = req.path;
        // Targeted API cache invalidation
        if (p.startsWith('/api/orders') || p.startsWith('/api/stock')) {
            invalidateCachePrefix('/api/orders');
            invalidateCachePrefix('/api/stock');
            invalidateCachePrefix('/api/dashboard');
            syncFb.invalidateSyncCache(['orders']);
        }
        if (p.startsWith('/api/tasks')) {
            invalidateCachePrefix('/api/tasks');
            syncFb.invalidateSyncCache(['tasks']);
        }
        if (p.startsWith('/api/approval')) {
            invalidateCachePrefix('/api/approval');
            syncFb.invalidateSyncCache(['approval_requests']);
        }
        if (p.startsWith('/api/outstanding')) {
            invalidateCachePrefix('/api/outstanding');
        }
        if (p.startsWith('/api/dispatch-documents')) {
            invalidateCachePrefix('/api/dispatch-documents');
            syncFb.invalidateSyncCache(['dispatch_documents']);
        }
        if (p.startsWith('/api/transport-documents')) {
            invalidateCachePrefix('/api/transport-documents');
        }
        if (p.startsWith('/api/clients')) {
            invalidateCachePrefix('/api/clients');
            syncFb.invalidateSyncCache(['client_contacts']);
        }
        // Attendance mutations clear attendance + dashboard caches
        if (p.startsWith('/api/attendance')) {
            invalidateCachePrefix('/api/attendance');
            invalidateCachePrefix('/api/dashboard');
            syncFb.invalidateSyncCache(['attendance']);
        }
        // Expense mutations clear expense caches
        if (p.startsWith('/api/expenses')) {
            invalidateCachePrefix('/api/expenses');
            invalidateCachePrefix('/api/dashboard');
            syncFb.invalidateSyncCache(['expenses']);
        }
        // Gate pass mutations clear gate pass caches
        if (p.startsWith('/api/gate-passes')) {
            invalidateCachePrefix('/api/gate-passes');
            syncFb.invalidateSyncCache(['gate_passes']);
        }
        // Notification mutations clear notification caches
        if (p.startsWith('/api/notifications')) {
            invalidateCachePrefix('/api/notifications');
        }
        // Dropdown mutations clear dropdown + dependent caches
        if (p.startsWith('/api/dropdown')) {
            invalidateCachePrefix('/api/dropdown');
            syncFb.invalidateSyncCache(['dropdowns']);
        }
        // Transport assignment mutations clear daily cart cache (other users need fresh data)
        if (p.includes('transport-assignments')) {
            invalidateCachePrefix('/api/orders/today-cart');
            invalidateCachePrefix('/api/orders/transport-assignments');
        }
    }
    next();
});

// Global rate limiter for all API routes
const apiLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 500,
    standardHeaders: true,
    legacyHeaders: false,
    message: { success: false, error: 'Too many requests, please try again later.' }
});
app.use('/api/', apiLimiter);

// Stricter rate limiter for login endpoint
const loginLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 5,
    standardHeaders: true,
    legacyHeaders: false,
    message: { success: false, error: 'Too many login attempts, please try again later.' }
});
app.use('/api/auth/login', loginLimiter);

// ====== JWT AUTHENTICATION MIDDLEWARE ======
// Protect all API routes except login endpoint
app.use((req, res, next) => {
    // Public routes (no authentication required)
    const publicRoutes = [
        '/api/auth/login',
        '/api/auth/face-login',    // Face login (server-verified)
        '/api/health',
        '/api/orders/dropdowns',  // Dropdown data is configuration, allow without auth
        '/api/users/face-data/all'  // Face login matching (pre-authentication)
    ];

    if (publicRoutes.includes(req.path)) {
        return next(); // Skip authentication for public routes
    }

    // All other /api/* routes require JWT authentication
    if (req.path.startsWith('/api/')) {
        return authenticateToken(req, res, next);
    }

    // Non-API routes pass through
    next();
});

// Helper: extract user info from JWT-authenticated request
function getUserFromRequest(req) {
    if (req.user) {
        return { username: req.user.username, role: req.user.role };
    }
    // Never trust headers for auth — return unknown if JWT not present
    return { username: 'unknown', role: 'unknown' };
}

// --- API Routes ---

// Health check (no auth required — used by app connectivity monitor)
app.get('/api/health', (req, res) => {
    res.json({
        status: 'ok',
        timestamp: new Date().toISOString(),
        imageBaseUrl: process.env.RENDER_EXTERNAL_URL || process.env.BASE_URL || 'localhost',
    });
});

// Dashboard
app.get('/api/dashboard', async (req, res) => {
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

// Stock
app.get('/api/stock/net', async (req, res) => {
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

app.post('/api/stock/purchase', requireAdmin, async (req, res) => {
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

app.post('/api/stock/recalc', requireAdmin, async (req, res) => {
    try {
        const result = await stockCalc.updateAllStocks();
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Clear all Rejection stock adjustments
app.post('/api/stock/clear-rejection', authenticateToken, async (req, res) => {
    try {
        const result = await stockCalc.clearRejectionAdjustments();
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Manual stock adjustment
app.post('/api/stock/adjust', requireAdmin, async (req, res) => {
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

app.get('/api/stock/delta-status', async (req, res) => {
    try {
        const html = await stockCalc.getDeltaStatusHtml();
        res.send(html);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Stock Health & Validation
app.get('/api/stock/health', async (req, res) => {
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

app.get('/api/stock/negative-check', async (req, res) => {
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

app.post('/api/stock/validate-sufficiency', async (req, res) => {
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
app.get('/api/stock/purchase-history', authenticateToken, requireAdmin, async (req, res) => {
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

app.get('/api/stock/adjustment-history', authenticateToken, requireAdmin, async (req, res) => {
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

// ==================== SYNC ENDPOINT (offline-first) ====================

app.get('/api/sync', authenticateToken, async (req, res) => {
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

// Orders
app.get('/api/orders', authenticateToken, async (req, res) => {
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

app.post('/api/orders', authenticateToken, async (req, res) => {
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

app.post('/api/orders/batch', authenticateToken, async (req, res) => {
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

        // ── Mandatory WhatsApp: notify client + dad on every new order ──
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

// ── Helper: server-side WhatsApp for batch orders (fire-and-forget) ──
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

// REMOVED: Duplicate insecure cancel route - secure version exists later in file with proper auth

// Cancel specific item (Sub-order)
app.post('/api/client-requests/:requestId/cancel-item', requireAdmin, async (req, res) => {
    console.log(`[Server] Received cancel-item request for ${req.params.requestId}`, req.body);
    try {
        const { index, reason } = req.body;
        // Extract role from JWT (secure)
        const { role } = getUserFromRequest(req);
        const result = await clientRequests.cancelRequestItem(req.params.requestId, index, role, reason);
        console.log('[Server] cancelRequestItem result:', result);
        res.json(result);
    } catch (err) {
        console.error('Error cancelling item:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Update packed date on a billed order (superadmin only)
app.put('/api/orders/packed/:docId', authenticateToken, async (req, res) => {
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

app.put('/api/orders/:rowIndex', authenticateToken, requireAdmin, requirePageAccess('edit_orders'), async (req, res) => {
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

app.delete('/api/orders/:rowIndex', authenticateToken, requireAdmin, requirePageAccess('delete_orders'), async (req, res) => {
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

// POST /api/orders/deduplicate - Find and remove duplicate packed/billed orders
app.post('/api/orders/deduplicate', authenticateToken, requireAdmin, async (req, res) => {
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

// GET /api/orders/similar - Get similar previous orders for comparison
app.get('/api/orders/similar', async (req, res) => {
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

// POST /api/orders/check-drift - Check for price/qty drift against recent orders
app.post('/api/orders/check-drift', async (req, res) => {
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

app.get('/api/orders/dropdowns', async (req, res) => {
    try {
        const { dropdownCache } = require('./backend/utils/cache');
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

// ============================================================================
// DROPDOWN CRUD (Phase 8)
// ============================================================================

// Search dropdown items (fuzzy match for inline add)
app.get('/api/dropdowns/:category/search', async (req, res) => {
    try {
        const { category } = req.params;
        const { q } = req.query;
        if (!q) return res.status(400).json({ success: false, error: 'Query parameter q is required' });
        const result = await dropdownFb.searchDropdownItems(category, q);
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Search error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get single category items
app.get('/api/dropdowns/:category', async (req, res) => {
    try {
        const result = await dropdownFb.getDropdownCategory(req.params.category);
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Get category error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Add dropdown item (with duplicate check)
app.post('/api/dropdowns/:category/add', requireAdmin, async (req, res) => {
    try {
        const { value } = req.body;
        if (!value) return res.status(400).json({ success: false, error: 'value is required' });
        const result = await dropdownFb.addDropdownItem(req.params.category, value);
        // Invalidate dropdown cache on write
        const { dropdownCache } = require('./backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Add error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Force add (skip duplicate check — user confirmed)
app.post('/api/dropdowns/:category/force-add', requireAdmin, async (req, res) => {
    try {
        const { value } = req.body;
        if (!value) return res.status(400).json({ success: false, error: 'value is required' });
        const result = await dropdownFb.forceAddDropdownItem(req.params.category, value);
        const { dropdownCache } = require('./backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Force-add error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Update (rename) dropdown item — admin only
app.put('/api/dropdowns/:category/item', requireAdmin, async (req, res) => {
    try {
        const { oldValue, newValue } = req.body;
        if (!oldValue || !newValue) return res.status(400).json({ success: false, error: 'oldValue and newValue are required' });
        const result = await dropdownFb.updateDropdownItem(req.params.category, oldValue, newValue);
        const { dropdownCache } = require('./backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Update error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete dropdown item — admin only
app.delete('/api/dropdowns/:category/item', requireAdmin, async (req, res) => {
    try {
        const { value } = req.body;
        if (!value) return res.status(400).json({ success: false, error: 'value is required' });
        const result = await dropdownFb.deleteDropdownItem(req.params.category, value);
        const { dropdownCache } = require('./backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Delete error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Find duplicate client names (potential merges) — admin only
app.get('/api/clients/duplicates', requireAdmin, async (req, res) => {
    try {
        const result = await dropdownFb.findDuplicateClients();
        res.json(result);
    } catch (err) {
        console.error('[Clients] Duplicate detection error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Merge duplicate client names across all orders — admin only
app.post('/api/clients/merge', requireAdmin, async (req, res) => {
    try {
        const { oldName, newName, dryRun = true } = req.body;
        if (!oldName || !newName) return res.status(400).json({ success: false, error: 'oldName and newName are required' });
        const result = await dropdownFb.mergeClients(oldName, newName, dryRun);
        const { dropdownCache } = require('./backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Clients] Merge error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Client Contact Details - for WhatsApp sharing (Firestore)
app.get('/api/clients/contact/:clientName', requireAdmin, async (req, res) => {
    try {
        const { clientName } = req.params;
        if (!clientName) {
            return res.status(400).json({ success: false, error: 'clientName is required' });
        }

        const contact = await clientContactsFb.getClientContact(clientName);

        if (!contact) {
            return res.json({ success: false, error: 'Client not found', clientName });
        }

        // Clean phone number helper
        function cleanPhoneNum(raw) {
            let p = String(raw || '').replace(/[^\d+]/g, '');
            if (p && !p.startsWith('+') && !p.startsWith('91') && p.length === 10) {
                p = '91' + p;
            }
            p = p.replace(/^\+/, '');
            return p;
        }

        const rawPhones = contact.phones || (contact.phone ? [contact.phone] : []);
        const cleanedPhones = rawPhones.map(cleanPhoneNum).filter(Boolean);

        res.json({
            success: true,
            contact: {
                name: contact.name,
                phones: cleanedPhones,
                rawPhones: rawPhones,
                phone: cleanedPhones[0] || '',     // backward compat
                rawPhone: rawPhones[0] || '',       // backward compat
                address: contact.address,
                gstin: contact.gstin
            }
        });
    } catch (err) {
        console.error('[GET /api/clients/contact] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get all client contacts (for dropdown manager)
app.get('/api/clients/contacts/all', requireAdmin, async (req, res) => {
    try {
        const contacts = await clientContactsFb.getAllClientContacts();

        // Clean phone numbers consistently (same logic as single-contact endpoint)
        function cleanPhoneNum(raw) {
            let p = String(raw || '').replace(/[^\d+]/g, '');
            if (p && !p.startsWith('+') && !p.startsWith('91') && p.length === 10) {
                p = '91' + p;
            }
            p = p.replace(/^\+/, '');
            return p;
        }

        const cleaned = contacts.map(c => {
            const rawPhones = c.phones || (c.phone ? [c.phone] : []);
            const cleanedPhones = rawPhones.map(cleanPhoneNum).filter(Boolean);
            return {
                ...c,
                phones: cleanedPhones,
                phone: cleanedPhones[0] || '',
            };
        });

        res.json({ success: true, contacts: cleaned });
    } catch (err) {
        console.error('[GET /api/clients/contacts/all] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Verify if a phone number is active on WhatsApp
app.get('/api/whatsapp/verify/:phone', async (req, res) => {
    try {
        const phone = req.params.phone.replace(/\D/g, '');
        if (!phone || phone.length < 10) {
            return res.json({ success: true, valid: false, reason: 'Invalid phone number format' });
        }

        // Format: ensure country code (default India +91)
        const fullPhone = phone.length === 10 ? `91${phone}` : phone;

        // Use WhatsApp's wa.me endpoint to check if the number exists
        // wa.me returns different content for valid vs invalid numbers
        const https = require('https');
        const checkUrl = `https://api.whatsapp.com/send/?phone=${fullPhone}&text&type=phone_number&app_absent=0`;

        const result = await new Promise((resolve, reject) => {
            https.get(checkUrl, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
                },
                timeout: 8000
            }, (response) => {
                let data = '';
                response.on('data', chunk => data += chunk);
                response.on('end', () => {
                    // If WhatsApp returns a page with "send a message" content, the number is valid
                    // If invalid, it typically shows an error or different content
                    const isValid = response.statusCode === 200 && !data.includes('page_not_found') && !data.includes('invalid');
                    resolve({ valid: isValid, statusCode: response.statusCode });
                });
            }).on('error', (err) => {
                reject(err);
            }).on('timeout', () => {
                resolve({ valid: true, statusCode: 0, timeout: true }); // Assume valid on timeout
            });
        });

        res.json({ success: true, valid: result.valid, phone: fullPhone });
    } catch (err) {
        console.error('[GET /api/whatsapp/verify] Error:', err);
        // On error, don't block the user — assume valid
        res.json({ success: true, valid: true, error: err.message });
    }
});

// ========== WhatsApp: Send image message via Meta Cloud API ==========
const fs = require('fs');

// POST /api/whatsapp/send-image
// Accepts base64 image + phone(s), hosts image temporarily, sends via Meta Cloud API to all numbers
app.post('/api/whatsapp/send-image', requireAdmin, async (req, res) => {
    const startTime = Date.now();
    const requestId = `wa_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;

    console.log(`\n[${requestId}] ========== WhatsApp Send Image Started ==========`);

    try {
        const { imageBase64, phone, phones, caption, clientName, operationType, companyName } = req.body;

        // Resolve target phones: prefer `phones` array, fall back to `phone` string
        const targetPhones = Array.isArray(phones) && phones.length > 0
            ? phones
            : (phone ? [phone] : []);

        if (!imageBase64 || targetPhones.length === 0) {
            return res.status(400).json({ success: false, error: 'imageBase64 and at least one phone are required', requestId });
        }
        console.log(`[${requestId}] Sending to ${targetPhones.length} number(s), client: ${clientName || 'N/A'}, operation: ${operationType || 'default'}`);

        // Meta Cloud API config — dual-number setup
        const META_WA_TOKEN = process.env.META_WHATSAPP_TOKEN;
        // ESPL WABA: +919790005649
        const META_ESPL_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;
        const META_ESPL_NUMBER = '919790005649';
        // SYGT WABA: +916006560069 (primary sender, primary sender)
        const META_SYGT_PHONE_ID = process.env.META_WHATSAPP_SYGT_PHONE_ID;
        const META_SYGT_NUMBER = '916006560069';
        const metaEnabled = !!(META_WA_TOKEN && META_ESPL_PHONE_ID);
        const sygtEnabled = !!(META_WA_TOKEN && META_SYGT_PHONE_ID);

        // Meta ESPL WABA templates (secondary sender: +919790005649)
        const META_ESPL_TEMPLATES = {
            order_confirmation_espl: { name: 'order_details_espl_v1', hasImageHeader: true },
            order_confirmation_sygt: { name: 'order_details_sygt_v1', hasImageHeader: true },
            share_orders_espl:      { name: 'order_details_espl_v1', hasImageHeader: true },
            share_orders_sygt:      { name: 'order_details_sygt_v1', hasImageHeader: true },
            invoice_document:       { name: 'invoice_document_v1',   hasImageHeader: true },
            payment_reminder_espl:  { name: 'payment_reminder_espl_v3', hasImageHeader: true },
            payment_reminder_sygt:  { name: 'payment_reminder_sygt_v3', hasImageHeader: true },
        };

        // Meta SYGT WABA templates (primary sender: +916006560069, primary sender)
        const META_SYGT_TEMPLATES = {
            order_confirmation_espl: { name: 'order_details_espl_hx7df95ed3a1bf3e209a41c3ba920a16c1', hasImageHeader: true },
            order_confirmation_sygt: { name: 'order_details_sygt_hxb338f8ebd49e1f6eacccd992d77372eb', hasImageHeader: true },
            share_orders_espl:      { name: 'order_details_espl_hx7df95ed3a1bf3e209a41c3ba920a16c1', hasImageHeader: true },
            share_orders_sygt:      { name: 'order_details_sygt_hxb338f8ebd49e1f6eacccd992d77372eb', hasImageHeader: true },
            invoice_document:       { name: 'invoice_document_hx96d51d825956ebc66f7be26efb466c1c', hasImageHeader: true },
            payment_reminder_espl:  { name: 'payment_remind_espl_hx4923be67303fb2dfcff7f9894c232faf', hasImageHeader: true },
            payment_reminder_sygt:  { name: 'payment_remind_sygt_hx7e453c04aef926fea01ead62354f3833', hasImageHeader: true },
            price_offer_espl:       { name: 'price_offer_espl_hxa2f5a9808bda54528039c6b644759f95', hasImageHeader: true },
            price_offer_sygt:       { name: 'price_offer_sygt_hx0bf2d2f0bc3aabe6f73d4ca17578624b', hasImageHeader: true },
        };

        if (!sygtEnabled && !metaEnabled) {
            return res.status(500).json({ success: false, error: 'WhatsApp not configured (Meta Cloud API credentials missing)', requestId });
        }

        // Save image once
        // Upload image to external host (always-available URL)
        const imageBuffer = Buffer.from(imageBase64, 'base64');
        const FormData = require('form-data');
        const axios = require('axios');
        let imageUrl;
        let localFilePath = null;
        try {
            const form = new FormData();
            form.append('reqtype', 'fileupload');
            form.append('time', '24h');
            form.append('fileToUpload', imageBuffer, { filename: `wa_${Date.now()}.png`, contentType: 'image/png' });
            const uploadRes = await axios.post('https://litterbox.catbox.moe/resources/internals/api.php', form, { headers: form.getHeaders(), timeout: 15000 });
            imageUrl = uploadRes.data.trim();
            console.log(`[${requestId}] Image uploaded to CDN: ${imageUrl} (${(imageBuffer.length / 1024).toFixed(2)} KB)`);
        } catch (uploadErr) {
            // Fallback to local hosting
            console.error(`[${requestId}] CDN upload failed: ${uploadErr.message}, falling back to local`);
            const tmpDir = path.join(__dirname, 'public', 'tmp');
            if (!fs.existsSync(tmpDir)) fs.mkdirSync(tmpDir, { recursive: true });
            const localName = `wa_${Date.now()}.png`;
            localFilePath = path.join(tmpDir, localName);
            fs.writeFileSync(localFilePath, imageBuffer);
            const baseUrl = process.env.RENDER_EXTERNAL_URL || process.env.BASE_URL || `http://localhost:${process.env.PORT || 3000}`;
            imageUrl = `${baseUrl}/tmp/${localName}`;
        }

        // Resolve template keys
        const companySuffix = (companyName || '').toLowerCase().includes('emperor') ? 'espl' : 'sygt';
        const opKey = operationType ? `${operationType}_${companySuffix}` : `order_confirmation_${companySuffix}`;

        // Resolve SYGT WABA template (primary: +916006560069)
        const sygtTemplate = META_SYGT_TEMPLATES[opKey] || META_SYGT_TEMPLATES[operationType];
        const shouldSendSygt = sygtEnabled && sygtTemplate;

        // Resolve ESPL WABA template (secondary: +919790005649)
        const esplTemplate = META_ESPL_TEMPLATES[opKey] || META_ESPL_TEMPLATES[operationType];
        const shouldSendEspl = metaEnabled && esplTemplate;

        // Upload image to SYGT WABA media (primary)
        let sygtMediaId = null;
        if (shouldSendSygt && sygtTemplate.hasImageHeader) {
            try {
                const sygtForm = new FormData();
                sygtForm.append('messaging_product', 'whatsapp');
                sygtForm.append('type', 'image/png');
                sygtForm.append('file', imageBuffer, { filename: `wa_${Date.now()}.png`, contentType: 'image/png' });
                const sygtUpload = await axios.post(
                    `https://graph.facebook.com/v22.0/${META_SYGT_PHONE_ID}/media`,
                    sygtForm,
                    { headers: { ...sygtForm.getHeaders(), Authorization: `Bearer ${META_WA_TOKEN}` }, timeout: 15000 }
                );
                sygtMediaId = sygtUpload.data.id;
                console.log(`[${requestId}] SYGT media uploaded: ${sygtMediaId}`);
            } catch (sygtUpErr) {
                console.error(`[${requestId}] SYGT media upload failed: ${sygtUpErr.response?.data ? JSON.stringify(sygtUpErr.response.data) : sygtUpErr.message}`);
            }
        }

        // Upload image to ESPL WABA media (secondary)
        let esplMediaId = null;
        if (shouldSendEspl && esplTemplate.hasImageHeader) {
            try {
                const esplForm = new FormData();
                esplForm.append('messaging_product', 'whatsapp');
                esplForm.append('type', 'image/png');
                esplForm.append('file', imageBuffer, { filename: `wa_${Date.now()}.png`, contentType: 'image/png' });
                const esplUpload = await axios.post(
                    `https://graph.facebook.com/v22.0/${META_ESPL_PHONE_ID}/media`,
                    esplForm,
                    { headers: { ...esplForm.getHeaders(), Authorization: `Bearer ${META_WA_TOKEN}` }, timeout: 15000 }
                );
                esplMediaId = esplUpload.data.id;
                console.log(`[${requestId}] ESPL media uploaded: ${esplMediaId}`);
            } catch (esplUpErr) {
                console.error(`[${requestId}] ESPL media upload failed: ${esplUpErr.response?.data ? JSON.stringify(esplUpErr.response.data) : esplUpErr.message}`);
            }
        }

        // Helper: send via Meta Cloud API
        const sendViaMeta = async (cleanPhone, phoneId, template, mediaId) => {
            const components = [{ type: 'body', parameters: [{ type: 'text', text: clientName || 'Customer' }] }];
            if (template.hasImageHeader && (mediaId || imageUrl)) {
                const imgParam = mediaId ? { id: mediaId } : { link: imageUrl };
                components.unshift({ type: 'header', parameters: [{ type: 'image', image: imgParam }] });
            }
            const res = await axios.post(
                `https://graph.facebook.com/v22.0/${phoneId}/messages`,
                {
                    messaging_product: 'whatsapp', to: cleanPhone, type: 'template',
                    template: { name: template.name, language: { code: 'en' }, components }
                },
                { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
            );
            return res.data?.messages?.[0]?.id || '';
        };

        // Send to all phones in PARALLEL via Promise.allSettled (SYGT + ESPL)
        const sendToPhone = async (targetPhone) => {
            let cleanPhone = String(targetPhone).replace(/\D/g, '');
            if (cleanPhone.length === 10) cleanPhone = `91${cleanPhone}`;

            let sygtOk = false;
            let esplOk = false;
            let messageId = null;

            // 1. Send via SYGT WABA (+916006560069) — primary sender (primary sender)
            if (shouldSendSygt && cleanPhone !== META_SYGT_NUMBER) {
                try {
                    const wamid = await sendViaMeta(cleanPhone, META_SYGT_PHONE_ID, sygtTemplate, sygtMediaId);
                    sygtOk = true;
                    messageId = wamid;
                    console.log(`[${requestId}] ✓ SYGT +${cleanPhone} (${sygtTemplate.name}): ${wamid}`);
                } catch (err) {
                    console.error(`[${requestId}] ✗ SYGT failed for +${cleanPhone}: ${err.response?.data ? JSON.stringify(err.response.data) : err.message}`);
                }
            }

            // 2. Send via ESPL WABA (+919790005649) — secondary sender
            if (shouldSendEspl && cleanPhone !== META_ESPL_NUMBER) {
                try {
                    const wamid = await sendViaMeta(cleanPhone, META_ESPL_PHONE_ID, esplTemplate, esplMediaId);
                    esplOk = true;
                    if (!messageId) messageId = wamid;
                    console.log(`[${requestId}] ✓ ESPL +${cleanPhone} (${esplTemplate.name}): ${wamid}`);
                } catch (err) {
                    console.error(`[${requestId}] ✗ ESPL failed for +${cleanPhone}: ${err.response?.data ? JSON.stringify(err.response.data) : err.message}`);
                }
            }

            return { phone: `+${cleanPhone}`, success: sygtOk || esplOk, messageId, method: `sygt:${sygtOk},espl:${esplOk}` };
        };

        const settled = await Promise.allSettled(targetPhones.map(p => sendToPhone(p)));
        const results = settled.map(s =>
            s.status === 'fulfilled' ? s.value : { success: false, error: s.reason?.message || 'Unknown error' }
        );

        // Cleanup temp image after 5 minutes
        if (localFilePath) { setTimeout(() => { try { fs.unlinkSync(localFilePath); } catch (e) { } }, 300000); }

        const sentCount = results.filter(r => r.success).length;
        const duration = Date.now() - startTime;
        console.log(`[${requestId}] Done: ${sentCount}/${targetPhones.length} sent in ${duration}ms (sygt: ${shouldSendSygt ? sygtTemplate.name : 'off'}, espl: ${shouldSendEspl ? esplTemplate.name : 'off'})\n`);

        res.json({
            success: sentCount > 0,
            sentCount,
            totalCount: targetPhones.length,
            results,
            requestId,
            imageUrl,
            duration: `${duration}ms`
        });

    } catch (err) {
        const duration = Date.now() - startTime;
        console.error(`[${requestId}] Error: ${err.message} (${duration}ms)\n`);
        res.status(500).json({ success: false, error: err.message, requestId, duration: `${duration}ms` });
    }
});

// POST /api/whatsapp/send-text
// Sends a text-only WhatsApp message via Meta Cloud API (SYGT primary + ESPL secondary)
app.post('/api/whatsapp/send-text', requireAdmin, async (req, res) => {
    try {
        const { phone, phones, clientName, orderId, orderDetails, totalAmount } = req.body;

        const targetPhones = Array.isArray(phones) && phones.length > 0
            ? phones
            : (phone ? [phone] : []);

        if (targetPhones.length === 0) {
            return res.status(400).json({ success: false, error: 'At least one phone is required' });
        }

        const META_TOKEN = process.env.META_WHATSAPP_TOKEN;
        const META_SYGT_PHONE_ID = process.env.META_WHATSAPP_SYGT_PHONE_ID;
        const META_ESPL_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;

        if (!META_TOKEN || (!META_SYGT_PHONE_ID && !META_ESPL_PHONE_ID)) {
            return res.status(500).json({ success: false, error: 'Meta WhatsApp not configured' });
        }

        const axios = require('axios');
        // Use order_confirm templates (SYGT WABA)
        const sygtTemplate = 'order_confirm_sygt_hxdbec4c73106f98d84aa16d0832993784';
        const esplTemplate = 'order_confirm_espl_hxa353a5933129970bac3b6ccc7d59d1fa';
        const logoUrl = 'https://cardamom-ysgf.onrender.com/images/brand/espl_logo.png';

        const sendToPhone = async (targetPhone) => {
            let cleanPhone = String(targetPhone).replace(/\D/g, '');
            if (cleanPhone.length === 10) cleanPhone = `91${cleanPhone}`;

            let messageId = null;
            let sygtOk = false, esplOk = false;

            // Primary: SYGT WABA (+916006560069)
            if (META_SYGT_PHONE_ID && cleanPhone !== '916006560069') {
                try {
                    const r = await axios.post(
                        `https://graph.facebook.com/v22.0/${META_SYGT_PHONE_ID}/messages`,
                        {
                            messaging_product: 'whatsapp', to: cleanPhone, type: 'template',
                            template: {
                                name: sygtTemplate, language: { code: 'en' },
                                components: [
                                    { type: 'header', parameters: [{ type: 'image', image: { link: logoUrl } }] },
                                    { type: 'body', parameters: [{ type: 'text', text: clientName || 'Customer' }] },
                                ],
                            },
                        },
                        { headers: { Authorization: `Bearer ${META_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
                    );
                    messageId = r.data?.messages?.[0]?.id || '';
                    sygtOk = true;
                    console.log(`[WA Text] ✓ SYGT +${cleanPhone}: ${messageId}`);
                } catch (err) {
                    console.error(`[WA Text] ✗ SYGT +${cleanPhone}: ${err.response?.data?.error?.message || err.message}`);
                }
            }

            // Secondary: ESPL WABA (+919790005649)
            if (META_ESPL_PHONE_ID && cleanPhone !== '919790005649') {
                try {
                    const r = await axios.post(
                        `https://graph.facebook.com/v22.0/${META_ESPL_PHONE_ID}/messages`,
                        {
                            messaging_product: 'whatsapp', to: cleanPhone, type: 'template',
                            template: {
                                name: esplTemplate, language: { code: 'en' },
                                components: [
                                    { type: 'header', parameters: [{ type: 'image', image: { link: logoUrl } }] },
                                    { type: 'body', parameters: [{ type: 'text', text: clientName || 'Customer' }] },
                                ],
                            },
                        },
                        { headers: { Authorization: `Bearer ${META_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
                    );
                    if (!messageId) messageId = r.data?.messages?.[0]?.id || '';
                    esplOk = true;
                    console.log(`[WA Text] ✓ ESPL +${cleanPhone}: ${messageId}`);
                } catch (err) {
                    console.error(`[WA Text] ✗ ESPL +${cleanPhone}: ${err.response?.data?.error?.message || err.message}`);
                }
            }

            return { phone: `+${cleanPhone}`, success: sygtOk || esplOk, messageId, method: `sygt:${sygtOk},espl:${esplOk}` };
        };

        const settled = await Promise.allSettled(targetPhones.map(p => sendToPhone(p)));
        const results = settled.map(s =>
            s.status === 'fulfilled' ? s.value : { phone: 'unknown', success: false, error: s.reason?.message || 'Send failed' }
        );

        const sentCount = results.filter(r => r.success).length;
        res.json({ success: sentCount > 0, sentCount, totalCount: targetPhones.length, results });

    } catch (err) {
        console.error('[POST /api/whatsapp/send-text] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Save/update client contact (phones, address, gstin)
app.put('/api/clients/contact', requireAdmin, async (req, res) => {
    try {
        const { name, oldName, phone, phones, address, gstin } = req.body;
        console.log(`[PUT /api/clients/contact] name="${name}" oldName=${oldName} phones=${JSON.stringify(phones)} phone=${phone} address="${address}"`);
        if (!name) {
            return res.status(400).json({ success: false, error: 'Client name is required' });
        }
        const result = await clientContactsFb.upsertClientContact({ name, oldName, phone, phones, address, gstin });
        console.log(`[PUT /api/clients/contact] Result: ${JSON.stringify(result)}`);
        invalidateApiCache();
        res.json(result);
    } catch (err) {
        console.error('[PUT /api/clients/contact] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});


app.get('/api/orders/next-lot', async (req, res) => {
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

app.get('/api/orders/ledger-clients', async (req, res) => {
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

app.get('/api/orders/client-summary', async (req, res) => {
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

app.get('/api/orders/sales-summary', authenticateToken, async (req, res) => {
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

app.get('/api/orders/by-grade', authenticateToken, async (req, res) => {
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

app.get('/api/orders/pending', authenticateToken, async (req, res) => {
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

app.get('/api/orders/today-cart', authenticateToken, async (req, res) => {
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

app.post('/api/orders/add-to-cart', authenticateToken, requireAdmin, async (req, res) => {
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

app.post('/api/orders/remove-from-cart', authenticateToken, requireAdmin, async (req, res) => {
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

app.post('/api/orders/batch-remove-from-cart', authenticateToken, requireAdmin, async (req, res) => {
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

app.post('/api/orders/archive-cart', authenticateToken, requireAdmin, async (req, res) => {
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

// ========== Transport Assignments (daily client→transport mapping) ==========

app.get('/api/orders/transport-assignments', authenticateToken, async (req, res) => {
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

app.put('/api/orders/transport-assignments', authenticateToken, async (req, res) => {
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
        // Broadcast to all connected clients so other users see the update
        if (global.io) {
            global.io.emit('transport-assignments-updated', { date, updatedBy: username });
        }
        res.json({ success: true });
    } catch (err) {
        console.error('[PUT /api/orders/transport-assignments]', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.post('/api/orders/partial-dispatch', authenticateToken, requireAdmin, async (req, res) => {
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

// Debug endpoints: Firestore collections use fixed schema
app.get('/api/debug/orderbook-headers', authenticateToken, requireAdmin, (req, res) => {
    const headers = ['Order Date', 'Billing From', 'Client', 'Lot', 'Grade', 'Bag / Box', 'No', 'Kgs', 'Price', 'Brand', 'Status', 'Notes'];
    res.json({
        headers,
        source: 'Firestore (fixed schema)',
        billingFromIndex: 1,
    });
});

app.get('/api/debug/cart-headers', authenticateToken, requireAdmin, (req, res) => {
    const headers = ['Order Date', 'Billing From', 'Client', 'Lot', 'Grade', 'Bag / Box', 'No', 'Kgs', 'Price', 'Brand', 'Status', 'Notes', 'Packed Date'];
    res.json({
        headers,
        headerCount: headers.length,
        source: 'Firestore (fixed schema)',
        bagboxColumnIndex: 5,
        bagboxColumnName: 'Bag / Box',
    });
});

// Cancel partial dispatch and merge back
app.post('/api/orders/cancel-partial-dispatch', authenticateToken, requireAdmin, async (req, res) => {
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

// Admin
app.post('/api/admin/recalc', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await admin.recalcDeltaFromMenu();
        await audit.logAction(req.user.username || 'Unknown', 'ADMIN_RECALC', 'Recalculated delta from menu', {});
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.post('/api/admin/rebuild', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await admin.rebuildFromScratchFromMenu();
        await audit.logAction(req.user.username || 'Unknown', 'ADMIN_REBUILD', 'Rebuilt database from scratch', {});
        res.json({ message: result });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.post('/api/admin/reset-pointer', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await admin.resetDeltaPointerFromMenu();
        await audit.logAction(req.user.username || 'Unknown', 'ADMIN_RESET_POINTER', 'Reset delta pointer', {});
        res.json({ message: result });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.get('/api/admin/pointer', authenticateToken, requireAdmin, (req, res) => {
    try {
        const result = admin.showDeltaPointer();
        res.json({ message: result });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Integrity Check API - Double-counting prevention
app.get('/api/admin/integrity', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const report = await orderBook.getIntegrityReport();
        res.json({ success: true, report });
    } catch (err) {
        console.error('[IntegrityCheck] API Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.get('/api/admin/integrity/overlaps', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await orderBook.validateNoOrderOverlap();
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[IntegrityCheck] Overlap API Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Phase 2: Sale Order Validation
app.get('/api/admin/integrity/sale-order', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await orderBook.validateSaleOrderIntegrity();
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[IntegrityCheck] Sale order validation error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Order Quantity Integrity - verifies sale_order matches orders, packed_sale matches packed_orders
app.get('/api/admin/integrity/order-quantities', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await stockCalc.verifyOrderIntegrity();
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[IntegrityCheck] Order quantity verification error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Phase 4: Checksum Management
app.get('/api/admin/integrity/checksums', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await orderBook.validateChecksums();
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[IntegrityCheck] Checksum validation error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.post('/api/admin/integrity/checksums/store', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const checksums = await orderBook.storeChecksums();
        await audit.logAction(req.user.username || 'Unknown', 'STORE_CHECKSUMS', 'Stored integrity checksums', {});
        res.json({ success: true, message: 'Checksums stored successfully', checksums });
    } catch (err) {
        console.error('[IntegrityCheck] Store checksum error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Phase 3: Audit Log
app.get('/api/admin/audit-log', authenticateToken, requireAdmin, async (req, res) => {
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

// Sync all Firestore orders → Google Sheets "AllOrders" tab
app.post('/api/admin/sync-allorders', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const { syncAllOrders } = require('./backend/scripts/sync_all_orders_to_sheet');
        const summary = await syncAllOrders();
        await audit.logAction(req.user.username || 'Unknown', 'SYNC_ALL_ORDERS', 'Synced all orders to sheets', summary);
        res.json({ success: true, ...summary });
    } catch (err) {
        console.error('[SyncAllOrders] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Authentication - Login endpoint (PUBLIC - no auth required)
app.post('/api/auth/login', async (req, res) => {
    try {
        const { username, password } = req.body;
        if (!username || !password) {
            return res.status(400).json({ success: false, error: 'Username and password are required' });
        }
        const result = await users.authenticateUser(username, password);
        if (result.success) {
            // Generate JWT token for authenticated user
            const token = generateToken(result.user);
            res.json({
                success: true,
                user: result.user,
                token: token,  // Return JWT token to client
                mustChangePassword: result.user.mustChangePassword || false
            });
        } else {
            res.status(401).json(result);
        }
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Face login endpoint — verifies face server-side, returns JWT
app.post('/api/auth/face-login', async (req, res) => {
    try {
        const { username, faceData } = req.body;
        if (!username || !faceData || typeof faceData !== 'object') {
            return res.status(400).json({ success: false, error: 'Username and face data are required' });
        }

        // Fetch user by username
        const user = await users.getUserByUsername(username);
        if (!user) {
            return res.status(401).json({ success: false, error: 'User not found' });
        }

        // Fetch stored face data
        const storedFaceData = await users.getUserFaceData(user.id);
        if (!storedFaceData || Object.keys(storedFaceData).length === 0) {
            return res.status(401).json({ success: false, error: 'No face data enrolled for this user' });
        }

        // Server-side cosine similarity verification
        const scanKeys = Object.keys(faceData);
        const storedKeys = Object.keys(storedFaceData);
        const isMeshScan = scanKeys.includes('leftEyeWidth');
        const isStoredMesh = storedKeys.includes('leftEyeWidth');

        let compareKeys, threshold;
        if (isMeshScan && isStoredMesh) {
            compareKeys = [
                'leftEyeWidth', 'rightEyeWidth', 'leftEyeHeight', 'rightEyeHeight',
                'leftBrowWidth', 'rightBrowWidth', 'leftBrowToEye', 'rightBrowToEye',
                'noseLength', 'noseWidth', 'noseTipToLeftEye', 'noseTipToRightEye',
                'mouthWidth', 'mouthHeight', 'noseToMouth',
                'faceWidth', 'faceHeight', 'chinToMouth', 'foreheadToNose', 'foreheadToBrow',
                'eyeWidthRatio', 'browWidthRatio', 'noseToFaceWidth', 'mouthToFaceWidth',
            ];
            threshold = 0.95;
        } else {
            compareKeys = ['noseTipToLeftEye', 'noseTipToRightEye', 'mouthWidth', 'noseToMouth', 'faceWidth', 'mouthToFaceWidth'];
            threshold = 0.88;
        }

        // Mean Relative Error — measures actual geometric differences.
        // Cosine similarity returns ~0.99 for ALL faces on positive vectors,
        // making it useless. MRE yields ~0.93-0.97 for same person and
        // ~0.75-0.85 for different people, making thresholds effective.
        let totalRelErr = 0, matched = 0;
        for (const k of compareKeys) {
            const a = Number(faceData[k]) || 0;
            const b = Number(storedFaceData[k]) || 0;
            if (a === 0 || b === 0) continue;
            const mean = (a + b) / 2.0;
            if (mean > 0) {
                totalRelErr += Math.abs(a - b) / mean;
                matched++;
            }
        }

        const minKeys = (isMeshScan && isStoredMesh) ? 8 : 3;
        if (matched < minKeys) {
            return res.status(401).json({ success: false, error: 'Insufficient face data for verification' });
        }

        const similarity = 1.0 - (totalRelErr / matched);
        console.log(`[FaceLogin] User: ${username}, similarity: ${(similarity * 100).toFixed(1)}%, threshold: ${(threshold * 100).toFixed(0)}%, keys: ${matched}/${compareKeys.length}`);

        if (similarity < threshold) {
            return res.status(401).json({ success: false, error: 'Face verification failed' });
        }

        // Generate JWT and return same format as password login
        const token = generateToken(user);
        res.json({
            success: true,
            user: user,
            token: token,
            mustChangePassword: user.mustChangePassword || false,
        });
    } catch (err) {
        console.error('[FaceLogin] Error:', err);
        res.status(500).json({ success: false, error: 'Face login error' });
    }
});

// Change password endpoint
app.post('/api/auth/change-password', async (req, res) => {
    try {
        const { currentPassword, newPassword } = req.body;

        if (!currentPassword || !newPassword) {
            return res.status(400).json({ success: false, error: 'Current password and new password are required' });
        }

        // Validate new password complexity: min 8 chars, 1 uppercase, 1 lowercase, 1 digit
        const passwordRegex = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}$/;
        if (!passwordRegex.test(newPassword)) {
            return res.status(400).json({
                success: false,
                error: 'Password must be at least 8 characters with 1 uppercase, 1 lowercase, and 1 digit'
            });
        }

        // Prevent reuse of the same password
        if (currentPassword === newPassword) {
            return res.status(400).json({ success: false, error: 'New password must be different from current password' });
        }

        const result = await users.changePassword(req.user.username, currentPassword, newPassword);
        if (result.success) {
            res.json({ success: true, message: 'Password changed successfully' });
        } else {
            res.status(400).json(result);
        }
    } catch (err) {
        console.error('[POST /api/auth/change-password] Error:', err);
        res.status(500).json({ success: false, error: 'Failed to change password' });
    }
});

// ========== ADMIN SETTINGS API ==========

// Get notification numbers (any authenticated user — needed for order sharing)
app.get('/api/admin/settings/notification-numbers', authenticateToken, async (req, res) => {
    try {
        const data = await settingsFb.getNotificationNumbers();
        res.json({ success: true, ...data });
    } catch (err) {
        console.error('[GET /api/admin/settings/notification-numbers] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Update notification numbers
app.put('/api/admin/settings/notification-numbers', authenticateToken, requireAdmin, async (req, res) => {
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

// User Management
app.get('/api/users', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const userList = await users.getAllUsers();
        res.json({ success: true, users: userList });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ====== USER FACE LOGIN ROUTES (must be before /api/users/:id) ======

// Get all user face data (PUBLIC - used pre-authentication for face login matching)
app.get('/api/users/face-data/all', async (req, res) => {
    try {
        const data = await users.getAllUserFaceData();
        res.json(data);
    } catch (err) {
        console.error('[FaceLogin] Get all user face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Store face data for current user (requires auth)
app.post('/api/users/me/face-data', authenticateToken, async (req, res) => {
    try {
        const { faceData } = req.body;
        if (!faceData) return res.status(400).json({ success: false, error: 'faceData is required' });
        const userId = req.user.id || req.user.userId;
        const result = await users.storeUserFaceData(userId, faceData);
        res.json(result);
    } catch (err) {
        console.error('[FaceLogin] Store user face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get face data for current user (requires auth)
app.get('/api/users/me/face-data', authenticateToken, async (req, res) => {
    try {
        const userId = req.user.id || req.user.userId;
        const data = await users.getUserFaceData(userId);
        res.json({ faceData: data });
    } catch (err) {
        console.error('[FaceLogin] Get user face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Store face data for a specific user (admin only)
app.post('/api/users/:id/face-data', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const { faceData } = req.body;
        if (!faceData) return res.status(400).json({ success: false, error: 'faceData is required' });
        const result = await users.storeUserFaceData(req.params.id, faceData);
        res.json(result);
    } catch (err) {
        console.error('[FaceLogin] Store user face data by ID error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get face data for a specific user (admin only)
app.get('/api/users/:id/face-data', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const data = await users.getUserFaceData(req.params.id);
        res.json({ faceData: data });
    } catch (err) {
        console.error('[FaceLogin] Get user face data by ID error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete face data for current user (requires auth)
app.delete('/api/users/me/face-data', authenticateToken, async (req, res) => {
    try {
        const userId = req.user.id || req.user.userId;
        await users.clearUserFaceData(userId);
        res.json({ success: true });
    } catch (err) {
        console.error('[FaceLogin] Delete own face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete face data for a specific user (admin only)
app.delete('/api/users/:id/face-data', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const cleared = await users.clearUserFaceData(req.params.id);
        if (!cleared) return res.status(404).json({ success: false, error: 'User not found' });
        res.json({ success: true });
    } catch (err) {
        console.error('[FaceLogin] Delete user face data by ID error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.get('/api/users/:id', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const user = await users.getUserById(req.params.id);
        if (!user) {
            return res.status(404).json({ success: false, error: 'User not found' });
        }
        res.json({ success: true, user });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.post('/api/users', authenticateToken, requireAdmin, async (req, res) => {
    console.log(`[API] POST /api/users request received: ${req.body.username}`);
    try {
        const { username, email, role, password, clientName, fullName, pageAccess } = req.body;
        if (!username) {
            return res.status(400).json({ success: false, error: 'Username is required' });
        }
        if (password && password.length < 6) {
            return res.status(400).json({ success: false, error: 'Password must be at least 6 characters' });
        }

        // Check if username already exists
        console.log(`[API] Checking existing user: ${username}`);
        const existingUser = await users.getUserByUsername(username);
        if (existingUser) {
            console.log(`[API] User already exists: ${username}`);
            return res.status(400).json({ success: false, error: 'Username already exists' });
        }

        console.log(`[API] Adding new user: ${username}`);
        const result = await users.addUser({ username, email, role, password, clientName, fullName, pageAccess });

        console.log(`[API] Add user result:`, result.success);
        if (result.success) {
            res.json(result);
        } else {
            res.status(500).json(result);
        }
    } catch (err) {
        console.error('[API] Error in POST /api/users:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.put('/api/users/:id', authenticateToken, requireAdmin, async (req, res) => {
    console.log(`[API] PUT /api/users/${req.params.id} request received`);
    try {
        const { username, email, role, password, clientName, fullName, pageAccess } = req.body;
        const callerRole = req.user.role?.toLowerCase();

        // Only superadmin can edit admin/superadmin/ops users
        const targetUser = await users.getUserById(req.params.id);
        if (targetUser) {
            const targetRole = targetUser.role?.toLowerCase();
            if (['superadmin', 'admin', 'ops'].includes(targetRole) && callerRole !== 'superadmin') {
                return res.status(403).json({ success: false, error: 'Only Super Admin can modify admin users' });
            }
        }
        // Only superadmin can assign superadmin/admin roles
        if (['superadmin', 'admin'].includes(role?.toLowerCase()) && callerRole !== 'superadmin') {
            return res.status(403).json({ success: false, error: 'Only Super Admin can assign admin roles' });
        }

        const result = await users.updateUser(req.params.id, { username, email, role, password, clientName, fullName, pageAccess });

        console.log(`[API] Update user result:`, result.success);
        if (result.success) {
            res.json(result);
        } else {
            res.status(404).json(result);
        }
    } catch (err) {
        console.error('[API] Error in PUT /api/users:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.delete('/api/users/:id', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await users.deleteUser(req.params.id);
        if (result.success) {
            res.json(result);
        } else {
            res.status(400).json(result);
        }
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// =============================================
// FCM Push Notification Token Management
// =============================================

app.post('/api/users/fcm-token', authenticateToken, async (req, res) => {
    try {
        const { token } = req.body;
        if (!token) return res.status(400).json({ success: false, error: 'Token is required' });
        await users.addFcmToken(req.user.id, token);
        res.json({ success: true });
    } catch (err) {
        console.error('[FCM] Register token error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.delete('/api/users/fcm-token', authenticateToken, async (req, res) => {
    try {
        const { token } = req.body;
        if (!token) return res.status(400).json({ success: false, error: 'Token is required' });
        await users.removeFcmToken(req.user.id, token);
        res.json({ success: true });
    } catch (err) {
        console.error('[FCM] Remove token error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// FCM diagnostic — check registered tokens for all admins
app.get('/api/users/fcm-diagnostics', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const tokens = await users.getAdminFcmTokens(-1); // -1 = don't exclude anyone
        const allAdmins = await users.getAllUsers();
        const adminUsers = allAdmins.filter(u => ['admin', 'superadmin', 'ops'].includes(u.role));
        const diagnostics = adminUsers.map(u => ({
            username: u.username,
            role: u.role,
            tokenCount: Array.isArray(u.fcmTokens) ? u.fcmTokens.flat().filter(t => typeof t === 'string' && t.length > 0).length : 0,
            hasTokens: Array.isArray(u.fcmTokens) && u.fcmTokens.flat().filter(t => typeof t === 'string' && t.length > 0).length > 0,
        }));
        res.json({
            success: true,
            totalTokens: tokens.length,
            admins: diagnostics,
        });
    } catch (err) {
        console.error('[FCM] Diagnostics error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Client Requests API
// Create a new client request
app.post('/api/client-requests', requireClient, async (req, res) => {
    try {
        const { requestType, items, initialStatus, sourceRequestId } = req.body;
        const initialMessage = req.body.initialMessage || req.body.initialText;
        // Extract username from JWT (secure) - ignore body values
        const { username } = getUserFromRequest(req);

        if (!username) {
            return res.status(400).json({ success: false, error: 'Username is required' });
        }

        // Get clientName from user profile in DB
        let finalClientName = req.body.clientName;
        if (!finalClientName) {
            const user = await users.getUserByUsername(username);
            if (user && user.clientName) {
                finalClientName = user.clientName;
            } else {
                finalClientName = username; // Fallback to username
            }
        }

        const result = await clientRequests.createClientRequest({
            clientUsername: username,
            clientName: finalClientName,
            requestType,
            items,
            initialText: initialMessage,
            initialStatus,
            sourceRequestId
        });

        res.json(result);
    } catch (err) {
        console.error('[POST /api/client-requests] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get requests for current client
app.get('/api/client-requests/my', requireClient, async (req, res) => {
    try {
        // Extract username from JWT (secure)
        const { username } = getUserFromRequest(req);

        if (!username) {
            return res.status(400).json({ success: false, error: 'Username is required' });
        }

        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await clientRequests.getRequestsForClientPaginated(username, { limit, cursor });
            return res.json({ success: true, requests: result.data, pagination: result.pagination });
        }
        const requests = await clientRequests.getRequestsForClient(username);
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[GET /api/client-requests/my] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get all requests (admin only)
app.get('/api/client-requests', requireAdmin, async (req, res) => {
    try {
        const { status, client, type } = req.query;

        const filters = {};
        if (status) filters.status = status;
        if (client) filters.client = client; // Changed to client for name matching
        if (type) filters.type = type;

        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await clientRequests.getRequestsForAdminPaginated({ limit, cursor, filters });
            return res.json({ success: true, requests: result.data, pagination: result.pagination });
        }
        const requests = await clientRequests.getRequestsForAdmin(filters);
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[GET /api/client-requests] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Send a chat message
app.post('/api/client-requests/:requestId/chat', async (req, res) => {
    try {
        const { requestId } = req.params;
        const { messageType, message, payload } = req.body;
        // Extract username and role from JWT (secure)
        const { username, role } = getUserFromRequest(req);

        if (!username || !role) {
            return res.status(400).json({ success: false, error: 'Username and role are required' });
        }

        // Authorization: only the request owner (client) or admin/ops can post
        const normalRole = role.toLowerCase();
        if (!['admin', 'superadmin', 'ops'].includes(normalRole)) {
            const requestMeta = await clientRequests.getRequestMeta(requestId);
            if (requestMeta.clientUsername !== username) {
                return res.status(403).json({ success: false, error: 'Not authorized to post to this request' });
            }
        }

        const senderRole = role === 'client' ? 'CLIENT' : 'ADMIN';

        const result = await clientRequests.appendChatMessage({
            requestId,
            senderRole,
            senderUsername: username,
            messageType: messageType || 'TEXT',
            message,
            payload
        });

        res.json(result);
    } catch (err) {
        console.error('[POST /api/client-requests/:requestId/chat] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Save agreed items (admin only)
app.post('/api/client-requests/:requestId/agreed-items', requireAdmin, async (req, res) => {
    try {
        const { requestId } = req.params;
        const { agreedItems } = req.body;

        if (!agreedItems || !Array.isArray(agreedItems)) {
            return res.status(400).json({ success: false, error: 'agreedItems must be an array' });
        }

        const result = await clientRequests.saveAgreedItems(requestId, agreedItems);

        // Also append a system chat message
        await clientRequests.appendChatMessage({
            requestId,
            senderRole: 'ADMIN',
            senderUsername: 'system',
            messageType: 'SYSTEM',
            message: 'Admin has marked these items as agreed with prices.'
        });

        res.json(result);
    } catch (err) {
        console.error('[POST /api/client-requests/:requestId/agreed-items] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});



// Update request status (admin only)
app.post('/api/client-requests/:requestId/status', requireAdmin, async (req, res) => {
    try {
        const { requestId } = req.params;
        const { status } = req.body;

        if (!status) {
            return res.status(400).json({ success: false, error: 'status is required' });
        }

        const result = await clientRequests.updateRequestStatus(requestId, status);

        // Append a system chat message
        const statusMessages = {
            'NEGOTIATING': 'Admin has started negotiations.',
            'REJECTED': 'Admin has rejected this request.',
            'CANCELLED': 'This request has been cancelled.',
            'AGREED': 'Admin has agreed to this request.'
        };

        if (statusMessages[status]) {
            await clientRequests.appendChatMessage({
                requestId,
                senderRole: 'ADMIN',
                senderUsername: 'system',
                messageType: 'SYSTEM',
                message: statusMessages[status]
            });
        }

        res.json(result);
    } catch (err) {
        console.error('[POST /api/client-requests/:requestId/status] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============================================================================
// PHASE 1: PANEL-BASED NEGOTIATION API ROUTES
// ============================================================================


// ============================================================================
// CLIENT ROUTES
// ============================================================================

// POST /api/client-requests (already exists, but ensure it uses new createClientRequest)
// GET /api/client-requests/my (already exists)

// GET /api/client-requests/:id - Get single request metadata
app.get('/api/client-requests/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { username, role } = getUserFromRequest(req);

        if (!username) {
            return res.status(400).json({ success: false, error: 'Username required' });
        }

        const requestMeta = await clientRequests.getRequestMeta(id);

        // Verify access
        if (role === 'client' && requestMeta.clientUsername !== username) {
            return res.status(403).json({ success: false, error: 'Access denied' });
        }

        res.json({ success: true, request: requestMeta });
    } catch (err) {
        console.error('[GET /api/client-requests/:id] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /api/client-requests/:id/chat - Get chat thread (with since parameter support)
app.get('/api/client-requests/:id/chat', async (req, res) => {
    try {
        const { id } = req.params;
        const { since } = req.query;

        // Extract username and role from JWT (secure)
        const { username: finalUsername, role: finalRole } = getUserFromRequest(req);

        if (!finalUsername) {
            return res.status(400).json({ success: false, error: 'Username required' });
        }

        const messages = await clientRequests.getChatThread(id, finalRole, finalUsername, since);
        res.json({ success: true, messages });
    } catch (err) {
        console.error('[GET /api/client-requests/:id/chat] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/client-requests/:id/bargain - Client starts bargaining
app.post('/api/client-requests/:id/bargain', requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { username } = getUserFromRequest(req);

        const result = await clientRequests.clientStartBargain(id);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/bargain] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/client-requests/:id/draft - Save draft panel (client)
app.post(['/api/client-requests/:id/draft', '/api/client-requests/:id/save-draft'], requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { panelDraft } = req.body;
        const { username } = getUserFromRequest(req);

        if (!panelDraft) {
            return res.status(400).json({ success: false, error: 'panelDraft required' });
        }

        const result = await clientRequests.saveDraftPanel(id, 'CLIENT', panelDraft);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/save-draft] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/client-requests/:id/send - Send panel message (client)
app.post(['/api/client-requests/:id/send', '/api/client-requests/:id/send-panel'], requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { panelSnapshot, optionalText } = req.body;
        const { username } = getUserFromRequest(req);

        if (!panelSnapshot) {
            return res.status(400).json({ success: false, error: 'panelSnapshot required' });
        }

        const result = await clientRequests.sendPanelMessage(id, 'CLIENT', username, panelSnapshot, optionalText);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/send-panel] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/client-requests/:id/confirm - Confirm request (client)
app.post('/api/client-requests/:id/confirm', requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { username } = getUserFromRequest(req);

        const result = await clientRequests.confirmRequest(id, 'CLIENT', username);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/confirm] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});



// POST /api/client-requests/:id/convert-to-order - Convert confirmed request to order (admin/ops only)
app.post('/api/client-requests/:id/convert-to-order', requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const { billingFrom, brand, orders } = req.body;

        const result = await clientRequests.convertConfirmedToOrder(id, billingFrom, brand, orders);
        res.json({ success: true, ...result });

        // Push notification to other admins (fire-and-forget)
        pushNotifications.notifyNewOrders(req.user.id, req.user.username || 'Admin', orders || [])
            .catch(err => console.error('[FCM] Push error (convert):', err.message));
    } catch (err) {
        console.error('[POST /api/client-requests/:id/convert-to-order] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/client-requests/:id/cancel - Cancel request (client)
app.post('/api/client-requests/:id/cancel', requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { reason } = req.body;
        const { username } = getUserFromRequest(req);

        const result = await clientRequests.cancelRequest(id, 'CLIENT', reason, username);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/cancel] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============================================================================
// ADMIN ROUTES
// ============================================================================

// GET /api/admin/client-requests - Get all requests (admin inbox with filters)
app.get('/api/admin/client-requests', requireAdmin, async (req, res) => {
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

// POST /api/admin/client-requests/:id/start-draft - Admin starts editing draft
app.post('/api/admin/client-requests/:id/start-draft', requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;

        const result = await clientRequests.adminStartDraft(id);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/start-draft] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/admin/client-requests/:id/draft - Save draft panel (admin)
app.post(['/api/admin/client-requests/:id/draft', '/api/admin/client-requests/:id/save-draft'], requireAdmin, async (req, res) => {
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

// POST /api/admin/client-requests/:id/send - Send panel message (admin)
app.post(['/api/admin/client-requests/:id/send', '/api/admin/client-requests/:id/send-panel'], requireAdmin, async (req, res) => {
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

// POST /api/admin/client-requests/:id/confirm - Confirm request (admin)
app.post('/api/admin/client-requests/:id/confirm', requireAdmin, async (req, res) => {
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

// POST /api/admin/client-requests/:id/cancel - Cancel request (admin)
app.post('/api/admin/client-requests/:id/cancel', requireAdmin, async (req, res) => {
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

// POST /api/admin/client-requests/:id/reinitiate - Reinitiate expired negotiation (admin)
app.post('/api/admin/client-requests/:id/reinitiate', requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const result = await clientRequests.reinitiateNegotiation(id, 'ADMIN');
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/admin/client-requests/:id/reinitiate] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/admin/client-requests/:id/convert - Convert confirmed request to order
app.post(['/api/admin/client-requests/:id/convert-to-order', '/api/admin/client-requests/:id/convert'], requireAdmin, async (req, res) => {
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

// ============================================================================
// REJECTED OFFERS ANALYTICS
// ============================================================================

// GET /api/analytics/rejected-offers - Query rejected offers with filters
app.get('/api/analytics/rejected-offers', requireAdmin, async (req, res) => {
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

// GET /api/analytics/rejected-offers/summary - Aggregated analytics
app.get('/api/analytics/rejected-offers/summary', requireAdmin, async (req, res) => {
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
app.get('/api/analytics/stock-forecast', authenticateToken, requireSuperAdmin, async (req, res) => {
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

app.get('/api/analytics/client-scores', authenticateToken, requireSuperAdmin, async (req, res) => {
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

app.get('/api/analytics/insights', authenticateToken, requireSuperAdmin, async (req, res) => {
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
app.get('/api/analytics/demand-trends', authenticateToken, requireSuperAdmin, async (req, res) => {
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

app.get('/api/analytics/seasonal-analysis', authenticateToken, requireSuperAdmin, async (req, res) => {
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

// AI Brain - Intelligent Decision Engine (superadmin only)
app.get('/api/ai/daily-briefing', authenticateToken, requireSuperAdmin, async (req, res) => {
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

app.get('/api/ai/grade-analysis/:grade', authenticateToken, requireSuperAdmin, async (req, res) => {
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

app.get('/api/ai/client-analysis/:name', authenticateToken, requireSuperAdmin, async (req, res) => {
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

app.get('/api/ai/recommendations', authenticateToken, requireSuperAdmin, async (req, res) => {
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

// Product Pricing - Phase 4.2 (superadmin only)
app.get('/api/analytics/suggested-prices', authenticateToken, requireSuperAdmin, async (req, res) => {
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

// Tasks
app.get('/api/tasks', async (req, res) => {
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

app.post('/api/tasks', requireAdmin, async (req, res) => {
    try {
        const result = await taskManager.createTask(req.body);
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.put('/api/tasks/:id', requireAdmin, async (req, res) => {
    try {
        const result = await taskManager.updateTask(req.params.id, req.body);
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.delete('/api/tasks/:id', requireAdmin, async (req, res) => {
    try {
        const result = await taskManager.deleteTask(req.params.id);
        res.json(result);
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.get('/api/tasks/stats', async (req, res) => {
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

// Audit Logs - Phase 4.3 (superadmin only)
app.get('/api/analytics/audit-logs', authenticateToken, requireSuperAdmin, async (req, res) => {
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

// =============================================
// APPROVAL REQUESTS API
// =============================================

// Create new approval request (for users)
app.post('/api/approval-requests', authenticateToken, async (req, res) => {
    try {
        const result = await approvalRequests.createRequest(req.body);

        // Emit to all admins about new approval request
        if (result.success && result.request) {
            io.to('admins').emit('approval:created', {
                request: result.request,
                requesterName: result.request.requesterName,
                actionType: result.request.actionType,
                resourceType: result.request.resourceType
            });
            console.log('📢 [Socket.IO] Emitted approval:created to admins');
            // Push notification for approval request
            pushNotifications.notifyApprovalRequest(
                result.request.requesterName,
                result.request.actionType,
                result.request.resourceType,
                result.request.summary || ''
            ).catch(err => console.error('[FCM] Approval push error:', err.message));
        }

        res.json(result);
    } catch (err) {
        console.error('[Approval Request] Create error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get all pending requests (admin only)
app.get('/api/approval-requests/pending', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const requests = await approvalRequests.getPendingRequests();
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[Approval Request] Pending error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get all requests (admin only)
app.get('/api/approval-requests', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/approval-requests?' + JSON.stringify(req.query);
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        let data;
        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await approvalRequests.getAllRequestsPaginated({ limit, cursor });
            data = { success: true, requests: result.data, pagination: result.pagination };
        } else {
            const requests = await approvalRequests.getAllRequests();
            data = { success: true, requests };
        }
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error('[Approval Request] Get all error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get user's own requests
app.get('/api/approval-requests/my/:userId', authenticateToken, async (req, res) => {
    try {
        // IDOR protection: users can only access their own requests (admins can access any)
        const userRole = req.user?.role?.toLowerCase();
        if (req.user && req.user.id !== req.params.userId && userRole !== 'admin' && userRole !== 'superadmin' && userRole !== 'ops') {
            return res.status(403).json({ success: false, error: 'Access denied' });
        }
        const includeDismissed = req.query.includeDismissed === 'true';
        console.log(`[Approval] Fetching MY REQUESTS for userId: ${req.params.userId}, includeDismissed: ${includeDismissed}`);
        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await approvalRequests.getUserRequestsPaginated(req.params.userId, { limit, cursor, includeDismissed });
            return res.json({ success: true, requests: result.data, pagination: result.pagination });
        }
        const requests = await approvalRequests.getUserRequests(req.params.userId, includeDismissed);
        console.log(`[Approval] Found ${requests.length} requests for userId: ${req.params.userId}`);
        if (requests.length > 0) {
            console.log(`[Approval] First request requesterId: ${requests[0].requesterId}`);
        }
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[Approval Request] User requests error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get pending count (for badge)
app.get('/api/approval-requests/count', authenticateToken, async (req, res) => {
    try {
        const count = await approvalRequests.getPendingCount();
        res.json({ success: true, count });
    } catch (err) {
        console.error('[Approval Request] Count error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Approve request (admin only) - also executes the action
app.put('/api/approval-requests/:id/approve', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const { adminId, adminName } = req.body;
        const adminRole = req.user?.role?.toLowerCase() || '';
        const result = await approvalRequests.approveRequest(req.params.id, adminId, adminName, adminRole);

        if (result.success && result.shouldExecute) {
            // Execute the approved action
            try {
                console.log(`[Approval] Execution: resourceType=${result.resourceType}, actionType=${result.actionType}`);
                console.log(`[Approval] resourceData:`, JSON.stringify(result.resourceData, null, 2));
                console.log(`[Approval] proposedChanges:`, JSON.stringify(result.proposedChanges, null, 2));

                if (result.resourceType === 'order') {
                    if (result.actionType === 'delete') {
                        await orderBook.deleteOrder(result.resourceId);
                    } else if (result.actionType === 'edit') {
                        await orderBook.updateOrder(result.resourceId, result.proposedChanges);
                    } else if (result.actionType === 'create' || result.actionType === 'new_order') {
                        // Create new order from resourceData or proposedChanges
                        const orderData = result.resourceData || result.proposedChanges;
                        console.log(`[Approval] Creating new order with data:`, JSON.stringify(orderData, null, 2));
                        await orderBook.addOrder(orderData);
                        console.log(`✅ [Approval] Created new order from approval request`);
                        // Push notification to admins about approved order creation
                        pushNotifications.notifyNewOrders(adminId, adminName || 'Admin', [orderData])
                            .catch(err => console.error('[FCM] Push error:', err.message));
                    }
                } else if (result.resourceType === 'stock' || result.resourceType === 'stock_adjustment' || result.resourceType === 'purchase') {
                    if (result.actionType === 'stock_adjustment' || result.actionType === 'edit' || result.actionType === 'adjust') {
                        // Stock adjustment: extract data from whichever format was used
                        const adjData = result.resourceData || result.proposedChanges?.adjustment || result.proposedChanges;
                        await stockCalc.addStockAdjustment({
                            ...adjData,
                            userRole: 'admin', // Approval grants admin-level execution
                            requesterName: adminName || 'admin',
                        });
                    } else if (result.actionType === 'add_purchase' || result.actionType === 'create') {
                        // Purchase addition
                        const purchaseData = result.proposedChanges || result.resourceData;
                        await stockCalc.addPurchase(purchaseData);
                        console.log(`✅ [Approval] Added purchase from approval request`);
                    }
                } else if (result.resourceType === 'expense') {
                    // Execute expense addition (uses Firestore expenses module from Phase 7)
                    if (result.actionType === 'add_expense' || result.actionType === 'create') {
                        const expenseData = result.proposedChanges || result.resourceData;
                        await expenses.saveExpenseSheet(expenseData.date, expenseData.items || [], expenseData.submittedBy);
                        console.log(`✅ [Approval] Added expense from approval request`);
                    }
                } else if (result.resourceType === 'gatepass') {
                    // Execute gatepass creation (uses Firestore gatepasses module from Phase 7)
                    if (result.actionType === 'create') {
                        await gatepasses.createGatePass(result.resourceData);
                        console.log(`✅ [Approval] Created gatepass from approval request`);
                    }
                }
                result.executed = true;
            } catch (execErr) {
                console.error(`❌ [Approval] Execution error:`, execErr);
                result.executed = false;
                result.executionError = execErr.message;
            }
        }

        // Emit to requester about approval
        if (result.success && result.request) {
            const requesterId = result.request.requesterId;
            const userData = connectedUsers.get(requesterId);
            if (userData) {
                io.to(userData.socketId).emit('approval:resolved', {
                    requestId: req.params.id,
                    status: 'approved',
                    adminName: adminName,
                    actionType: result.request.actionType,
                    executed: result.executed
                });
                console.log(`📢 [Socket.IO] Emitted approval:resolved (approved) to ${requesterId}`);
            }
            // Also emit to all admins to update their lists
            io.to('admins').emit('approval:updated', { requestId: req.params.id, status: 'approved' });
            // Push notification for approval resolved
            pushNotifications.notifyApprovalResolved(
                'approved', adminName,
                result.request.requesterName,
                result.request.actionType,
                result.request.resourceType,
                result.request.summary || ''
            ).catch(err => console.error('[FCM] Approval resolved push error:', err.message));
        }

        res.json(result);
    } catch (err) {
        console.error('[Approval Request] Approve error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Reject request (admin only)
app.put('/api/approval-requests/:id/reject', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const { adminId, adminName, reason, rejectionCategory } = req.body;
        const result = await approvalRequests.rejectRequest(req.params.id, adminId, adminName, reason, rejectionCategory);

        // Emit to requester about rejection
        if (result.success && result.request) {
            const requesterId = result.request.requesterId;
            const userData = connectedUsers.get(requesterId);
            if (userData) {
                io.to(userData.socketId).emit('approval:resolved', {
                    requestId: req.params.id,
                    status: 'rejected',
                    adminName: adminName,
                    reason: reason,
                    actionType: result.request.actionType
                });
                console.log(`📢 [Socket.IO] Emitted approval:resolved (rejected) to ${requesterId}`);
            }
            // Also emit to all admins to update their lists
            io.to('admins').emit('approval:updated', { requestId: req.params.id, status: 'rejected' });
            // Push notification for rejection
            pushNotifications.notifyApprovalResolved(
                'rejected', adminName,
                result.request.requesterName,
                result.request.actionType,
                result.request.resourceType,
                reason || ''
            ).catch(err => console.error('[FCM] Rejection push error:', err.message));
        }

        res.json(result);
    } catch (err) {
        console.error('[Approval Request] Reject error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Dismiss a resolved request (hide from user's view after reading)
app.put('/api/approval-requests/:id/dismiss', authenticateToken, async (req, res) => {
    try {
        console.log(`[Approval] Dismissing request ${req.params.id}`);
        const result = await approvalRequests.dismissRequest(req.params.id);
        res.json(result);
    } catch (err) {
        console.error('[Approval Request] Dismiss error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ==================== WORKERS & ATTENDANCE API ====================

// Get all workers
app.get('/api/workers', async (req, res) => {
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
app.get('/api/workers/search', async (req, res) => {
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
app.get('/api/workers/teams', async (req, res) => {
    try {
        const teams = await workersAttendance.getWorkerTeams();
        res.json(teams);
    } catch (err) {
        console.error('[Workers] Teams error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Add new worker
app.post('/api/workers', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.addWorker(req.body);
        res.json(result);
    } catch (err) {
        console.error('[Workers] Add error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Force add worker (skip duplicate check)
app.post('/api/workers/force', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.forceAddWorker(req.body);
        res.json(result);
    } catch (err) {
        console.error('[Workers] Force add error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Update worker
app.put('/api/workers/:id', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.updateWorker(req.params.id, req.body);
        res.json(result);
    } catch (err) {
        console.error('[Workers] Update error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete worker (soft delete - marks as Inactive)
app.delete('/api/workers/:id', requireAdmin, async (req, res) => {
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
app.get('/api/workers/face-data', requireAdmin, async (req, res) => {
    try {
        const data = await workersAttendance.getAllFaceData();
        res.json(data);
    } catch (err) {
        console.error('[Face] Get all face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Store face data for a worker (enrollment)
app.post('/api/workers/:workerId/face-data', requireAdmin, async (req, res) => {
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
app.delete('/api/workers/:workerId/face-data', requireAdmin, async (req, res) => {
    try {
        const result = await workersAttendance.clearFaceData(req.params.workerId);
        res.json(result);
    } catch (err) {
        console.error('[Face] Delete worker face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Mark attendance via face scan
app.post('/api/attendance/face-mark', authenticateToken, async (req, res) => {
    try {
        const result = await workersAttendance.markAttendance(req.body);
        res.json(result);
    } catch (err) {
        console.error('[Face] Face attendance error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get attendance for a date range (wage calculation)
app.get('/api/attendance/range', authenticateToken, async (req, res) => {
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
app.get('/api/attendance/:date', authenticateToken, async (req, res) => {
    try {
        const attendance = await workersAttendance.getAttendanceByDate(req.params.date);
        res.json(attendance);
    } catch (err) {
        console.error('[Attendance] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get attendance summary for a date
app.get('/api/attendance/:date/summary', authenticateToken, async (req, res) => {
    try {
        const summary = await workersAttendance.getAttendanceSummary(req.params.date);
        res.json(summary);
    } catch (err) {
        console.error('[Attendance] Summary error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Mark attendance
app.post('/api/attendance', authenticateToken, async (req, res) => {
    try {
        const result = await workersAttendance.markAttendance(req.body);
        res.json(result);
    } catch (err) {
        console.error('[Attendance] Mark error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Remove attendance record
app.delete('/api/attendance/:date/:workerId', authenticateToken, async (req, res) => {
    try {
        const result = await workersAttendance.removeAttendance(req.params.date, req.params.workerId);
        res.json(result);
    } catch (err) {
        console.error('[Attendance] Remove error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Copy previous day's workers
app.post('/api/attendance/copy-previous', authenticateToken, async (req, res) => {
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
app.get('/api/attendance/calendar/:year/:month', authenticateToken, async (req, res) => {
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
app.get('/api/attendance/:date/lock-status', authenticateToken, async (req, res) => {
    try {
        const lockStatus = workersAttendance.isRecordLocked(req.params.date);
        res.json(lockStatus);
    } catch (err) {
        console.error('[Attendance] Lock status error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ========== EXPENSES API ==========
// Use the expenses router for all expense-related endpoints
app.use('/api/expenses', authenticateToken, expenses.router);

// Initialize expense sheets on startup
expenses.initExpenseSheets().catch(console.error);

// ========== GATE PASSES API ==========
// Use the gate passes router for all gate pass endpoints
app.use('/api/gate-passes', authenticateToken, gatepasses.router);

// Initialize gate passes sheet on startup
gatepasses.initGatePassesSheet().catch(console.error);

// ========== DISPATCH DOCUMENTS API ==========
app.use('/api/dispatch-documents', authenticateToken, dispatchDocuments.router);

// ========== TRANSPORT DOCUMENTS API ==========
app.use('/api/transport-documents', authenticateToken, transportDocuments.router);

// ========== PACKED BOXES API ==========
app.get('/api/packed-boxes/today', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const { date } = req.query;
        if (!date) return res.status(400).json({ success: false, error: 'date query param required' });
        const result = await packedBoxes.getTodayEntries(date);
        res.json(result);
    } catch (err) {
        console.error('[GET /api/packed-boxes/today] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.post('/api/packed-boxes/add', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const { date, grade, brand, boxesAdded } = req.body;
        if (!date || !grade || !brand || boxesAdded == null) {
            return res.status(400).json({ success: false, error: 'Missing required fields: date, grade, brand, boxesAdded' });
        }
        const addedBy = req.user?.username || req.user?.name || '';
        const result = await packedBoxes.addPackedBoxes(date, grade, brand, Number(boxesAdded), addedBy);
        res.json(result);
    } catch (err) {
        console.error('[POST /api/packed-boxes/add] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.put('/api/packed-boxes/bill', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const updatedBy = req.user?.username || req.user?.name || '';
        // Support batch updates: { entries: [{grade, brand, billed, date}, ...] }
        if (req.body.entries && Array.isArray(req.body.entries)) {
            const results = [];
            for (const entry of req.body.entries) {
                const { date, grade, brand, billed } = entry;
                if (!date || !grade || !brand || billed == null) continue;
                const result = await packedBoxes.updateBilledBoxes(date, grade, brand, Number(billed), updatedBy);
                results.push(result);
            }
            return res.json({ success: true, results });
        }
        // Single update fallback
        const { date, grade, brand, boxesBilled } = req.body;
        if (!date || !grade || !brand || boxesBilled == null) {
            return res.status(400).json({ success: false, error: 'Missing required fields: date, grade, brand, boxesBilled' });
        }
        const result = await packedBoxes.updateBilledBoxes(date, grade, brand, Number(boxesBilled), updatedBy);
        res.json(result);
    } catch (err) {
        console.error('[PUT /api/packed-boxes/bill] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.get('/api/packed-boxes/remaining', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await packedBoxes.getRemainingBoxes();
        res.json(result);
    } catch (err) {
        console.error('[GET /api/packed-boxes/remaining] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.get('/api/packed-boxes/history', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const { date } = req.query;
        if (!date) return res.status(400).json({ success: false, error: 'date query param required' });
        const result = await packedBoxes.getHistoryForDate(date);
        res.json(result);
    } catch (err) {
        console.error('[GET /api/packed-boxes/history] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.delete('/api/packed-boxes/:id', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const result = await packedBoxes.deletePackedBoxEntry(req.params.id);
        res.json(result);
    } catch (err) {
        console.error('[DELETE /api/packed-boxes/:id] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ========== NOTIFICATIONS API (Firestore-persisted) ==========
app.get('/api/notifications', authenticateToken, async (req, res) => {
    try {
        const db = require('./backend/firebaseClient').getDb();
        const snap = await db.collection('notifications')
            .where('read', '==', false)
            .orderBy('createdAt', 'desc')
            .limit(50)
            .get();
        const notifications = snap.docs.map(d => d.data());
        res.json({ success: true, notifications });
    } catch (err) {
        console.error('[Notifications] GET error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.post('/api/notifications/mark-read', authenticateToken, async (req, res) => {
    try {
        const db = require('./backend/firebaseClient').getDb();
        // Scope to current user's notifications only
        let query = db.collection('notifications').where('read', '==', false);
        if (req.user && req.user.id) {
            query = query.where('userId', '==', req.user.id);
        }
        const snap = await query.get();
        if (snap.empty) {
            return res.json({ success: true, count: 0 });
        }
        const batch = db.batch();
        snap.docs.forEach(doc => batch.update(doc.ref, { read: true }));
        await batch.commit();
        res.json({ success: true, count: snap.size });
    } catch (err) {
        console.error('[Notifications] mark-read error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ========== OFFER PRICE API ==========
app.use('/api/offers', authenticateToken, requireAdmin, offerPrice.router);

// ========== DATA INITIALIZATION ==========
if (users.initializeFromJson) {
    users.initializeFromJson().then(() => {
        console.log('[Server] User data migration check complete');
    }).catch(err => {
        console.error('[Server] User migration error:', err.message);
    });
}
if (taskManager.initializeFromJson) {
    taskManager.initializeFromJson().then(() => {
        console.log('[Server] Task data migration check complete');
    }).catch(err => {
        console.error('[Server] Task migration error:', err.message);
    });
}


// ========== REPORTS API ==========
// All report endpoints require JWT auth + admin/ops role

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
app.post('/api/reports/invoice', authenticateToken, requireAdmin,
    reportHandler('invoice', invoiceReport.generate, 'application/pdf',
        (params) => `invoice_${Date.now()}.pdf`));

// Dispatch Summary
app.post('/api/reports/dispatch-summary', authenticateToken, requireAdmin,
    reportHandler('dispatch-summary', dispatchReport.generate, 'application/pdf',
        (params) => `dispatch_${params.date || 'summary'}.pdf`));

// Stock Position
app.post('/api/reports/stock-position', authenticateToken, requireAdmin,
    reportHandler('stock-position', stockPositionReport.generate, contentTypeForFormat,
        (params, fmt) => `stock_position.${fmt === 'excel' ? 'xlsx' : 'pdf'}`));

// Stock Movement
app.post('/api/reports/stock-movement', authenticateToken, requireAdmin,
    reportHandler('stock-movement', stockMovementReport.generate,
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        (params) => `stock_movement_${params.startDate}_${params.endDate}.xlsx`));

// Client Statement
app.post('/api/reports/client-statement', authenticateToken, requireAdmin,
    reportHandler('client-statement', clientStatementReport.generate, 'application/pdf',
        (params) => `statement_${(params.client || 'client').replace(/\s+/g, '_')}.pdf`));

// Client Statement Bulk (ZIP)
app.post('/api/reports/client-statement/bulk', authenticateToken, requireAdmin,
    reportHandler('client-statement-bulk', clientStatementReport.generateBulk, 'application/zip',
        (params) => `client_statements_${params.startDate}_${params.endDate}.zip`));

// Sales Summary
app.post('/api/reports/sales-summary', authenticateToken, requireAdmin,
    reportHandler('sales-summary', salesSummaryReport.generate, contentTypeForFormat,
        (params, fmt) => `sales_summary_${params.startDate}_${params.endDate}.${fmt === 'excel' ? 'xlsx' : 'pdf'}`));

// Attendance
app.post('/api/reports/attendance', authenticateToken, requireAdmin,
    reportHandler('attendance', attendanceReport.generate,
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        (params) => `attendance_${params.month || 'report'}.xlsx`));

// Expenses
app.post('/api/reports/expenses', authenticateToken, requireAdmin,
    reportHandler('expenses', expenseReport.generate,
        (fmt) => fmt === 'monthly' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'application/pdf',
        (params) => params.type === 'monthly' ? `expenses_${params.month}.xlsx` : `expenses_${params.date}.pdf`));

// ==================== OUTSTANDING PAYMENTS ====================

app.get('/api/outstanding/check-date', authenticateToken, async (req, res) => {
    try {
        const dates = await outstanding.getOutstandingDates();
        res.json({ success: true, dates });
    } catch (err) {
        console.error('[Outstanding] check-date error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/outstanding/send-reminders
// Server-side image generation + WhatsApp send — app returns instantly.
app.post('/api/outstanding/send-reminders', authenticateToken, async (req, res) => {
    const { clients } = req.body;
    if (!Array.isArray(clients) || clients.length === 0) {
        return res.status(400).json({ success: false, error: 'clients array is required' });
    }
    const requestId = `pr_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
    console.log(`[${requestId}] Outstanding send-reminders: ${clients.length} client(s) queued`);

    // Respond immediately — processing continues in background
    res.json({ success: true, queued: clients.length, requestId });

    // --- Background processing ---
    const { generatePaymentImage } = require('./backend/services/payment_image_generator');
    const FormData = require('form-data');
    const axios = require('axios');

    // Meta Cloud API config — dual-number (primary sender)
    const META_WA_TOKEN = process.env.META_WHATSAPP_TOKEN;
    const META_ESPL_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;
    const META_SYGT_PHONE_ID = process.env.META_WHATSAPP_SYGT_PHONE_ID;
    const META_ESPL_NUMBER = '919790005649';
    const META_SYGT_NUMBER = '916006560069';
    const esplEnabled = !!(META_WA_TOKEN && META_ESPL_PHONE_ID);
    const sygtEnabled = !!(META_WA_TOKEN && META_SYGT_PHONE_ID);
    if (!sygtEnabled && !esplEnabled) {
        console.error(`[${requestId}] Meta Cloud API not configured — aborting background send`);
        return;
    }

    // SYGT WABA templates (primary: +916006560069)
    const SYGT_TEMPLATES = {
        payment_reminder_espl: 'payment_remind_espl_hx4923be67303fb2dfcff7f9894c232faf',
        payment_reminder_sygt: 'payment_remind_sygt_hx7e453c04aef926fea01ead62354f3833',
    };
    // ESPL WABA templates (secondary: +919790005649)
    const ESPL_TEMPLATES = {
        payment_reminder_espl: 'payment_reminder_espl_v3',
        payment_reminder_sygt: 'payment_reminder_sygt_v3',
    };

    let successCount = 0;
    let failCount = 0;

    for (const client of clients) {
        const phones = Array.isArray(client.phones) ? client.phones.filter(Boolean) : [];
        if (phones.length === 0) { failCount++; continue; }

        try {
            // 1. Generate image
            const pngBuffer = await generatePaymentImage(client);

            // 2. Upload to CDN
            let imageUrl;
            try {
                const form = new FormData();
                form.append('reqtype', 'fileupload');
                form.append('time', '24h');
                form.append('fileToUpload', pngBuffer, { filename: `pr_${Date.now()}.png`, contentType: 'image/png' });
                const uploadRes = await axios.post('https://litterbox.catbox.moe/resources/internals/api.php', form, { headers: form.getHeaders(), timeout: 15000 });
                imageUrl = uploadRes.data.trim();
            } catch (cdnErr) {
                // Fallback: local tmp
                const tmpDir = path.join(__dirname, 'public', 'tmp');
                if (!fs.existsSync(tmpDir)) fs.mkdirSync(tmpDir, { recursive: true });
                const localName = `pr_${Date.now()}.png`;
                const localPath = path.join(tmpDir, localName);
                fs.writeFileSync(localPath, pngBuffer);
                setTimeout(() => { try { fs.unlinkSync(localPath); } catch (_) { } }, 300000);
                const baseUrl = process.env.RENDER_EXTERNAL_URL || `http://localhost:${process.env.PORT || 3000}`;
                imageUrl = `${baseUrl}/tmp/${localName}`;
            }

            // 2b. Upload image to both WABAs for Cloud API template send
            let sygtMediaId = null;
            let esplMediaId = null;
            const uploadMedia = async (phoneId, label) => {
                try {
                    const mForm = new FormData();
                    mForm.append('messaging_product', 'whatsapp');
                    mForm.append('type', 'image/png');
                    mForm.append('file', pngBuffer, { filename: `pr_${Date.now()}.png`, contentType: 'image/png' });
                    const up = await axios.post(
                        `https://graph.facebook.com/v22.0/${phoneId}/media`,
                        mForm,
                        { headers: { ...mForm.getHeaders(), Authorization: `Bearer ${META_WA_TOKEN}` }, timeout: 15000 }
                    );
                    console.log(`[${requestId}] ${label} media uploaded: ${up.data.id}`);
                    return up.data.id;
                } catch (err) {
                    console.error(`[${requestId}] ${label} media upload failed: ${err.response?.data ? JSON.stringify(err.response.data) : err.message}`);
                    return null;
                }
            };
            if (sygtEnabled) sygtMediaId = await uploadMedia(META_SYGT_PHONE_ID, 'SYGT');
            if (esplEnabled) esplMediaId = await uploadMedia(META_ESPL_PHONE_ID, 'ESPL');

            // 3. Send WhatsApp to all phones
            const isESPL = (client.companyFull || client.company || '').toLowerCase().includes('emperor');
            const templateKey = isESPL ? 'payment_reminder_espl' : 'payment_reminder_sygt';
            const companyLabel = isESPL ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders';
            const sygtTemplateName = SYGT_TEMPLATES[templateKey];
            const esplTemplateName = ESPL_TEMPLATES[templateKey];
            const logBase = { clientName: client.sheetName || 'Customer', company: companyLabel, type: 'payment_reminder', requestId };

            // 3a. Send via SYGT WABA (+916006560069) — primary sender
            const sendViaSygt = async (phone) => {
                if (!sygtEnabled) return false;
                let clean = String(phone).replace(/\D/g, '');
                if (clean.length === 10) clean = `91${clean}`;
                if (clean === META_SYGT_NUMBER) return false;
                try {
                    const components = [{ type: 'body', parameters: [{ type: 'text', text: client.sheetName || 'Customer' }] }];
                    const imgParam = sygtMediaId ? { id: sygtMediaId } : (imageUrl ? { link: imageUrl } : null);
                    if (imgParam) components.unshift({ type: 'header', parameters: [{ type: 'image', image: imgParam }] });
                    const r = await axios.post(
                        `https://graph.facebook.com/v22.0/${META_SYGT_PHONE_ID}/messages`,
                        { messaging_product: 'whatsapp', to: clean, type: 'template', template: { name: sygtTemplateName, language: { code: 'en' }, components } },
                        { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
                    );
                    const wamid = r.data?.messages?.[0]?.id || '';
                    whatsappLogs.logSend({ ...logBase, recipient: clean, channel: 'meta-sygt', sender: META_SYGT_NUMBER, templateName: sygtTemplateName, status: 'accepted', messageId: wamid });
                    return true;
                } catch (err) {
                    console.error(`[PaymentReminder][SYGT] Failed for +${clean}: ${err.message}`);
                    whatsappLogs.logSend({ ...logBase, recipient: clean, channel: 'meta-sygt', sender: META_SYGT_NUMBER, templateName: sygtTemplateName, status: 'failed', error: err.message });
                    return false;
                }
            };

            // 3b. Send via ESPL WABA (+919790005649) — secondary sender
            const sendViaEspl = async (phone) => {
                if (!esplEnabled) return false;
                let clean = String(phone).replace(/\D/g, '');
                if (clean.length === 10) clean = `91${clean}`;
                if (clean === META_ESPL_NUMBER) return false;
                try {
                    const components = [{ type: 'body', parameters: [{ type: 'text', text: client.sheetName || 'Customer' }] }];
                    const imgParam = esplMediaId ? { id: esplMediaId } : (imageUrl ? { link: imageUrl } : null);
                    if (imgParam) components.unshift({ type: 'header', parameters: [{ type: 'image', image: imgParam }] });
                    const r = await axios.post(
                        `https://graph.facebook.com/v22.0/${META_ESPL_PHONE_ID}/messages`,
                        { messaging_product: 'whatsapp', to: clean, type: 'template', template: { name: esplTemplateName, language: { code: 'en' }, components } },
                        { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
                    );
                    const wamid = r.data?.messages?.[0]?.id || '';
                    whatsappLogs.logSend({ ...logBase, recipient: clean, channel: 'meta-espl', sender: META_ESPL_NUMBER, templateName: esplTemplateName, status: 'accepted', messageId: wamid });
                    return true;
                } catch (err) {
                    console.error(`[PaymentReminder][ESPL] Failed for +${clean}: ${err.message}`);
                    whatsappLogs.logSend({ ...logBase, recipient: clean, channel: 'meta-espl', sender: META_ESPL_NUMBER, templateName: esplTemplateName, status: 'failed', error: err.message });
                    return false;
                }
            };

            const sendToPhone = async (phone) => {
                const [sygtOk, esplOk] = await Promise.allSettled([
                    sendViaSygt(phone),
                    sendViaEspl(phone),
                ]);
                const sOk = sygtOk.status === 'fulfilled' && sygtOk.value === true;
                const eOk = esplOk.status === 'fulfilled' && esplOk.value === true;
                return sOk || eOk;
            };

            const results = await Promise.allSettled(phones.map(sendToPhone));
            const sent = results.filter(r => r.status === 'fulfilled' && r.value === true).length;
            if (sent > 0) successCount++; else failCount++;
            console.log(`[${requestId}] ${client.sheetName}: ${sent}/${phones.length} sent (SYGT+ESPL)`);
        } catch (err) {
            failCount++;
            console.error(`[${requestId}] ${client.sheetName}: error — ${err.message}`);
        }
    }

    console.log(`[${requestId}] Done: ${successCount} success, ${failCount} failed out of ${clients.length}`);
});

// ── WhatsApp Send Logs ──────────────────────────────────────────────────
app.get('/api/whatsapp-logs', authenticateToken, async (req, res) => {
    try {
        const filters = {};
        if (req.query.channel) filters.channel = req.query.channel;
        if (req.query.type) filters.type = req.query.type;
        if (req.query.status) filters.status = req.query.status;
        if (req.query.recipient) filters.recipient = req.query.recipient;
        if (req.query.limit) filters.limit = parseInt(req.query.limit);
        const logs = await whatsappLogs.getLogs(filters);
        res.json(logs);
    } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/whatsapp-logs/stats', authenticateToken, async (req, res) => {
    try {
        const stats = await whatsappLogs.getStats();
        res.json(stats);
    } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/outstanding', authenticateToken, async (req, res) => {
    try {
        const company = req.query.company || 'all';
        const cacheKey = `/api/outstanding?company=${company}`;
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const data = await outstanding.getOutstandingData(company);
        const result = { success: true, data };
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[Outstanding] GET error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.get('/api/outstanding/name-mappings', authenticateToken, async (req, res) => {
    try {
        const cached = getCachedResponse('/api/outstanding/name-mappings');
        if (cached) return res.json(cached);
        const mappings = await outstanding.getNameMappings();
        const result = { success: true, mappings };
        setCachedResponse('/api/outstanding/name-mappings', result);
        res.json(result);
    } catch (err) {
        console.error('[Outstanding] GET mappings error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.put('/api/outstanding/name-mapping', authenticateToken, requireAdmin, async (req, res) => {
    try {
        const { sheetName, company, firebaseClientName } = req.body;
        const result = await outstanding.saveNameMapping({ sheetName, company, firebaseClientName });
        invalidateApiCache();
        res.json(result);
    } catch (err) {
        console.error('[Outstanding] PUT mapping error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Admin debug endpoint: show current feature flag status
app.get('/api/admin/feature-flags', authenticateToken, requireAdmin, (req, res) => {
    res.json({ success: true, flags: featureFlags.getStatus() });
});

// Admin endpoint: pagination performance stats and cache hit rates
app.get('/api/admin/pagination-stats', authenticateToken, requireAdmin, (req, res) => {
    const { getQueryMetrics } = require('./backend/utils/paginate');
    const { dropdownCache, dashboardCache, countCache } = require('./backend/utils/cache');

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

// ==================== L1433: ACCESS RESTRICTION NOTIFICATION ====================
// When a user hits an access-restricted page, the app POSTs here to notify admins
app.post('/api/access-restriction-log', authenticateToken, async (req, res) => {
    try {
        // #57: Use JWT-sourced identity instead of trusting req.body
        const userId = req.user.userId || req.body.userId;
        const userName = req.user.username || req.body.userName;
        const userRole = req.user.role || req.body.userRole;
        const { pageKey, timestamp } = req.body;
        const { getDb } = require('./backend/firebaseClient');
        const db = getDb();
        const notifDoc = db.collection('notifications').doc();
        await notifDoc.set({
            id: notifDoc.id,
            userId: 'all_admins',
            title: 'Access Restriction Hit',
            body: `${userName || 'Unknown'} (${userRole || 'unknown'}) tried to access "${pageKey}" but was blocked.`,
            type: 'access_restriction',
            metadata: { blockedUserId: userId, pageKey, userRole, timestamp: timestamp || new Date().toISOString() },
            read: false,
            createdAt: new Date().toISOString(),
        });
        // Emit to all admins via Socket.IO
        io.to('admins').emit('access:restricted', { userId, userName, pageKey, userRole });
        res.json({ success: true });
    } catch (err) {
        console.error('[Access Restriction Log] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Serve frontend - root goes to index.html (Flutter entry point)
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Serve tmp files explicitly (WhatsApp image hosting) — prevent SPA catch-all from returning HTML
app.get('/tmp/:filename', (req, res) => {
    // Sanitize filename to prevent path traversal (e.g., ../../etc/passwd)
    const filename = path.basename(req.params.filename);
    if (filename !== req.params.filename || filename.includes('\0')) {
        return res.status(400).send('Invalid filename');
    }
    const filePath = path.join(__dirname, 'public', 'tmp', filename);
    if (fs.existsSync(filePath)) {
        res.setHeader('Content-Type', 'image/png');
        res.setHeader('Cache-Control', 'public, max-age=600');
        res.sendFile(filePath);
    } else {
        res.status(404).send('Not found');
    }
});

// Handle 404 for any route not matched above - redirect to index.html for SPA routing
app.use((req, res, next) => {
    // Only handle if response hasn't been sent yet
    if (res.headersSent) return;

    // If it's an API request that wasn't found, send 404
    if (req.path.startsWith('/api/')) {
        return res.status(404).json({ success: false, error: 'API endpoint not found' });
    }

    // Static asset requests (like /tmp/) should 404, not serve SPA HTML
    if (req.path.match(/\.(png|jpg|jpeg|gif|svg|ico|css|js|map|json|woff|woff2|ttf|eot)$/)) {
        return res.status(404).send('Not found');
    }

    // For everything else (likely SPA routes), serve index.html
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// ==================== SCHEDULED JOBS ====================

// L877: 24-hour escalation for pending approvals — runs every hour
const ESCALATION_INTERVAL = 60 * 60 * 1000; // 1 hour
async function escalatePendingApprovals() {
    try {
        const { getDb } = require('./backend/firebaseClient');
        const db = getDb();
        const pending = await approvalRequests.getPendingRequests();
        const now = Date.now();
        const TWENTY_FOUR_HOURS = 24 * 60 * 60 * 1000;
        let escalated = 0;

        for (const req of pending) {
            const createdAt = new Date(req.createdAt).getTime();
            if (now - createdAt > TWENTY_FOUR_HOURS && !req.escalated) {
                // Mark as escalated in the approval request
                await db.collection('approval_requests').doc(req.id).update({
                    escalated: true,
                    escalatedAt: new Date().toISOString(),
                });
                // Create escalation notification for all admins
                const notifDoc = db.collection('notifications').doc();
                await notifDoc.set({
                    id: notifDoc.id,
                    userId: 'all_admins',
                    title: 'Approval Overdue (24h+)',
                    body: `${req.actionType} request for ${req.resourceType} by ${req.requesterName || 'Unknown'} has been pending for >24 hours.`,
                    type: 'approval_escalation',
                    relatedRequestId: req.id,
                    read: false,
                    createdAt: new Date().toISOString(),
                });
                // Emit real-time alert to admins
                io.to('admins').emit('approval:escalation', {
                    requestId: req.id,
                    actionType: req.actionType,
                    resourceType: req.resourceType,
                    requesterName: req.requesterName,
                    pendingSince: req.createdAt,
                });
                escalated++;
            }
        }
        if (escalated > 0) {
            console.log(`⏰ [Escalation] Escalated ${escalated} pending approval(s) older than 24 hours`);
        }
    } catch (err) {
        console.error('[Escalation] Error checking pending approvals:', err.message);
    }
}

// L1513-1515: Stock drift auto-reconciliation — runs every 6 hours
const STOCK_RECONCILE_INTERVAL = 6 * 60 * 60 * 1000; // 6 hours
async function autoReconcileStockDrift() {
    try {
        console.log('[Stock Reconcile] Running 6-hour auto-reconciliation...');
        await stockCalc.updateAllStocks();
        const negatives = await stockCalc.detectNegativeStock();
        if (negatives.length > 0) {
            const { getDb } = require('./backend/firebaseClient');
            const db = getDb();
            const notifDoc = db.collection('notifications').doc();
            await notifDoc.set({
                id: notifDoc.id,
                userId: 'all_admins',
                title: 'Stock Drift Detected',
                body: `Auto-reconciliation found ${negatives.length} negative stock entries: ${negatives.slice(0, 3).map(n => `${n.grade} (${n.type}): ${n.value}kg`).join(', ')}${negatives.length > 3 ? '...' : ''}`,
                type: 'stock_drift',
                metadata: { negatives },
                read: false,
                createdAt: new Date().toISOString(),
            });
            io.to('admins').emit('stock:drift', { negatives });
            console.log(`⚠️ [Stock Reconcile] Found ${negatives.length} negative stock entries`);
        } else {
            console.log('[Stock Reconcile] No drift detected — stock is healthy');
        }
    } catch (err) {
        console.error('[Stock Reconcile] Error:', err.message);
    }
}

// Only start server when run directly (not when required by tests)
if (!module.parent && require.main === module) {
    httpServer.listen(PORT, '0.0.0.0', () => {
        console.log(`🚀 Server running on http://0.0.0.0:${PORT}`);
        console.log(`📱 Mobile access: http://172.20.10.4:${PORT}`);
        console.log(`🔌 WebSocket enabled: Socket.IO ready for real-time notifications`);
        console.log(`🔥 Backend: Firebase Firestore`);
        // Log feature flag status on startup
        featureFlags.logStatus();

        // Start scheduled jobs (delayed to not block startup)
        setTimeout(() => {
            setInterval(escalatePendingApprovals, ESCALATION_INTERVAL);
            setInterval(autoReconcileStockDrift, STOCK_RECONCILE_INTERVAL);
            escalatePendingApprovals();
            console.log('⏰ Scheduled: Approval escalation (1h), Stock reconciliation (6h)');
        }, 60000); // Delay 60s after startup to let server warm up first

        // Keepalive: self-ping every 14 min to prevent Render cold starts
        if (process.env.NODE_ENV === 'production' && process.env.RENDER_EXTERNAL_URL) {
            const keepaliveUrl = process.env.RENDER_EXTERNAL_URL + '/api/health';
            setInterval(() => {
                require('https').get(keepaliveUrl, () => {}).on('error', () => {});
            }, 14 * 60 * 1000);
            console.log('🏓 Keepalive ping enabled (14 min interval)');
        }
    });
}

// Export app for Supertest
module.exports = app;
