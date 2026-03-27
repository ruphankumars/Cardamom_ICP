/**
 * UUID Mock for Jest
 *
 * The uuid v13+ package uses ESM which Jest can't handle natively.
 * This mock provides a simple CJS replacement for testing.
 */

let counter = 0;

module.exports = {
    v4: () => {
        counter++;
        return `00000000-0000-4000-8000-${String(counter).padStart(12, '0')}`;
    },
    v1: () => `10000000-0000-1000-8000-${String(++counter).padStart(12, '0')}`,
    NIL: '00000000-0000-0000-0000-000000000000',
    MAX: 'ffffffff-ffff-ffff-ffff-ffffffffffff',
    validate: (str) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str),
};
