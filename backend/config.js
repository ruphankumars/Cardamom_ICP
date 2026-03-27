// Port of AppConfig.gs

const CFG = {
    // Note: Sheets-era sheet names removed in Issue #11 (dead code cleanup).
    // All data now lives in Firestore collections.
    types: ['Colour Bold', 'Fruit Bold', 'Rejection'],
    absGrades: [
        '8 mm',
        '7.5 to 8 mm',
        '7 to 7.5 mm',
        '6.5 to 7 mm',
        '6 to 6.5 mm',
        '6 mm below'
    ],
    virtualGrades: [
        '8.5 mm',
        '7.8 bold',
        '7 to 8 mm',
        '6.5 to 8 mm',
        '6.5 to 7.5 mm',
        '6 to 7 mm',
        'Mini Bold',
        'Pan'
    ],
    saleOrderHeaders: [
        '8.5 mm',
        '8 mm',
        '7.8 bold',
        '7.5 to 8 mm',
        '7 to 8 mm',
        '6.5 to 8 mm',
        '7 to 7.5 mm',
        '6.5 to 7.5 mm',
        '6.5 to 7 mm',
        '6 to 7 mm',
        '6 to 6.5 mm',
        'Mini Bold',
        'Pan'
    ]
};

module.exports = CFG;
