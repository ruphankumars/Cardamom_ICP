/**
 * Cardamom ICP Backend — Azle Server Entry Point
 *
 * Wraps the Express application inside Azle's experimental Server()
 * to run as an ICP canister. All ~190 API endpoints are mounted from
 * route modules extracted from the original server.js.
 */

import { Server, StableBTreeMap, preUpgrade } from 'azle/experimental';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
// express-rate-limit uses node:net which is unavailable in Azle WASM.
// Use a simple in-memory rate limiter instead.
function rateLimit(opts: { windowMs: number; max: number; message?: any; standardHeaders?: boolean; legacyHeaders?: boolean }) {
    const hits = new Map<string, { count: number; resetTime: number }>();
    return (req: any, res: any, next: any) => {
        // req.ip crashes on ICP (no real socket) — use header or fallback
        const key = req.headers['x-forwarded-for'] || req.headers['x-real-ip'] || 'icp-caller';
        const now = Date.now();
        let entry = hits.get(key);
        if (!entry || now > entry.resetTime) {
            entry = { count: 0, resetTime: now + opts.windowMs };
            hits.set(key, entry);
        }
        entry.count++;
        if (entry.count > opts.max) {
            return res.status(429).json(opts.message || { success: false, error: 'Too many requests' });
        }
        next();
    };
}
import { getDatabase, exportDatabase } from './database/sqliteClient';
const { initializeDatabase } = require('./database/init');
const { setStableStorage, persistNow } = require('./database/stableMemory');

// ---------------------------------------------------------------------------
// Stable Memory — persists SQLite database across canister upgrades
// ---------------------------------------------------------------------------
// Custom serializer for raw binary (Uint8Array) — avoids JSON overhead
const binarySerializer = {
    toBytes: (data: any) => {
        if (data instanceof Uint8Array) return data;
        if (typeof data === 'string') return new TextEncoder().encode(data);
        return new Uint8Array(0);
    },
    fromBytes: (bytes: Uint8Array) => bytes,
};
const stringSerializer = {
    toBytes: (data: any) => new TextEncoder().encode(String(data)),
    fromBytes: (bytes: Uint8Array) => new TextDecoder().decode(bytes),
};

// Memory ID 0 reserved for the SQLite database binary
const dbStorage = StableBTreeMap<string, Uint8Array>(0, stringSerializer, binarySerializer);

// Wire up stable storage for the persistence layer
setStableStorage({
    get(key: string) {
        return dbStorage.get(key);
    },
    set(key: string, value: any) {
        dbStorage.insert(key, value instanceof Uint8Array ? value : new Uint8Array(value));
    }
});

// Middleware
const { authenticateToken, requireAdmin } = require('../../backend/middleware/auth');
const { responseGuardrail } = require('../../backend/middleware/responseGuardrail');
const { cacheInvalidationMiddleware } = require('./middleware/apiCache');
const syncFb = require('../../backend/firebase/sync_fb');

// Route modules
const authRoutes = require('./routes/auth');
const ordersRoutes = require('./routes/orders');
const stockRoutes = require('./routes/stock');
const usersRoutes = require('./routes/users');
const workersRoutes = require('./routes/workers');
const attendanceRoutes = require('./routes/attendance');
const tasksRoutes = require('./routes/tasks');
const dropdownsRoutes = require('./routes/dropdowns');
const clientsRoutes = require('./routes/clients');
const clientRequestsRoutes = require('./routes/clientRequests');
const approvalRequestsRoutes = require('./routes/approvalRequests');
const adminRoutes = require('./routes/admin');
const reportsRoutes = require('./routes/reports');
const { analyticsRouter, aiRouter } = require('./routes/analytics');
const notificationsRoutes = require('./routes/notifications');
const miscRoutes = require('./routes/misc');

