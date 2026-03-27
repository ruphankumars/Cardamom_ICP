/**
 * Google Sheets API Client — Backup/Sync Utility Only
 * 
 * This is used ONLY by backup scripts to export data to Google Sheets.
 * The main application uses Firebase Firestore exclusively.
 */

const { google } = require('googleapis');
const path = require('path');
const fs = require('fs');

// Load credentials from credentials.json (has Sheets API access)
const KEYFILEPATH = path.join(__dirname, '../../credentials.json');

let auth;
if (fs.existsSync(KEYFILEPATH)) {
    // Use credentials.json file (has Google Sheets API enabled)
    auth = new google.auth.GoogleAuth({
        keyFile: KEYFILEPATH,
        scopes: ['https://www.googleapis.com/auth/spreadsheets'],
    });
    console.log('[Sheets-Backup] Using credentials.json file');
} else if (process.env.FIREBASE_CLIENT_EMAIL && process.env.FIREBASE_PRIVATE_KEY) {
    // Fallback to Firebase service account credentials
    auth = new google.auth.JWT(
        process.env.FIREBASE_CLIENT_EMAIL,
        null,
        process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n'),
        ['https://www.googleapis.com/auth/spreadsheets']
    );
    console.log('[Sheets-Backup] Using Firebase service account credentials');
} else {
    console.error('[Sheets-Backup] No credentials found!');
}

const sheets = google.sheets({ version: 'v4', auth });

function getSpreadsheetId() {
    return process.env.SPREADSHEET_ID;
}

/**
 * Write values to a specific range
 */
async function writeRange(range, values) {
    const spreadsheetId = getSpreadsheetId();
    await sheets.spreadsheets.values.update({
        spreadsheetId,
        range,
        valueInputOption: 'USER_ENTERED',
        requestBody: { values }
    });
}

/**
 * Clear a range
 */
async function clearRange(range) {
    const spreadsheetId = getSpreadsheetId();
    await sheets.spreadsheets.values.clear({
        spreadsheetId,
        range
    });
}

/**
 * Ensure a sheet exists, create if not
 */
async function ensureSheet(sheetName, headers = null) {
    const spreadsheetId = getSpreadsheetId();

    // Check if sheet exists
    const meta = await sheets.spreadsheets.get({ spreadsheetId });
    const exists = meta.data.sheets.some(s => s.properties.title === sheetName);

    if (!exists) {
        // Create the sheet
        await sheets.spreadsheets.batchUpdate({
            spreadsheetId,
            requestBody: {
                requests: [{
                    addSheet: { properties: { title: sheetName } }
                }]
            }
        });
        console.log(`[Sheets-Backup] Created sheet: ${sheetName}`);
    }

    // Write headers if provided
    if (headers && headers.length > 0) {
        await writeRange(`${sheetName}!A1`, [headers]);
    }
}

module.exports = {
    writeRange,
    clearRange,
    ensureSheet,
    getSpreadsheetId
};
