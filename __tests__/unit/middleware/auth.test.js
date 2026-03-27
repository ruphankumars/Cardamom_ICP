/**
 * Authentication Middleware Unit Tests
 *
 * Tests for backend/middleware/auth.js covering:
 * - generateToken(): JWT structure, payload, expiry
 * - authenticateToken(): token validation middleware
 * - requireAdmin(): admin/ops role check
 * - requireClient(): client role check
 * - requireAuth(): alias for authenticateToken
 */

const jwt = require('jsonwebtoken');
const { mockRequest, mockResponse, mockNext, JWT_SECRET } = require('../../helpers');
const { testUsers } = require('../../fixtures/testData');

// Import the auth module (setup.js already sets JWT_SECRET env var)
const {
    generateToken,
    authenticateToken,
    requireAdmin,
    requireClient,
    requireAuth,
    JWT_EXPIRY,
} = require('../../../backend/middleware/auth');

// ============================================================================
// generateToken()
// ============================================================================

describe('generateToken()', () => {
    test('returns a valid JWT string', () => {
        const token = generateToken(testUsers.admin);
        expect(typeof token).toBe('string');
        expect(token.split('.')).toHaveLength(3); // JWT has 3 parts
    });

    test('token payload contains id, username, and role', () => {
        const token = generateToken(testUsers.admin);
        const decoded = jwt.verify(token, JWT_SECRET);
        expect(decoded.id).toBe(testUsers.admin.id);
        expect(decoded.username).toBe(testUsers.admin.username);
        expect(decoded.role).toBe(testUsers.admin.role);
    });

    test('token has exp field (expiration)', () => {
        const token = generateToken(testUsers.admin);
        const decoded = jwt.verify(token, JWT_SECRET);
        expect(decoded.exp).toBeDefined();
        expect(typeof decoded.exp).toBe('number');
    });

    test('token expires in approximately 7 days', () => {
        const token = generateToken(testUsers.admin);
        const decoded = jwt.verify(token, JWT_SECRET);
        const now = Math.floor(Date.now() / 1000);
        const sevenDays = 7 * 24 * 60 * 60;
        // Allow 10 second tolerance
        expect(decoded.exp - now).toBeGreaterThan(sevenDays - 10);
        expect(decoded.exp - now).toBeLessThanOrEqual(sevenDays + 10);
    });

    test('token has iat field (issued at)', () => {
        const token = generateToken(testUsers.admin);
        const decoded = jwt.verify(token, JWT_SECRET);
        expect(decoded.iat).toBeDefined();
    });

    test('generates different tokens for different users', () => {
        const token1 = generateToken(testUsers.admin);
        const token2 = generateToken(testUsers.client);
        expect(token1).not.toBe(token2);
    });

    test('JWT_EXPIRY constant is 7d', () => {
        expect(JWT_EXPIRY).toBe('7d');
    });

    test('works with minimal user object (id, username, role)', () => {
        const token = generateToken({ id: '99', username: 'min', role: 'admin' });
        const decoded = jwt.verify(token, JWT_SECRET);
        expect(decoded.id).toBe('99');
        expect(decoded.username).toBe('min');
        expect(decoded.role).toBe('admin');
    });
});

// ============================================================================
// authenticateToken()
// ============================================================================

