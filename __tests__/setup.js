/**
 * Jest Global Setup
 *
 * Sets environment variables required by the backend before any module loads.
 * This file runs before each test suite via Jest's setupFiles config.
 */

// Set test environment variables BEFORE any module imports
process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-jwt-secret-key-minimum-32-chars-long';
process.env.PORT = '0'; // Use random available port in tests

// Suppress console output during tests (comment out for debugging)
if (process.env.JEST_SILENT !== 'false') {
    const noop = () => {};
    global.originalConsole = {
        log: console.log,
        error: console.error,
        warn: console.warn,
    };
    console.log = noop;
    console.warn = noop;
    // Keep console.error for test debugging
}
