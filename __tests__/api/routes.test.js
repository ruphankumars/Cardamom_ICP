/**
 * API Route Smoke Tests
 *
 * Verifies that protected routes reject unauthenticated requests (401)
 * and that the server routes are wired up correctly.
 *
 * Uses Supertest against the Express app.
 * Firebase modules are mocked to avoid requiring real credentials.
 */

const jwt = require('jsonwebtoken');

// Mock Firebase Admin before any module that imports it
jest.mock('firebase-admin', () => {
    const firestoreMock = {
        collection: jest.fn(() => firestoreMock),
        doc: jest.fn(() => firestoreMock),
        get: jest.fn(() => Promise.resolve({ exists: false, data: () => ({}), docs: [], empty: true, size: 0 })),
        set: jest.fn(() => Promise.resolve()),
        update: jest.fn(() => Promise.resolve()),
        delete: jest.fn(() => Promise.resolve()),
        add: jest.fn(() => Promise.resolve({ id: 'mock-id' })),
        where: jest.fn(() => firestoreMock),
        orderBy: jest.fn(() => firestoreMock),
        limit: jest.fn(() => firestoreMock),
        batch: jest.fn(() => ({
            set: jest.fn(),
            update: jest.fn(),
            delete: jest.fn(),
            commit: jest.fn(() => Promise.resolve()),
        })),
        runTransaction: jest.fn((fn) => fn({
            get: jest.fn(() => Promise.resolve({ exists: false, data: () => ({}), docs: [] })),
            set: jest.fn(),
            update: jest.fn(),
        })),
    };

    return {
        initializeApp: jest.fn(),
        credential: {
            cert: jest.fn(() => ({})),
        },
        firestore: Object.assign(jest.fn(() => firestoreMock), {
            FieldValue: {
                serverTimestamp: jest.fn(() => new Date().toISOString()),
                increment: jest.fn((n) => n),
                arrayUnion: jest.fn((...args) => args),
                arrayRemove: jest.fn((...args) => args),
                delete: jest.fn(),
            },
        }),
        auth: jest.fn(() => ({
            verifyIdToken: jest.fn(),
        })),
    };
});

const request = require('supertest');
const app = require('../../server');

const JWT_SECRET = process.env.JWT_SECRET;

function makeToken(role = 'admin') {
    return jwt.sign(
        { id: '1', username: 'testuser', role },
        JWT_SECRET,
        { expiresIn: '24h' }
    );
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
