/**
 * Stock Calculation Engine Unit Tests
 *
 * Tests pure functions in backend/firebase/stock_fb.js:
 * - _norm(): string normalization
 * - _pickCanonFromText(): grade text -> canonical sale grade
 * - _chooseSaleRowName(): grade text -> sale row (Colour Bold, Fruit Bold, Rejection)
 * - _getRatio(): ratio extraction from config
 * - Constants validation: ABS_GRADES, VIRT_GRADES, TYPES, NET_HEADERS
 * - VIRTUAL_IMPACT_ON_ABSOLUTE and VIRTUAL_TO_ABSOLUTE_MAP mappings
 */

const stockFb = require('../../../backend/firebase/stock_fb');
const {
    _norm,
    _pickCanonFromText,
    _chooseSaleRowName,
    _getRatio,
    _SALE_CANON,
    ABS_GRADES,
    VIRT_GRADES,
    TYPES,
    NET_HEADERS,
    VIRTUAL_IMPACT_ON_ABSOLUTE,
    VIRTUAL_TO_ABSOLUTE_MAP,
    CONFIG_TTL,
    cache,
} = stockFb._test;

// ============================================================================
// _norm()
// ============================================================================

describe('_norm() - string normalization', () => {
    test('converts to lowercase', () => {
        expect(_norm('HELLO')).toBe('hello');
    });

    test('trims leading and trailing whitespace', () => {
        expect(_norm('  hello  ')).toBe('hello');
    });

    test('collapses multiple spaces to single space', () => {
        expect(_norm('7.5  to  8  mm')).toBe('7.5 to 8 mm');
    });

    test('handles null input', () => {
        expect(_norm(null)).toBe('');
    });

    test('handles undefined input', () => {
        expect(_norm(undefined)).toBe('');
    });

    test('handles empty string', () => {
        expect(_norm('')).toBe('');
    });

    test('handles numeric input', () => {
        expect(_norm(123)).toBe('123');
    });

    test('handles mixed case with whitespace', () => {
        expect(_norm('  Mini  BOLD  ')).toBe('mini bold');
    });

    test('handles tabs and newlines', () => {
        expect(_norm('8\tmm')).toBe('8 mm');
    });
});

// ============================================================================
// _pickCanonFromText() - Parameterized grade normalization tests
// ============================================================================

describe('_pickCanonFromText() - canonical grade matching', () => {
    // Test all 13 canonical sale grades with exact input
    describe('exact canonical grade inputs', () => {
        const canonicalCases = [
            ['8.5 mm', '8.5 mm'],
            ['8 mm', '8 mm'],
            ['7.8 bold', '7.8 bold'],
            ['7.5 to 8 mm', '7.5 to 8 mm'],
            ['7 to 8 mm', '7 to 8 mm'],
            ['6.5 to 8 mm', '6.5 to 8 mm'],
            ['7 to 7.5 mm', '7 to 7.5 mm'],
            ['6.5 to 7.5 mm', '6.5 to 7.5 mm'],
            ['6.5 to 7 mm', '6.5 to 7 mm'],
            ['6 to 7 mm', '6 to 7 mm'],
            ['6 to 6.5 mm', '6 to 6.5 mm'],
            ['mini bold', 'mini bold'],
            ['pan', 'pan'],
        ];

        test.each(canonicalCases)(
            'maps "%s" -> "%s"',
            (input, expected) => {
                expect(_pickCanonFromText(input)).toBe(expected);
            }
        );
    });

    // Edge cases: mixed case
    describe('case-insensitive matching', () => {
        test('MINI BOLD -> mini bold', () => {
            expect(_pickCanonFromText('MINI BOLD')).toBe('mini bold');
        });

        test('Mini Bold -> mini bold', () => {
            expect(_pickCanonFromText('Mini Bold')).toBe('mini bold');
        });

        test('PAN -> pan', () => {
            expect(_pickCanonFromText('PAN')).toBe('pan');
        });

        test('7.8 BOLD -> 7.8 bold', () => {
            expect(_pickCanonFromText('7.8 BOLD')).toBe('7.8 bold');
        });

        test('8 MM -> 8 mm', () => {
            expect(_pickCanonFromText('8 MM')).toBe('8 mm');
        });
    });

    // Edge cases: extra whitespace
    describe('whitespace handling', () => {
        test('leading/trailing spaces', () => {
            expect(_pickCanonFromText('  8 mm  ')).toBe('8 mm');
        });

        test('double spaces between words', () => {
            expect(_pickCanonFromText('7.5  to  8  mm')).toBe('7.5 to 8 mm');
        });

        test('tabs in text', () => {
            expect(_pickCanonFromText('mini\tbold')).toBe('mini bold');
        });
    });

    // Edge cases: variations
    describe('variation matching', () => {
        test('7.8bold (no space) falls back to numeric match 8 mm (word boundary needed for bold)', () => {
            // Without a space before "bold", the \bbold\b regex doesn't match
            // The numeric parser sees "7.8" and rounds to "8 mm"
            expect(_pickCanonFromText('7.8bold')).toBe('8 mm');
        });

        test('null input returns null', () => {
            expect(_pickCanonFromText(null)).toBeNull();
        });

        test('empty string returns null', () => {
            expect(_pickCanonFromText('')).toBeNull();
        });

        test('unrecognized text returns null', () => {
            expect(_pickCanonFromText('xyz unknown grade')).toBeNull();
        });

        test('8.5mm (no space) matches 8.5 mm', () => {
            expect(_pickCanonFromText('8.5mm')).toBe('8.5 mm');
        });
    });
});