describe('authenticateToken()', () => {
    test('passes with valid Bearer token and attaches user to req', () => {
        const token = generateToken(testUsers.admin);
        const req = mockRequest({
            headers: { authorization: `Bearer ${token}` },
        });
        const res = mockResponse();
        const next = mockNext();

        authenticateToken(req, res, next);

        expect(next).toHaveBeenCalled();
        expect(req.user).toBeDefined();
        expect(req.user.id).toBe(testUsers.admin.id);
        expect(req.user.username).toBe(testUsers.admin.username);
        expect(req.user.role).toBe(testUsers.admin.role);
    });

    test('returns 401 when no Authorization header is present', () => {
        const req = mockRequest({ headers: {} });
        const res = mockResponse();
        const next = mockNext();

        authenticateToken(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(res.json).toHaveBeenCalledWith(
            expect.objectContaining({ success: false })
        );
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 401 when Authorization header has no Bearer token', () => {
        const req = mockRequest({
            headers: { authorization: 'Bearer' },
        });
        const res = mockResponse();
        const next = mockNext();

        authenticateToken(req, res, next);

        // "Bearer".split(' ')[1] is undefined
        expect(res.status).toHaveBeenCalledWith(401);
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 401 for malformed token', () => {
        const req = mockRequest({
            headers: { authorization: 'Bearer invalid.token.here' },
        });
        const res = mockResponse();
        const next = mockNext();

        authenticateToken(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(res.json).toHaveBeenCalledWith(
            expect.objectContaining({ success: false })
        );
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 401 for expired token', (done) => {
        // Create a token that expires immediately
        const token = jwt.sign(
            { id: '1', username: 'test', role: 'admin' },
            JWT_SECRET,
            { expiresIn: '0s' }
        );

        // Small delay to ensure expiration
        setTimeout(() => {
            const req = mockRequest({
                headers: { authorization: `Bearer ${token}` },
            });
            const res = mockResponse();
            const next = mockNext();

            authenticateToken(req, res, next);

            expect(res.status).toHaveBeenCalledWith(401);
            expect(next).not.toHaveBeenCalled();
            done();
        }, 50);
    });

    test('returns 401 for token signed with wrong secret', () => {
        const token = jwt.sign(
            { id: '1', username: 'test', role: 'admin' },
            'wrong-secret-key-that-is-totally-different'
        );
        const req = mockRequest({
            headers: { authorization: `Bearer ${token}` },
        });
        const res = mockResponse();
        const next = mockNext();

        authenticateToken(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 401 for empty Authorization header', () => {
        const req = mockRequest({
            headers: { authorization: '' },
        });
        const res = mockResponse();
        const next = mockNext();

        authenticateToken(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(next).not.toHaveBeenCalled();
    });
});

// ============================================================================
// requireAdmin()
// ============================================================================

describe('requireAdmin()', () => {
    test('passes for admin role', () => {
        const req = mockRequest({ user: { role: 'admin' } });
        const res = mockResponse();
        const next = mockNext();

        requireAdmin(req, res, next);

        expect(next).toHaveBeenCalled();
    });

    test('passes for ops role', () => {
        const req = mockRequest({ user: { role: 'ops' } });
        const res = mockResponse();
        const next = mockNext();

        requireAdmin(req, res, next);

        expect(next).toHaveBeenCalled();
    });

    test('passes for Admin role (case-insensitive)', () => {
        const req = mockRequest({ user: { role: 'Admin' } });
        const res = mockResponse();
        const next = mockNext();

        requireAdmin(req, res, next);

        expect(next).toHaveBeenCalled();
    });

    test('passes for OPS role (case-insensitive)', () => {
        const req = mockRequest({ user: { role: 'OPS' } });
        const res = mockResponse();
        const next = mockNext();

        requireAdmin(req, res, next);

        expect(next).toHaveBeenCalled();
    });

    test('returns 403 for client role', () => {
        const req = mockRequest({ user: { role: 'client' } });
        const res = mockResponse();
        const next = mockNext();

        requireAdmin(req, res, next);

        expect(res.status).toHaveBeenCalledWith(403);
        expect(res.json).toHaveBeenCalledWith(
            expect.objectContaining({ success: false, error: 'Admin access required' })
        );
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 403 for employee role', () => {
        const req = mockRequest({ user: { role: 'employee' } });
        const res = mockResponse();
        const next = mockNext();

        requireAdmin(req, res, next);

        expect(res.status).toHaveBeenCalledWith(403);
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 401 when req.user is null', () => {
        const req = mockRequest({ user: null });
        const res = mockResponse();
        const next = mockNext();

        requireAdmin(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 401 when req.user is undefined', () => {
        const req = mockRequest();
        const res = mockResponse();
        const next = mockNext();

        requireAdmin(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(next).not.toHaveBeenCalled();
    });
});

// ============================================================================
// requireClient()
// ============================================================================

describe('requireClient()', () => {
    test('passes for client role', () => {
        const req = mockRequest({ user: { role: 'client' } });
        const res = mockResponse();
        const next = mockNext();

        requireClient(req, res, next);

        expect(next).toHaveBeenCalled();
    });

    test('passes for Client role (case-insensitive)', () => {
        const req = mockRequest({ user: { role: 'Client' } });
        const res = mockResponse();
        const next = mockNext();

        requireClient(req, res, next);

        expect(next).toHaveBeenCalled();
    });

    test('returns 403 for admin role', () => {
        const req = mockRequest({ user: { role: 'admin' } });
        const res = mockResponse();
        const next = mockNext();

        requireClient(req, res, next);

        expect(res.status).toHaveBeenCalledWith(403);
        expect(res.json).toHaveBeenCalledWith(
            expect.objectContaining({ success: false, error: 'Client access required' })
        );
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 403 for ops role', () => {
        const req = mockRequest({ user: { role: 'ops' } });
        const res = mockResponse();
        const next = mockNext();

        requireClient(req, res, next);

        expect(res.status).toHaveBeenCalledWith(403);
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 401 when req.user is null', () => {
        const req = mockRequest({ user: null });
        const res = mockResponse();
        const next = mockNext();

        requireClient(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(next).not.toHaveBeenCalled();
    });

    test('returns 401 when req.user is undefined', () => {
        const req = mockRequest();
        const res = mockResponse();
        const next = mockNext();

        requireClient(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(next).not.toHaveBeenCalled();
    });
});

// ============================================================================
// requireAuth()
// ============================================================================

describe('requireAuth()', () => {
    test('is a function', () => {
        expect(typeof requireAuth).toBe('function');
    });

    test('passes with valid token (same behavior as authenticateToken)', () => {
        const token = generateToken(testUsers.admin);
        const req = mockRequest({
            headers: { authorization: `Bearer ${token}` },
        });
        const res = mockResponse();
        const next = mockNext();

        requireAuth(req, res, next);

        expect(next).toHaveBeenCalled();
        expect(req.user).toBeDefined();
    });

    test('returns 401 without token (same behavior as authenticateToken)', () => {
        const req = mockRequest({ headers: {} });
        const res = mockResponse();
        const next = mockNext();

        requireAuth(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(next).not.toHaveBeenCalled();
    });
});
