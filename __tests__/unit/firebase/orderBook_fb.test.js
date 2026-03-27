/**
 * Order Book Module Tests
 *
 * Tests pure helper functions in backend/firebase/orderBook_fb.js:
 * - docToOrder(): Firestore document -> order object conversion
 * - _formatDate(): date formatting helper
 * - Collection constants validation
 */

const orderBook = require('../../../backend/firebase/orderBook_fb');
const { docToOrder, _formatDate, ORDERS_COL, CART_COL, PACKED_COL } = orderBook._test;

// ============================================================================
// Collection Constants
// ============================================================================

describe('Collection constants', () => {
    test('ORDERS_COL is "orders"', () => {
        expect(ORDERS_COL).toBe('orders');
    });

    test('CART_COL is "cart_orders"', () => {
        expect(CART_COL).toBe('cart_orders');
    });

    test('PACKED_COL is "packed_orders"', () => {
        expect(PACKED_COL).toBe('packed_orders');
    });
});

// ============================================================================
// docToOrder()
// ============================================================================

describe('docToOrder()', () => {
    function makeMockDoc(id, data) {
        return {
            id,
            data: () => data,
        };
    }

    test('converts full document to order object', () => {
        const doc = makeMockDoc('doc123', {
            orderDate: '08/02/26',
            billingFrom: 'Emperor Spices',
            client: 'Test Client',
            lot: 'LOT-001',
            grade: '8 mm',
            bagbox: 'Bag',
            no: 10,
            kgs: 500,
            price: 2000,
            brand: 'Emperor',
            status: 'Pending',
            notes: 'Test note',
            packedDate: '09/02/26',
        });

        const result = docToOrder(doc);

        expect(result.id).toBe('doc123');
        expect(result.orderDate).toBe('08/02/26');
        expect(result.billingFrom).toBe('Emperor Spices');
        expect(result.client).toBe('Test Client');
        expect(result.lot).toBe('LOT-001');
        expect(result.grade).toBe('8 mm');
        expect(result.bagbox).toBe('Bag');
        expect(result.no).toBe(10);
        expect(result.kgs).toBe(500);
        expect(result.price).toBe(2000);
        expect(result.brand).toBe('Emperor');
        expect(result.status).toBe('Pending');
        expect(result.notes).toBe('Test note');
        expect(result.packedDate).toBe('09/02/26');
        expect(result.index).toBe('doc123');
    });

    test('defaults missing string fields to empty string', () => {
        const doc = makeMockDoc('doc456', {});
        const result = docToOrder(doc);

        expect(result.orderDate).toBe('');
        expect(result.billingFrom).toBe('');
        expect(result.client).toBe('');
        expect(result.lot).toBe('');
        expect(result.grade).toBe('');
        expect(result.bagbox).toBe('');
        expect(result.brand).toBe('');
        expect(result.notes).toBe('');
        expect(result.packedDate).toBe('');
    });

    test('defaults missing numeric fields to 0', () => {
        const doc = makeMockDoc('doc789', {});
        const result = docToOrder(doc);

        expect(result.no).toBe(0);
        expect(result.kgs).toBe(0);
        expect(result.price).toBe(0);
    });

    test('defaults missing status to "Pending"', () => {
        const doc = makeMockDoc('docXYZ', {});
        const result = docToOrder(doc);

        expect(result.status).toBe('Pending');
    });

    test('converts string numbers to Number type', () => {
        const doc = makeMockDoc('docNum', {
            no: '15',
            kgs: '750.5',
            price: '2500',
        });
        const result = docToOrder(doc);

        expect(result.no).toBe(15);
        expect(result.kgs).toBe(750.5);
        expect(result.price).toBe(2500);
    });

    test('uses doc.id as both id and index fields', () => {
        const doc = makeMockDoc('unique-id', { status: 'Pending' });
        const result = docToOrder(doc);

        expect(result.id).toBe('unique-id');
        expect(result.index).toBe('unique-id');
    });
});

// ============================================================================
// _formatDate()
// ============================================================================

describe('_formatDate()', () => {
    test('returns empty string for falsy input', () => {
        expect(_formatDate(null)).toBe('');
        expect(_formatDate(undefined)).toBe('');
        expect(_formatDate('')).toBe('');
        expect(_formatDate(0)).toBe('');
    });

    test('formats ISO date string to dd/mm/yy', () => {
        const result = _formatDate('2026-02-08');
        expect(result).toMatch(/^\d{2}\/\d{2}\/\d{2}$/);
    });

    test('formats dd/mm/yy input (passes through)', () => {
        const result = _formatDate('08/02/26');
        expect(result).toBe('08/02/26');
    });

    test('returns original value if toDate returns null', () => {
        // "not a date" can't be parsed by toDate()
        const result = _formatDate('not a date');
        expect(result).toBe('not a date');
    });

    test('formats Date-like string', () => {
        const result = _formatDate('2025-12-25');
        expect(result).toMatch(/^\d{2}\/\d{2}\/\d{2}$/);
    });
});
