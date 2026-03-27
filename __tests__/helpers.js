/**
 * Test Helper Utilities
 *
 * Common helpers for creating mock objects, tokens, and test setup.
 */

const jwt = require('jsonwebtoken');

const JWT_SECRET = process.env.JWT_SECRET || 'test-jwt-secret-key-minimum-32-chars-long';

/**
 * Generate a valid JWT token for testing
 * @param {Object} user - User payload
 * @param {Object} options - JWT sign options (override expiresIn etc.)
 * @returns {string} JWT token
 */
function generateTestToken(user, options = {}) {
    const payload = {
        id: user.id || '1',
        username: user.username || 'testuser',
        role: user.role || 'admin',
    };
    return jwt.sign(payload, JWT_SECRET, { expiresIn: '24h', ...options });
}

/**
 * Generate an expired JWT token for testing
 * @param {Object} user - User payload
 * @returns {string} Expired JWT token
 */
function generateExpiredToken(user) {
    const payload = {
        id: user.id || '1',
        username: user.username || 'testuser',
        role: user.role || 'admin',
    };
    return jwt.sign(payload, JWT_SECRET, { expiresIn: '0s' });
}

/**
 * Create a mock Express request object
 * @param {Object} overrides - Properties to override
 * @returns {Object} Mock request
 */
function mockRequest(overrides = {}) {
    return {
        headers: {},
        body: {},
        params: {},
        query: {},
        user: null,
        ...overrides,
    };
}

/**
 * Create a mock Express response object with jest spy functions
 * @returns {Object} Mock response with status/json/send spies
 */
function mockResponse() {
    const res = {};
    res.status = jest.fn().mockReturnValue(res);
    res.json = jest.fn().mockReturnValue(res);
    res.send = jest.fn().mockReturnValue(res);
    res.sendFile = jest.fn().mockReturnValue(res);
    return res;
}

/**
 * Create a mock next function for middleware testing
 * @returns {jest.Mock}
 */
function mockNext() {
    return jest.fn();
}

module.exports = {
    generateTestToken,
    generateExpiredToken,
    mockRequest,
    mockResponse,
    mockNext,
    JWT_SECRET,
};
