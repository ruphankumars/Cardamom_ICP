/**
 * Shared Test Data Fixtures
 *
 * Centralized test data used across multiple test files.
 * Import what you need: const { testUsers, testOrders } = require('../fixtures/testData');
 */

const testUsers = {
    admin: {
        id: '1',
        username: 'testadmin',
        role: 'admin',
        displayName: 'Test Admin',
    },
    ops: {
        id: '2',
        username: 'testops',
        role: 'ops',
        displayName: 'Test Ops User',
    },
    client: {
        id: '3',
        username: 'testclient',
        role: 'client',
        displayName: 'Test Client',
    },
    employee: {
        id: '4',
        username: 'testemployee',
        role: 'employee',
        displayName: 'Test Employee',
    },
};

const testOrders = {
    basic: {
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
        notes: '',
    },
    withAllFields: {
        orderDate: '08/02/26',
        billingFrom: 'Emperor Spices',
        client: 'Premium Client',
        lot: 'LOT-002',
        grade: '7.5 to 8 mm',
        bagbox: 'Box',
        no: 5,
        kgs: 250,
        price: 2500,
        brand: 'Emperor Premium',
        status: 'Confirmed',
        notes: 'Priority order',
    },
};

const testGrades = {
    canonical: [
        '8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm',
        '6.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm',
        '6 to 7 mm', '6 to 6.5 mm', 'mini bold', 'pan',
    ],
    absGrades: ['8 mm', '7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below'],
    types: ['Colour Bold', 'Fruit Bold', 'Rejection'],
};

const testDates = {
    isoString: '2026-02-08T09:00:00.000Z',
    sheetFormat: '08/02/26',
    serialDate: 46055, // approximate serial date for 2026-02-08
    slashFormat: '08/02/26',
    dashFormat: '2026-02-08',
};

module.exports = {
    testUsers,
    testOrders,
    testGrades,
    testDates,
};