// ============================================================================
// _chooseSaleRowName()
// ============================================================================

describe('_chooseSaleRowName() - sale row classification', () => {
    test('classifies "Colour Bold" text', () => {
        expect(_chooseSaleRowName('Colour Bold')).toBe('Colour Bold');
    });

    test('classifies "Color Bold" (American spelling)', () => {
        expect(_chooseSaleRowName('Color Bold')).toBe('Colour Bold');
    });

    test('classifies "colour bold" (lowercase)', () => {
        expect(_chooseSaleRowName('colour bold')).toBe('Colour Bold');
    });

    test('classifies "Fruit Bold"', () => {
        expect(_chooseSaleRowName('Fruit Bold')).toBe('Fruit Bold');
    });

    test('classifies "fruit bold" (lowercase)', () => {
        expect(_chooseSaleRowName('fruit bold')).toBe('Fruit Bold');
    });

    test('classifies "Rejection"', () => {
        expect(_chooseSaleRowName('Rejection')).toBe('Rejection');
    });

    test('classifies "rejection" (lowercase)', () => {
        expect(_chooseSaleRowName('rejection')).toBe('Rejection');
    });

    test('classifies "Split" as Rejection', () => {
        expect(_chooseSaleRowName('Split')).toBe('Rejection');
    });

    test('classifies "Sick" as Rejection', () => {
        expect(_chooseSaleRowName('Sick')).toBe('Rejection');
    });

    test('returns null for unmatched text', () => {
        expect(_chooseSaleRowName('Unknown Category')).toBeNull();
    });

    test('returns null for empty string', () => {
        expect(_chooseSaleRowName('')).toBeNull();
    });

    test('returns null for null', () => {
        expect(_chooseSaleRowName(null)).toBeNull();
    });
});

// ============================================================================
// _getRatio()
// ============================================================================

describe('_getRatio() - config ratio extraction', () => {
    const mockConfig = {
        ratios: {
            bold: {
                'Colour Bold': { '8 mm': 0.48, '7.5 to 8 mm': 0.25 },
                'Fruit Bold': { '8 mm': 0.10 },
            },
            float: {
                'Colour Bold': { '8 mm': 0.05 },
            },
            medium: {},
        },
    };

    test('extracts valid ratio (decimal form)', () => {
        expect(_getRatio(mockConfig, 'bold', 'Colour Bold', '8 mm')).toBe(0.48);
    });

    test('extracts another valid ratio', () => {
        expect(_getRatio(mockConfig, 'bold', 'Colour Bold', '7.5 to 8 mm')).toBe(0.25);
    });

    test('returns 0 for missing grade', () => {
        expect(_getRatio(mockConfig, 'bold', 'Colour Bold', '6 mm below')).toBe(0);
    });

    test('returns 0 for missing stock type', () => {
        expect(_getRatio(mockConfig, 'bold', 'Nonexistent', '8 mm')).toBe(0);
    });

    test('returns 0 for missing purchase type', () => {
        expect(_getRatio(mockConfig, 'nonexistent', 'Colour Bold', '8 mm')).toBe(0);
    });

    test('returns 0 for null config', () => {
        expect(_getRatio({}, 'bold', 'Colour Bold', '8 mm')).toBe(0);
    });

    test('converts percentage form (>1) to decimal', () => {
        const percentConfig = {
            ratios: {
                bold: {
                    'Colour Bold': { '8 mm': 48 }, // 48% stored as number
                },
            },
        };
        expect(_getRatio(percentConfig, 'bold', 'Colour Bold', '8 mm')).toBe(0.48);
    });

    test('handles NaN values by returning 0', () => {
        const badConfig = {
            ratios: {
                bold: {
                    'Colour Bold': { '8 mm': 'not-a-number' },
                },
            },
        };
        expect(_getRatio(badConfig, 'bold', 'Colour Bold', '8 mm')).toBe(0);
    });
});

// ============================================================================
// Constants validation
// ============================================================================