// Already-modularized routers from _fb.js files
const expenses = require('../../backend/firebase/expenses_fb');
const gatepasses = require('../../backend/firebase/gatepasses_fb');
const dispatchDocuments = require('../../backend/firebase/dispatch_documents_fb');
const transportDocuments = require('../../backend/firebase/transport_documents_fb');
const offerPrice = require('../../backend/firebase/offer_price_fb');

// Scheduled job dependencies
const approvalRequests = require('../../backend/firebase/approval_requests_fb');
const stockCalc = require('../../backend/firebase/stock_fb');
const { getDb } = require('./database/sqliteClient');

export default Server(() => {
    const app = express();
    // Disable trust proxy — ICP has no real sockets, so req.ip/proxyaddr crashes
    app.set('trust proxy', false);

    // ---------------------------------------------------------------------------
    // Middleware Stack (same order as original server.js)
    // ---------------------------------------------------------------------------

    // ICP WASM compat: patch req so Express doesn't crash accessing missing socket
    app.use((req: any, _res: any, next: any) => {
        if (!req.connection) req.connection = {};
        if (!req.connection.remoteAddress) req.connection.remoteAddress = '127.0.0.1';
        if (!req.socket) req.socket = req.connection;
        next();
    });

    // Security headers
    app.use(helmet({
        contentSecurityPolicy: false,
        crossOriginEmbedderPolicy: false,
    }));

    // CORS
    app.use(cors());

    // Body parsing
    app.use(express.json({ limit: '10mb' }));
    app.use(express.urlencoded({ limit: '10mb', extended: true }));

    // Compression
    app.use(compression());

    // Response size guardrail
    app.use(responseGuardrail);

    // Cache invalidation on writes
    app.use(cacheInvalidationMiddleware(syncFb));

    // Rate limiting
    const apiLimiter = rateLimit({
        windowMs: 15 * 60 * 1000,
        max: 500,
        standardHeaders: true,
        legacyHeaders: false,
        message: { success: false, error: 'Too many requests, please try again later.' }
    });
    app.use('/api/', apiLimiter);

    const loginLimiter = rateLimit({
        windowMs: 15 * 60 * 1000,
        max: 5,
        standardHeaders: true,
        legacyHeaders: false,
        message: { success: false, error: 'Too many login attempts, please try again later.' }
    });
    app.use('/api/auth/login', loginLimiter);

    // ---------------------------------------------------------------------------
    // Initialize SQLite database (async — sql.js needs WASM init)
    // ---------------------------------------------------------------------------
    let dbReady = false;
    let dbInitError: string | null = null;
    let dbInitPromise = initializeDatabase().then(() => {
        dbReady = true;
        console.log('[Cardamom] Database initialized successfully');
    }).catch((err: any) => {
        dbInitError = err?.message || String(err);
        console.error('[Cardamom] Database init failed:', dbInitError);
    });

    // Middleware: wait for DB to be ready before processing API requests
    app.use('/api', (req: any, res: any, next: any) => {
        if (dbReady) return next();
        dbInitPromise.then(() => next()).catch(() =>
            res.status(503).json({ success: false, error: 'Database initializing, please retry' })
        );
    });

    // ---------------------------------------------------------------------------
    // Health Check (no auth)
    // ---------------------------------------------------------------------------
    app.get('/health', (_req, res) => {
        const db = getDatabase();
        const resp: any = {
            status: 'ok',
            platform: 'icp',
            database: db ? 'connected' : 'disconnected',
            timestamp: new Date().toISOString(),
        };
        if (dbInitError) resp.dbInitError = dbInitError;
        res.json(resp);
    });

    app.get('/api/health', (_req, res) => {
        res.json({
            status: 'ok',
            timestamp: new Date().toISOString(),
        });
    });

    app.get('/api/info', (_req, res) => {
        res.json({
            name: 'Cardamom ICP Backend',
            version: '1.0.0',
            platform: 'Internet Computer Protocol',
            database: 'SQLite (sql.js)',
            framework: 'Azle + Express',
        });
    });

    // ---------------------------------------------------------------------------
    // JWT Authentication — protect all /api/* except public routes
    // ---------------------------------------------------------------------------
    const publicRoutes = [
        '/api/auth/login',
        '/api/auth/face-login',
        '/api/health',
        '/api/info',
        '/api/orders/dropdowns',
        '/api/users/face-data/all',
    ];

    app.use((req: any, res: any, next: any) => {
        if (publicRoutes.includes(req.path)) return next();
        if (req.path.startsWith('/api/')) return authenticateToken(req, res, next);
        next();
    });

    // ---------------------------------------------------------------------------
    // Public routes (no auth applied — handled by exemption above)
    // ---------------------------------------------------------------------------
    app.use('/api/auth', authRoutes);

    // ---------------------------------------------------------------------------
    // Authenticated routes
    // ---------------------------------------------------------------------------

    // Core business
    app.use('/api/orders', ordersRoutes);
    app.use('/api/stock', stockRoutes);
    app.use('/api/users', usersRoutes);
    app.use('/api/clients', clientsRoutes);

    // Workers & attendance
    app.use('/api/workers', workersRoutes);
    app.use('/api/attendance', attendanceRoutes);

    // Requests & approvals
    app.use('/api/client-requests', clientRequestsRoutes);
    app.use('/api/approval-requests', approvalRequestsRoutes);

    // Admin
    app.use('/api/admin', adminRoutes);

    // Tasks & dropdowns
    app.use('/api/tasks', tasksRoutes);
    app.use('/api/dropdowns', dropdownsRoutes);

    // Reports & analytics
    app.use('/api/reports', reportsRoutes);
    app.use('/api/analytics', analyticsRouter);
    app.use('/api/ai', aiRouter);

    // Notifications (polling replaces Socket.IO)
    app.use('/api/notifications', notificationsRoutes);

    // Already-modularized routers from _fb.js files
    app.use('/api/expenses', expenses.router);
    app.use('/api/gate-passes', gatepasses.router);
    app.use('/api/dispatch-documents', dispatchDocuments.router);
    app.use('/api/transport-documents', transportDocuments.router);
    app.use('/api/offers', requireAdmin, offerPrice.router);

    // Misc routes (whatsapp, outstanding, packed-boxes, logs, debug, access-log)
    // These are mounted at /api since misc.js uses full sub-paths like /whatsapp/verify/:phone
    app.use('/api', miscRoutes);

    // Dashboard and sync — legacy top-level paths the Flutter app expects
    // Proxy to admin router handlers directly
    const dashboardFb = require('../../backend/firebase/dashboard_fb');
    app.get('/api/dashboard', async (req: any, res: any) => {
        try {
            const { getCachedResponse: getC, setCachedResponse: setC } = require('./middleware/apiCache');
            const cached = getC('/api/dashboard');
            if (cached) return res.json(cached);
            const data = await dashboardFb.getDashboardPayload();
            setC('/api/dashboard', data);
            res.json(data);
        } catch (err: any) { res.status(500).json({ success: false, error: err.message }); }
    });
    app.get('/api/sync', async (req: any, res: any) => {
        try {
            const { getCachedResponse: getC, setCachedResponse: setC } = require('./middleware/apiCache');
            const since = req.query.since || null;
            const sections = req.query.sections ? String(req.query.sections).split(',') : null;
            const cacheKey = `/api/sync?since=${since || 'null'}&sections=${sections ? sections.join(',') : 'all'}`;
            const cached = getC(cacheKey);
            if (cached) return res.json(cached);
            const data = await syncFb.getSyncData(since, sections);
            setC(cacheKey, data, 30000);
            res.json(data);
        } catch (err: any) { res.status(500).json({ success: false, error: err.message }); }
    });

    // ---------------------------------------------------------------------------
    // 404 handler
    // ---------------------------------------------------------------------------
    app.use((req: any, res: any) => {
        if (req.path.startsWith('/api/')) {
            return res.status(404).json({ success: false, error: 'API endpoint not found' });
        }
        res.status(404).json({ error: 'Not found' });
    });

    // ---------------------------------------------------------------------------
    // Scheduled Jobs (replaces server.js cron jobs)
    // ---------------------------------------------------------------------------
    const ESCALATION_INTERVAL = 60 * 60 * 1000; // 1 hour
    const STOCK_RECONCILE_INTERVAL = 6 * 60 * 60 * 1000; // 6 hours

    async function escalatePendingApprovals() {
        try {
            const db = getDb();
            const pending = await approvalRequests.getPendingRequests();
            const now = Date.now();
            const TWENTY_FOUR_HOURS = 24 * 60 * 60 * 1000;
            let escalated = 0;

            for (const req of pending) {
                const createdAt = new Date(req.createdAt).getTime();
                if (now - createdAt > TWENTY_FOUR_HOURS && !req.escalated) {
                    await db.collection('approval_requests').doc(req.id).update({
                        escalated: true,
                        escalatedAt: new Date().toISOString(),
                    });
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
                    escalated++;
                }
            }
            if (escalated > 0) {
                console.log(`[Escalation] Escalated ${escalated} pending approval(s) older than 24 hours`);
            }
        } catch (err: any) {
            console.error('[Escalation] Error:', err.message);
        }
    }

    async function autoReconcileStockDrift() {
        try {
            console.log('[Stock Reconcile] Running 6-hour auto-reconciliation...');
            await stockCalc.updateAllStocks();
            const negatives = await stockCalc.detectNegativeStock();
            if (negatives.length > 0) {
                const db = getDb();
                const notifDoc = db.collection('notifications').doc();
                await notifDoc.set({
                    id: notifDoc.id,
                    userId: 'all_admins',
                    title: 'Stock Drift Detected',
                    body: `Auto-reconciliation found ${negatives.length} negative stock entries: ${negatives.slice(0, 3).map((n: any) => `${n.grade} (${n.type}): ${n.value}kg`).join(', ')}${negatives.length > 3 ? '...' : ''}`,
                    type: 'stock_drift',
                    metadata: { negatives },
                    read: false,
                    createdAt: new Date().toISOString(),
                });
                console.log(`[Stock Reconcile] Found ${negatives.length} negative stock entries`);
            } else {
                console.log('[Stock Reconcile] No drift detected');
            }
        } catch (err: any) {
            console.error('[Stock Reconcile] Error:', err.message);
        }
    }

    // Start scheduled jobs 60s after server startup
    setTimeout(() => {
        setInterval(escalatePendingApprovals, ESCALATION_INTERVAL);
        setInterval(autoReconcileStockDrift, STOCK_RECONCILE_INTERVAL);
        escalatePendingApprovals();
        console.log('Scheduled: Approval escalation (1h), Stock reconciliation (6h)');
    }, 60000);

    // ---------------------------------------------------------------------------
    // Data initialization (one-time migrations)
    // ---------------------------------------------------------------------------
    const users = require('../../backend/firebase/users_fb');
    const taskManager = require('../../backend/firebase/taskManager_fb');
    if (users.initializeFromJson) {
        users.initializeFromJson().catch((err: any) => console.error('[Init] User migration error:', err.message));
    }
    if (taskManager.initializeFromJson) {
        taskManager.initializeFromJson().catch((err: any) => console.error('[Init] Task migration error:', err.message));
    }

    console.log('Cardamom ICP Backend started — SQLite + Azle');

    return app.listen();
}, {
    // Persist database to stable memory before canister upgrades
    preUpgrade: preUpgrade(() => {
        console.log('[PreUpgrade] Persisting database to stable memory...');
        persistNow(exportDatabase);
    }),
});
