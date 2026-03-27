/**
 * Date Utility Tests
 *
 * Tests for backend/utils/date.js covering:
 * - toDate(): parse various date formats to Date objects
 * - formatSheetDate(): format Date to dd/mm/yy
 * - normalizeSheetDate(): round-trip normalization
 * - parseSheetDate(): alias for toDate with null handling
 */

const { toDate, formatSheetDate, normalizeSheetDate, parseSheetDate } = require('../../../backend/utils/date');

// ============================================================================
// toDate()
// ============================================================================

describe('toDate()', () => {
    describe('ISO string parsing', () => {
        test('parses ISO 8601 string', () => {
            const result = toDate('2026-02-08T09:00:00.000Z');
            expect(result).toBeInstanceOf(Date);
            expect(result.getFullYear()).toBe(2026);
        });

        test('parses ISO date-only string', () => {
            const result = toDate('2026-02-08');
            expect(result).toBeInstanceOf(Date);
            expect(result.getFullYear()).toBe(2026);
        });

        test('parses full ISO with timezone', () => {
            const result = toDate('2025-12-07T10:30:00Z');
            expect(result).toBeInstanceOf(Date);
            expect(result.getFullYear()).toBe(2025);
            expect(result.getUTCMonth()).toBe(11); // December = 11
        });
    });

    describe('Date object input', () => {
        test('returns a copy of Date object', () => {
            const input = new Date(2026, 1, 8); // Feb 8, 2026
            const result = toDate(input);
            expect(result).toBeInstanceOf(Date);
            expect(result.getTime()).toBe(input.getTime());
            // Should be a different reference
            expect(result).not.toBe(input);
        });

        test('handles invalid Date object', () => {
            const result = toDate(new Date('invalid'));
            expect(result).toBeNull();
        });
    });

    describe('Google Sheets serial dates', () => {
        test('parses numeric serial date', () => {
            // 45000 is approximately 2023-03-14 in Google Sheets epoch
            const result = toDate(45000);
            expect(result).toBeInstanceOf(Date);
            expect(result.getFullYear()).toBeGreaterThanOrEqual(2023);
        });

        test('parses serial date as string', () => {
            const result = toDate('45000');
            expect(result).toBeInstanceOf(Date);
        });

        test('ignores small numbers (not serial dates)', () => {
            const result = toDate(100);
            expect(result).toBeNull();
        });

        test('ignores very large numbers (not serial dates)', () => {
            const result = toDate(2000000);
            expect(result).toBeNull();
        });
    });

    describe('dd/mm/yy format', () => {
        test('parses dd/mm/yy format', () => {
            const result = toDate('08/02/26');
            expect(result).toBeInstanceOf(Date);
            expect(result.getDate()).toBe(8);
            expect(result.getMonth()).toBe(1); // February = 1
            expect(result.getFullYear()).toBe(2026);
        });

        test('parses another dd/mm/yy date', () => {
            const result = toDate('25/12/25');
            expect(result).toBeInstanceOf(Date);
            expect(result.getDate()).toBe(25);
            expect(result.getMonth()).toBe(11); // December = 11
            expect(result.getFullYear()).toBe(2025);
        });

        test('parses dd/mm/yyyy format', () => {
            const result = toDate('08/02/2026');
            expect(result).toBeInstanceOf(Date);
            expect(result.getDate()).toBe(8);
            expect(result.getMonth()).toBe(1);
            // Year parsing takes last 2 digits
            expect(result.getFullYear()).toBe(2026);
        });
    });

    describe('yyyy/mm/dd format', () => {
        test('parses yyyy/mm/dd format', () => {
            const result = toDate('2026/02/08');
            expect(result).toBeInstanceOf(Date);
            expect(result.getFullYear()).toBe(2026);
            expect(result.getMonth()).toBe(1);
            expect(result.getDate()).toBe(8);
        });
    });

    describe('null and edge cases', () => {
        test('returns null for null', () => {
            expect(toDate(null)).toBeNull();
        });

        test('returns null for undefined', () => {
            expect(toDate(undefined)).toBeNull();
        });

        test('returns null for empty string', () => {
            expect(toDate('')).toBeNull();
        });

        test('returns null for whitespace-only string', () => {
            expect(toDate('   ')).toBeNull();
        });

        test('returns null for non-date string', () => {
            expect(toDate('not a date')).toBeNull();
        });
    });
});

// ============================================================================
// formatSheetDate()
// ============================================================================

describe('formatSheetDate()', () => {
    test('formats Date object to dd/mm/yy', () => {
        const date = new Date(2026, 1, 8); // Feb 8, 2026
        const result = formatSheetDate(date);
        expect(result).toBe('08/02/26');
    });

    test('formats single-digit day/month with leading zeros', () => {
        const date = new Date(2026, 0, 5); // Jan 5, 2026
        const result = formatSheetDate(date);
        expect(result).toBe('05/01/26');
    });

    test('formats December date correctly', () => {
        const date = new Date(2025, 11, 25); // Dec 25, 2025
        const result = formatSheetDate(date);
        expect(result).toBe('25/12/25');
    });

    test('defaults to current date when called with no argument', () => {
        const result = formatSheetDate();
        expect(result).toMatch(/^\d{2}\/\d{2}\/\d{2}$/);
    });

    test('handles string date input (passes through toDate)', () => {
        const result = formatSheetDate('2026-02-08');
        expect(result).toMatch(/^\d{2}\/\d{2}\/\d{2}$/);
    });

    test('formats dd/mm/yy input through round-trip', () => {
        const result = formatSheetDate('08/02/26');
        expect(result).toBe('08/02/26');
    });
});

// ============================================================================
// normalizeSheetDate()
// ============================================================================

describe('normalizeSheetDate()', () => {
    test('normalizes ISO string to dd/mm/yy', () => {
        const result = normalizeSheetDate('2026-02-08');
        expect(result).toMatch(/^\d{2}\/\d{2}\/\d{2}$/);
    });

    test('normalizes dd/mm/yy to itself (idempotent)', () => {
        const result = normalizeSheetDate('08/02/26');
        expect(result).toBe('08/02/26');
    });

    test('returns empty string for null', () => {
        expect(normalizeSheetDate(null)).toBe('');
    });

    test('returns empty string for empty string', () => {
        expect(normalizeSheetDate('')).toBe('');
    });

    test('returns empty string for invalid date', () => {
        expect(normalizeSheetDate('not a date')).toBe('');
    });

    test('normalizes serial date number', () => {
        const result = normalizeSheetDate(45000);
        expect(result).toMatch(/^\d{2}\/\d{2}\/\d{2}$/);
    });
});

// ============================================================================
// parseSheetDate()
// ============================================================================

describe('parseSheetDate()', () => {
    test('parses valid date and returns Date object', () => {
        const result = parseSheetDate('08/02/26');
        expect(result).toBeInstanceOf(Date);
    });

    test('returns null for null', () => {
        expect(parseSheetDate(null)).toBeNull();
    });

    test('returns null for empty string', () => {
        expect(parseSheetDate('')).toBeNull();
    });

    test('returns null for invalid date', () => {
        expect(parseSheetDate('not a date')).toBeNull();
    });

    test('parses ISO string', () => {
        const result = parseSheetDate('2026-02-08');
        expect(result).toBeInstanceOf(Date);
    });
});
