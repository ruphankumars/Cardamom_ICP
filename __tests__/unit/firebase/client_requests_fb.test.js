/**
 * Client Request State Machine and ID Generation Tests
 *
 * Tests for backend/firebase/client_requests_fb.js:
 * - REQUEST_STATUSES: All 8 states present
 * - SUBORDER_STATUSES: All 6 states present
 * - MESSAGE_KINDS: All 3 kinds present
 * - generateRequestId(): format and uniqueness
 * - generateMessageId(): format and uniqueness
 * - getCurrentTimestamp(): valid ISO timestamp
 * - validatePanelSnapshot(): valid/invalid panel validation
 */

const clientRequests = require('../../../backend/firebase/client_requests_fb');
const {
    REQUEST_STATUSES,
    SUBORDER_STATUSES,
    MESSAGE_KINDS,
} = clientRequests;

const {
    generateRequestId,
    generateMessageId,
    getCurrentTimestamp,
    validatePanelSnapshot,
} = clientRequests._test;

// ============================================================================
// REQUEST_STATUSES
// ============================================================================

describe('REQUEST_STATUSES', () => {
    test('has exactly 8 status values', () => {
        expect(Object.keys(REQUEST_STATUSES)).toHaveLength(8);
    });

    test('contains OPEN', () => {
        expect(REQUEST_STATUSES.OPEN).toBe('OPEN');
    });

    test('contains ADMIN_DRAFT', () => {
        expect(REQUEST_STATUSES.ADMIN_DRAFT).toBe('ADMIN_DRAFT');
    });

    test('contains ADMIN_SENT', () => {
        expect(REQUEST_STATUSES.ADMIN_SENT).toBe('ADMIN_SENT');
    });

    test('contains CLIENT_DRAFT', () => {
        expect(REQUEST_STATUSES.CLIENT_DRAFT).toBe('CLIENT_DRAFT');
    });

    test('contains CLIENT_SENT', () => {
        expect(REQUEST_STATUSES.CLIENT_SENT).toBe('CLIENT_SENT');
    });

    test('contains CONFIRMED', () => {
        expect(REQUEST_STATUSES.CONFIRMED).toBe('CONFIRMED');
    });

    test('contains CANCELLED', () => {
        expect(REQUEST_STATUSES.CANCELLED).toBe('CANCELLED');
    });

    test('contains CONVERTED_TO_ORDER', () => {
        expect(REQUEST_STATUSES.CONVERTED_TO_ORDER).toBe('CONVERTED_TO_ORDER');
    });

    test('all values are strings', () => {
        Object.values(REQUEST_STATUSES).forEach(status => {
            expect(typeof status).toBe('string');
        });
    });
});

// ============================================================================
// SUBORDER_STATUSES
// ============================================================================

describe('SUBORDER_STATUSES', () => {
    test('has exactly 6 status values', () => {
        expect(Object.keys(SUBORDER_STATUSES)).toHaveLength(6);
    });

    test('contains REQUESTED', () => {
        expect(SUBORDER_STATUSES.REQUESTED).toBe('REQUESTED');
    });

    test('contains OFFERED', () => {
        expect(SUBORDER_STATUSES.OFFERED).toBe('OFFERED');
    });

    test('contains DECLINED', () => {
        expect(SUBORDER_STATUSES.DECLINED).toBe('DECLINED');
    });

    test('contains COUNTERED', () => {
        expect(SUBORDER_STATUSES.COUNTERED).toBe('COUNTERED');
    });

    test('contains ACCEPTED', () => {
        expect(SUBORDER_STATUSES.ACCEPTED).toBe('ACCEPTED');
    });

    test('contains FINALIZED', () => {
        expect(SUBORDER_STATUSES.FINALIZED).toBe('FINALIZED');
    });
});

// ============================================================================
// MESSAGE_KINDS
// ============================================================================

describe('MESSAGE_KINDS', () => {
    test('has exactly 3 message kinds', () => {
        expect(Object.keys(MESSAGE_KINDS)).toHaveLength(3);
    });

    test('contains PANEL', () => {
        expect(MESSAGE_KINDS.PANEL).toBe('PANEL');
    });

    test('contains TEXT', () => {
        expect(MESSAGE_KINDS.TEXT).toBe('TEXT');
    });

    test('contains SYSTEM', () => {
        expect(MESSAGE_KINDS.SYSTEM).toBe('SYSTEM');
    });
});

// ============================================================================
// generateRequestId()
// ============================================================================

describe('generateRequestId()', () => {
    test('returns string starting with REQ-', () => {
        const id = generateRequestId();
        expect(typeof id).toBe('string');
        expect(id.startsWith('REQ-')).toBe(true);
    });

    test('format is REQ-{timestamp}-{random}', () => {
        const id = generateRequestId();
        const parts = id.split('-');
        expect(parts[0]).toBe('REQ');
        expect(parts.length).toBe(3);
        expect(Number(parts[1])).toBeGreaterThan(0);
        expect(Number(parts[2])).toBeDefined();
    });

    test('generates unique IDs across calls', () => {
        const ids = new Set();
        for (let i = 0; i < 100; i++) {
            ids.add(generateRequestId());
        }
        // With timestamp + random, most should be unique
        expect(ids.size).toBeGreaterThan(90);
    });

    test('timestamp part is a valid number', () => {
        const id = generateRequestId();
        const timestamp = parseInt(id.split('-')[1]);
        expect(timestamp).toBeGreaterThan(Date.now() - 10000);
        expect(timestamp).toBeLessThanOrEqual(Date.now() + 1000);
    });
});