describe('Constants', () => {
    test('_SALE_CANON has exactly 14 canonical grades', () => {
        expect(_SALE_CANON).toHaveLength(14);
    });

    test('_SALE_CANON contains all expected grades', () => {
        const expected = [
            '8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm',
            '6.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm',
            '6 to 7 mm', '6 to 6.5 mm', '6 mm below', 'mini bold', 'pan',
        ];
        expected.forEach(grade => {
            expect(_SALE_CANON).toContain(grade);
        });
    });

    test('ABS_GRADES has 6 absolute grades', () => {
        expect(ABS_GRADES).toHaveLength(6);
    });

    test('ABS_GRADES contains expected grades', () => {
        expect(ABS_GRADES).toEqual([
            '8 mm', '7.5 to 8 mm', '7 to 7.5 mm',
            '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below',
        ]);
    });

    test('VIRT_GRADES has 8 virtual grades', () => {
        expect(VIRT_GRADES).toHaveLength(8);
    });

    test('TYPES has 3 stock types', () => {
        expect(TYPES).toEqual(['Colour Bold', 'Fruit Bold', 'Rejection']);
    });

    test('NET_HEADERS has 14 columns', () => {
        expect(NET_HEADERS).toHaveLength(14);
    });

    test('CONFIG_TTL is 5 minutes (300000 ms)', () => {
        expect(CONFIG_TTL).toBe(5 * 60 * 1000);
    });

    test('cache object has stockConfig and stockConfigExpiry', () => {
        expect(cache).toHaveProperty('stockConfig');
        expect(cache).toHaveProperty('stockConfigExpiry');
    });
});

// ============================================================================
// VIRTUAL_IMPACT_ON_ABSOLUTE mapping
// ============================================================================

describe('VIRTUAL_IMPACT_ON_ABSOLUTE mapping', () => {
    test('has entries for all 8 virtual grades', () => {
        const expectedKeys = [
            '8.5 mm', '7.8 bold', '7 to 8 mm', '6.5 to 8 mm',
            '6.5 to 7.5 mm', '6 to 7 mm', 'Mini Bold', 'Pan',
        ];
        expectedKeys.forEach(key => {
            // Use bracket notation since keys contain dots
            expect(key in VIRTUAL_IMPACT_ON_ABSOLUTE).toBe(true);
        });
    });

    test('8.5 mm impacts only absIdx 0 with factor 1.0', () => {
        expect(VIRTUAL_IMPACT_ON_ABSOLUTE['8.5 mm']).toEqual([
            { absIdx: 0, factor: 1.0 },
        ]);
    });

    test('7.8 bold splits evenly between absIdx 0 and 1', () => {
        expect(VIRTUAL_IMPACT_ON_ABSOLUTE['7.8 bold']).toEqual([
            { absIdx: 0, factor: 0.5 },
            { absIdx: 1, factor: 0.5 },
        ]);
    });

    test('Pan impacts only absIdx 5 with factor 1.0', () => {
        expect(VIRTUAL_IMPACT_ON_ABSOLUTE['Pan']).toEqual([
            { absIdx: 5, factor: 1.0 },
        ]);
    });

    test('6.5 to 8 mm splits into thirds across 3 abs grades', () => {
        const impact = VIRTUAL_IMPACT_ON_ABSOLUTE['6.5 to 8 mm'];
        expect(impact).toHaveLength(3);
        impact.forEach(entry => {
            expect(entry.factor).toBeCloseTo(1 / 3, 5);
        });
    });

    test('all factors for each virtual grade sum to approximately 1.0', () => {
        for (const [grade, impacts] of Object.entries(VIRTUAL_IMPACT_ON_ABSOLUTE)) {
            const sum = impacts.reduce((acc, { factor }) => acc + factor, 0);
            expect(sum).toBeCloseTo(1.0, 2);
        }
    });
});

// ============================================================================
// VIRTUAL_TO_ABSOLUTE_MAP mapping
// ============================================================================

describe('VIRTUAL_TO_ABSOLUTE_MAP mapping', () => {
    test('has entries for all 8 virtual grades', () => {
        expect(Object.keys(VIRTUAL_TO_ABSOLUTE_MAP)).toHaveLength(8);
    });

    test('8.5 mm maps to 8 mm with factor 1.0', () => {
        expect(VIRTUAL_TO_ABSOLUTE_MAP['8.5 mm']).toEqual([
            { grade: '8 mm', factor: 1.0 },
        ]);
    });

    test('Pan maps to 6 mm below with factor 1.0', () => {
        expect(VIRTUAL_TO_ABSOLUTE_MAP['Pan']).toEqual([
            { grade: '6 mm below', factor: 1.0 },
        ]);
    });

    test('7.8 bold splits evenly between 8 mm and 7.5 to 8 mm', () => {
        expect(VIRTUAL_TO_ABSOLUTE_MAP['7.8 bold']).toEqual([
            { grade: '8 mm', factor: 0.5 },
            { grade: '7.5 to 8 mm', factor: 0.5 },
        ]);
    });

    test('all map entries reference valid ABS_GRADES', () => {
        for (const [, maps] of Object.entries(VIRTUAL_TO_ABSOLUTE_MAP)) {
            maps.forEach(({ grade }) => {
                expect(ABS_GRADES).toContain(grade);
            });
        }
    });
});
