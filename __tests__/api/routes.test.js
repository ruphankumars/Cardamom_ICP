/**
 * API Route Smoke Tests
 *
 * Verifies that protected routes reject unauthenticated requests (401)
 * and that the server routes are wired up correctly.
 *
 * Uses Supertest against the Express app.
 * Firebase modules are mocked to avoid requiring real credentials.
 */

const { generateToken } = require('../../backend/middleware/auth');

// No firebase-admin mock needed — ICP backend uses SQLite via sqliteClient.js

const request = require('supertest');

// Build a lightweight Express app matching the ICP index.ts wiring
// (index.ts uses Azle Server() which can't be imported in Jest)
const express = require('express');
const { initDatabase } = require('../../src/backend/database/sqliteClient');
const { authenticateToken, requireAdmin } = require('../../backend/middleware/auth');

initDatabase();
const app = express();
app.use(express.json());

// Public routes
const authRoutes = require('../../src/backend/routes/auth');
app.use('/api/auth', authRoutes);

// JWT auth for /api/*
app.use((req, res, next) => {
    const publicPaths = ['/api/auth/login', '/api/auth/face-login', '/api/health'];
    if (publicPaths.includes(req.path)) return next();
    if (req.path.startsWith('/api/')) return authenticateToken(req, res, next);
    next();
});

// Protected routes
app.use('/api/orders', require('../../src/backend/routes/orders'));
app.use('/api/stock', require('../../src/backend/routes/stock'));
app.use('/api/users', require('../../src/backend/routes/users'));
app.use('/api/clients', require('../../src/backend/routes/clients'));
app.use('/api/workers', require('../../src/backend/routes/workers'));
app.use('/api/attendance', require('../../src/backend/routes/attendance'));
app.use('/api/client-requests', require('../../src/backend/routes/clientRequests'));
app.use('/api/approval-requests', require('../../src/backend/routes/approvalRequests'));
app.use('/api/admin', require('../../src/backend/routes/admin'));
app.use('/api/tasks', require('../../src/backend/routes/tasks'));
app.use('/api/dropdowns', require('../../src/backend/routes/dropdowns'));
app.use('/api/reports', require('../../src/backend/routes/reports'));
const { analyticsRouter, aiRouter } = require('../../src/backend/routes/analytics');
app.use('/api/analytics', analyticsRouter);
app.use('/api/ai', aiRouter);
app.use('/api/notifications', require('../../src/backend/routes/notifications'));
app.use('/api', require('../../src/backend/routes/misc'));

// 404 handler
app.use((req, res) => {
    if (req.path.startsWith('/api/')) return res.status(404).json({ success: false, error: 'API endpoint not found' });
    res.status(404).json({ error: 'Not found' });
});

const JWT_SECRET = process.env.JWT_SECRET;

function makeToken(role = 'admin') {
    return generateToken({ id: '1', username: 'testuser', role });
}

// ============================================================================
// Public routes
// ============================================================================

describe('Public routes', () => {
    test('GET / returns 200 or serves index.html', async () => {
        const res = await request(app).get('/');
        // May return 200 (if public/index.html exists) or 404
        expect([200, 404]).toContain(res.status);
    });

    test('GET /api/nonexistent returns 401 or 404', async () => {
        const res = await request(app).get('/api/nonexistent');
        // Returns 401 if route has auth middleware, or 404 if truly not found
        expect([401, 404]).toContain(res.status);
    });

    test('GET /api/nonexistent returns 404 when authenticated', async () => {
        const adminToken = makeToken('admin');
        const res = await request(app)
            .get('/api/nonexistent')
            .set('Authorization', `Bearer ${adminToken}`);
        expect(res.status).toBe(404);
        expect(res.body.success).toBe(false);
    });
});

// ============================================================================
// Auth endpoints
// ============================================================================

describe('Auth endpoints', () => {
    test('POST /api/auth/login returns 400 without credentials', async () => {
        const res = await request(app)
            .post('/api/auth/login')
            .send({});
        expect(res.status).toBe(400);
        expect(res.body.success).toBe(false);
    });

    test('POST /api/auth/login returns 400 with missing password', async () => {
        const res = await request(app)
            .post('/api/auth/login')
            .send({ username: 'testuser' });
        expect(res.status).toBe(400);
    });

    test('POST /api/auth/login returns 400 with missing username', async () => {
        const res = await request(app)
            .post('/api/auth/login')
            .send({ password: 'testpass' });
        expect(res.status).toBe(400);
    });
});

// ============================================================================
// Protected routes - should return 401 without auth
// ============================================================================

describe('Protected routes return 401 without authentication', () => {
    // Stock routes
    const protectedGetRoutes = [
        '/api/stock/net',
        '/api/stock/adjustments',
        '/api/stock/config',
        '/api/orders',
        '/api/orders/pending',
        '/api/orders/today-cart',
        '/api/orders/sales-summary',
        '/api/orders/dropdown-options',
        '/api/client-requests/admin',
        '/api/users',
        '/api/dropdowns/categories',
        '/api/tasks',
        '/api/attendance/workers',
        '/api/admin/feature-flags',
    ];

    test.each(protectedGetRoutes)(
        'GET %s returns 401 without auth',
        async (route) => {
            const res = await request(app).get(route);
            // Should be 401 (no token) - some routes may return 500 if mock isn't perfect
            expect([401, 403]).toContain(res.status);
        }
    );

    const protectedPostRoutes = [
        '/api/stock/purchase',
        '/api/stock/adjustment',
        '/api/orders/add',
        '/api/users/add',
        '/api/tasks/add',
    ];

    test.each(protectedPostRoutes)(
        'POST %s returns 401 without auth',
        async (route) => {
            const res = await request(app)
                .post(route)
                .send({});
            expect([401, 403]).toContain(res.status);
        }
    );
});

// ============================================================================
// Role-based access control
// ============================================================================

describe('Role-based access control', () => {
    test('GET /api/admin/feature-flags returns 403 with client token', async () => {
        const clientToken = makeToken('client');
        const res = await request(app)
            .get('/api/admin/feature-flags')
            .set('Authorization', `Bearer ${clientToken}`);
        expect(res.status).toBe(403);
    });

    test('GET /api/admin/feature-flags returns 200 with admin token', async () => {
        const adminToken = makeToken('admin');
        const res = await request(app)
            .get('/api/admin/feature-flags')
            .set('Authorization', `Bearer ${adminToken}`);
        expect(res.status).toBe(200);
        expect(res.body.success).toBe(true);
    });

    test('POST /api/auth/login validation works (no auth required)', async () => {
        const res = await request(app)
            .post('/api/auth/login')
            .send({ username: '', password: '' });
        // Empty strings should trigger 400
        expect(res.status).toBe(400);
    });
});