// ============================================================================
// generateMessageId()
// ============================================================================

describe('generateMessageId()', () => {
    test('returns string starting with MSG-', () => {
        const id = generateMessageId();
        expect(typeof id).toBe('string');
        expect(id.startsWith('MSG-')).toBe(true);
    });

    test('format is MSG-{timestamp}-{random}', () => {
        const id = generateMessageId();
        const parts = id.split('-');
        expect(parts[0]).toBe('MSG');
        expect(parts.length).toBe(3);
    });

    test('generates unique IDs across calls', () => {
        const ids = new Set();
        for (let i = 0; i < 100; i++) {
            ids.add(generateMessageId());
        }
        expect(ids.size).toBeGreaterThan(90);
    });
});

// ============================================================================
// getCurrentTimestamp()
// ============================================================================

describe('getCurrentTimestamp()', () => {
    test('returns a valid ISO 8601 string', () => {
        const ts = getCurrentTimestamp();
        expect(typeof ts).toBe('string');
        const parsed = new Date(ts);
        expect(parsed.toISOString()).toBe(ts);
    });

    test('returns current time (within 2 seconds)', () => {
        const ts = getCurrentTimestamp();
        const now = Date.now();
        const parsed = new Date(ts).getTime();
        expect(Math.abs(now - parsed)).toBeLessThan(2000);
    });
});

// ============================================================================
// validatePanelSnapshot()
// ============================================================================

describe('validatePanelSnapshot()', () => {
    const validPanel = {
        panelVersion: 1,
        stage: 'OPEN',
        items: [
            {
                itemId: 'I-001',
                requestedNo: 10,
                requestedKgs: 500,
                offeredNo: 0,
                offeredKgs: 0,
                unitPrice: 0,
                status: 'REQUESTED',
            },
        ],
    };

    test('accepts valid panel snapshot', () => {
        expect(validatePanelSnapshot(validPanel)).toBe(true);
    });

    test('throws for null input', () => {
        expect(() => validatePanelSnapshot(null)).toThrow('Panel snapshot must be an object');
    });

    test('throws for non-object input', () => {
        expect(() => validatePanelSnapshot('string')).toThrow('Panel snapshot must be an object');
    });

    test('throws for missing panelVersion', () => {
        expect(() => validatePanelSnapshot({ items: [], stage: 'OPEN' })).toThrow('panelVersion');
    });

    test('throws for panelVersion < 1', () => {
        expect(() => validatePanelSnapshot({ panelVersion: 0, items: [], stage: 'OPEN' })).toThrow('panelVersion');
    });

    test('throws for missing items array', () => {
        expect(() => validatePanelSnapshot({ panelVersion: 1, stage: 'OPEN' })).toThrow('items array');
    });

    test('throws for invalid stage', () => {
        expect(() => validatePanelSnapshot({ panelVersion: 1, items: [], stage: 'INVALID' })).toThrow('valid stage');
    });

    test('throws for item without itemId', () => {
        const panel = {
            panelVersion: 1,
            stage: 'OPEN',
            items: [{ requestedNo: 10, requestedKgs: 500, offeredNo: 0, offeredKgs: 0, unitPrice: 0, status: 'REQUESTED' }],
        };
        expect(() => validatePanelSnapshot(panel)).toThrow('itemId');
    });

    test('throws for negative requestedNo', () => {
        const panel = {
            panelVersion: 1,
            stage: 'OPEN',
            items: [{ itemId: 'I-001', requestedNo: -1, requestedKgs: 500, offeredNo: 0, offeredKgs: 0, unitPrice: 0, status: 'REQUESTED' }],
        };
        expect(() => validatePanelSnapshot(panel)).toThrow('requestedNo');
    });

    test('throws for invalid item status', () => {
        const panel = {
            panelVersion: 1,
            stage: 'OPEN',
            items: [{ itemId: 'I-001', requestedNo: 10, requestedKgs: 500, offeredNo: 0, offeredKgs: 0, unitPrice: 0, status: 'INVALID' }],
        };
        expect(() => validatePanelSnapshot(panel)).toThrow('Invalid status');
    });

    test('throws for DECLINED item with offeredNo > 0', () => {
        const panel = {
            panelVersion: 1,
            stage: 'OPEN',
            items: [{ itemId: 'I-001', requestedNo: 10, requestedKgs: 500, offeredNo: 5, offeredKgs: 0, unitPrice: 0, status: 'DECLINED' }],
        };
        expect(() => validatePanelSnapshot(panel)).toThrow('Declined items');
    });

    test('accepts DECLINED item with zero offeredNo and offeredKgs', () => {
        const panel = {
            panelVersion: 1,
            stage: 'OPEN',
            items: [{ itemId: 'I-001', requestedNo: 10, requestedKgs: 500, offeredNo: 0, offeredKgs: 0, unitPrice: 0, status: 'DECLINED' }],
        };
        expect(validatePanelSnapshot(panel)).toBe(true);
    });

    test('accepts all valid REQUEST_STATUSES as stage', () => {
        Object.values(REQUEST_STATUSES).forEach(status => {
            const panel = {
                panelVersion: 1,
                stage: status,
                items: [],
            };
            expect(validatePanelSnapshot(panel)).toBe(true);
        });
    });
});
