/**
 * @deprecated SHEETS-ERA MODULE — retained only for migration scripts in backend/migrations/.
 * Not imported by server.js or any active runtime module.
 * Safe to delete once all migrations are confirmed complete.
 */
const { google } = require('googleapis');
const path = require('path');
const fs = require('fs');

// Load credentials from file or environment variables
const KEYFILEPATH = path.join(__dirname, '../credentials.json');
const SCOPES = ['https://www.googleapis.com/auth/spreadsheets'];
const CACHE_TTL_MS = Number(process.env.SHEETS_CACHE_MS || 5000);

// Create auth - support both file and environment variables
let auth;
if (process.env.GOOGLE_SERVICE_ACCOUNT_EMAIL && process.env.GOOGLE_PRIVATE_KEY) {
    // Cloud deployment: use environment variables
    auth = new google.auth.GoogleAuth({
        credentials: {
            client_email: process.env.GOOGLE_SERVICE_ACCOUNT_EMAIL,
            private_key: process.env.GOOGLE_PRIVATE_KEY.replace(/\\n/g, '\n'),
        },
        scopes: SCOPES,
    });
    console.log('[Sheets] Using environment variable credentials');
} else if (fs.existsSync(KEYFILEPATH)) {
    // Local development: use credentials file
    auth = new google.auth.GoogleAuth({
        keyFile: KEYFILEPATH,
        scopes: SCOPES,
    });
    console.log('[Sheets] Using credentials.json file');
} else {
    console.error('[Sheets] No credentials found! Set GOOGLE_SERVICE_ACCOUNT_EMAIL and GOOGLE_PRIVATE_KEY or provide credentials.json');
}

const sheets = google.sheets({ version: 'v4', auth });

// Helper to get the spreadsheet ID from environment or config
const getSpreadsheetId = () => process.env.SPREADSHEET_ID;

// Simple in-memory cache so rapid reloads don't hammer Google Sheets
const readCache = new Map();
const inFlightReads = new Map();
const clone2d = values => (values || []).map(row => [...row]);

// Cache sheet titles so we can auto-resolve names (e.g., fallback to *_table)
let sheetTitleCache = null;

async function loadSheetTitles(spreadsheetId) {
    if (sheetTitleCache) return sheetTitleCache;
    const meta = await sheets.spreadsheets.get({
        spreadsheetId,
        fields: 'sheets(properties/title)'
    });
    const titles = (meta.data.sheets || []).map(s => s.properties.title);
    sheetTitleCache = new Set(titles);
    return sheetTitleCache;
}

let sheetIdCache = null;

async function getSheetId(sheetName) {
    if (sheetIdCache && sheetIdCache[sheetName] !== undefined) return sheetIdCache[sheetName];

    const spreadsheetId = getSpreadsheetId();
    const meta = await sheets.spreadsheets.get({
        spreadsheetId,
        fields: 'sheets(properties/title,properties/sheetId)'
    });

    sheetIdCache = {};
    (meta.data.sheets || []).forEach(s => {
        sheetIdCache[s.properties.title] = s.properties.sheetId;
    });

    return sheetIdCache[sheetName];
}

// If a sheet name is missing, try `${name}_table` as seen in your screenshots.
async function resolveRangeWithFallback(range) {
    const idx = range.indexOf('!');
    if (idx === -1) return range; // no sheet name

    const spreadsheetId = getSpreadsheetId();
    const sheetName = range.slice(0, idx);
    const rest = range.slice(idx);

    try {
        const titles = await loadSheetTitles(spreadsheetId);
        if (titles.has(sheetName)) return range;
        // Try with _table suffix
        const alt = `${sheetName}_table`;
        if (titles.has(alt)) return alt + rest;
        // Try without _table suffix if the original had it
        if (sheetName.endsWith('_table')) {
            const withoutSuffix = sheetName.replace(/_table$/, '');
            if (titles.has(withoutSuffix)) return withoutSuffix + rest;
        }
        // Log available sheets for debugging
        console.warn(`[resolveRangeWithFallback] Sheet "${sheetName}" not found. Available sheets:`, Array.from(titles).slice(0, 10).join(', '));
        return range; // let API throw if not found
    } catch (err) {
        console.error('Error resolving sheet name for range', range, err);
        return range;
    }
}

function clearReadCache() {
    readCache.clear();
    inFlightReads.clear();
}

/**
 * Reads values from a specific range.
 * @param {string} range - e.g., 'Sheet1!A1:B2'
 * @returns {Promise<Array<Array<string>>>} - 2D array of values
 */
async function readRange(range, options = {}) {
    const spreadsheetId = getSpreadsheetId();
    const {
        valueRenderOption = 'UNFORMATTED_VALUE',
        dateTimeRenderOption = 'SERIAL_NUMBER',
        cache = true,
        cacheTtlMs = CACHE_TTL_MS
    } = options;

    try {
        const resolvedRange = await resolveRangeWithFallback(range);
        const cacheKey = `${resolvedRange}::${valueRenderOption}::${dateTimeRenderOption}`;
        const now = Date.now();

        if (cache && cacheTtlMs > 0) {
            const hit = readCache.get(cacheKey);
            if (hit && now - hit.ts < cacheTtlMs) {
                return clone2d(hit.data);
            }
            const pending = inFlightReads.get(cacheKey);
            if (pending) return pending;
        }

        const fetchPromise = (async () => {
            try {
                const response = await sheets.spreadsheets.values.get({
                    spreadsheetId,
                    range: resolvedRange,
                    valueRenderOption,
                    dateTimeRenderOption,
                });
                const values = response.data.values || [];
                if (cache && cacheTtlMs > 0) {
                    readCache.set(cacheKey, { ts: Date.now(), data: values });
                }
                return clone2d(values);
            } finally {
                inFlightReads.delete(cacheKey);
            }
        })();

        if (cache && cacheTtlMs > 0) {
            inFlightReads.set(cacheKey, fetchPromise);
        }

        return fetchPromise;
    } catch (error) {
        console.error(`Error reading range ${range}:`, error);
        throw error;
    }
}

/**
 * Writes values to a specific range.
 * @param {string} range - e.g., 'Sheet1!A1'
 * @param {Array<Array<string|number>>} values - 2D array of values
 */
async function writeRange(range, values) {
    const spreadsheetId = getSpreadsheetId();
    try {
        const resolvedRange = await resolveRangeWithFallback(range);
        await sheets.spreadsheets.values.update({
            spreadsheetId,
            range: resolvedRange,
            valueInputOption: 'USER_ENTERED',
            requestBody: {
                values,
            },
        });
        clearReadCache();
    } catch (error) {
        console.error(`Error writing to range ${range}:`, error);
        throw error;
    }
}

/**
 * Batch update multiple ranges (more efficient than individual writes)
 * @param {Array<{range: string, values: Array<Array>}>} updates
 */
async function batchUpdate(updates) {
    const spreadsheetId = getSpreadsheetId();
    if (!spreadsheetId) {
        throw new Error('SPREADSHEET_ID not configured');
    }

    if (!updates || updates.length === 0) {
        return;
    }

    try {
        // Resolve all ranges
        const resolvedUpdates = await Promise.all(updates.map(async (update) => {
            const resolvedRange = await resolveRangeWithFallback(update.range);
            return {
                range: resolvedRange,
                values: update.values
            };
        }));

        // Use batchUpdate API for efficiency
        await sheets.spreadsheets.values.batchUpdate({
            spreadsheetId,
            requestBody: {
                valueInputOption: 'USER_ENTERED',
                data: resolvedUpdates.map(update => ({
                    range: update.range,
                    values: update.values
                }))
            }
        });

        clearReadCache();
    } catch (error) {
        console.error(`Error batch updating ranges:`, error);
        throw error;
    }
}

/**
 * Appends rows to a sheet.
 * @param {string} range - e.g., 'Sheet1' or 'Sheet1!A:Z' (appends to the end)
 * @param {Array<Array<string|number>>} values - 2D array of values
 */
async function appendRow(range, values) {
    const spreadsheetId = getSpreadsheetId();
    try {
        // If range doesn't contain '!', it's just a sheet name - add a default range
        let resolvedRange = range;
        if (!range.includes('!')) {
            // It's just a sheet name, resolve with fallback and add default range
            const titles = await loadSheetTitles(spreadsheetId);
            let sheetName = range;
            // Check if the sheet exists as-is
            if (!titles.has(sheetName)) {
                // Try with _table suffix
                const alt = `${sheetName}_table`;
                if (titles.has(alt)) {
                    sheetName = alt;
                } else {
                    // Try without _table suffix if the original had it
                    if (sheetName.endsWith('_table')) {
                        const withoutSuffix = sheetName.replace(/_table$/, '');
                        if (titles.has(withoutSuffix)) {
                            sheetName = withoutSuffix;
                        } else {
                            // Sheet doesn't exist - throw a helpful error
                            throw new Error(`Sheet "${range}" not found. Available sheets: ${Array.from(titles).join(', ')}`);
                        }
                    } else {
                        // Sheet doesn't exist - throw a helpful error
                        throw new Error(`Sheet "${range}" not found. Available sheets: ${Array.from(titles).join(', ')}`);
                    }
                }
            }
            // Google Sheets API append needs the range format: SheetName!A:Z
            resolvedRange = `${sheetName}!A:Z`;
        } else {
            resolvedRange = await resolveRangeWithFallback(range);
        }

        // Manual append: Read sheet first to find next row
        // This fixes the issue where values.append overwrites rows in some cases
        const currentData = await readRange(`${resolvedRange}`, { cache: false });
        const nextRow = currentData ? currentData.length + 1 : 1;

        // Extract sheet name from resolvedRange (e.g. 'Sheet1!A:Z' -> 'Sheet1')
        const sheetNameMatch = resolvedRange.match(/^('?[^'!]+'?)/);
        const sheetName = sheetNameMatch ? sheetNameMatch[1] : resolvedRange.split('!')[0];

        const writeTarget = `${sheetName}!A${nextRow}`;

        await sheets.spreadsheets.values.update({
            spreadsheetId,
            range: writeTarget,
            valueInputOption: 'USER_ENTERED',
            requestBody: {
                values,
            },
        });
        clearReadCache();
    } catch (error) {
        console.error(`Error appending to range ${range}:`, error);
        throw error;
    }
}

/**
 * Clears values in a range.
 * @param {string} range 
 */
async function clearRange(range) {
    const spreadsheetId = getSpreadsheetId();
    try {
        const resolvedRange = await resolveRangeWithFallback(range);
        await sheets.spreadsheets.values.clear({
            spreadsheetId,
            range: resolvedRange,
        });
        clearReadCache();
    } catch (error) {
        console.error(`Error clearing range ${range}:`, error);
        throw error;
    }
}

/**
 * Deletes multiple rows from a sheet in a single batch update.
 * @param {number} sheetId - The ID of the sheet (not the name)
 * @param {Array<number>} rowIndices - Array of 1-based row indices to delete
 */
async function deleteRowsBatch(sheetId, rowIndices) {
    if (!rowIndices || rowIndices.length === 0) return;

    const spreadsheetId = getSpreadsheetId();
    try {
        // Sort descending to ensure we can delete in one go without shifting issues 
        // OR use specific indices if we are doing multiple requests in one batch update.
        // Google RECOMMENDS sorting descending if deleting one by one, 
        // but if we send multiple deleteDimension requests in ONE batch update,
        // we MUST sort descending so that deleting row 10 doesn't affect row 5.
        const sortedIndices = [...rowIndices].sort((a, b) => b - a);

        const requests = sortedIndices.map(index => ({
            deleteDimension: {
                range: {
                    sheetId: sheetId,
                    dimension: 'ROWS',
                    startIndex: index - 1, // 0-based
                    endIndex: index // exclusive
                }
            }
        }));

        await sheets.spreadsheets.batchUpdate({
            spreadsheetId,
            requestBody: {
                requests
            }
        });
        clearReadCache();
    } catch (error) {
        console.error(`Error batch deleting rows:`, error);
        throw error;
    }
}

/**
 * Deletes rows from a sheet.
 * @param {number} sheetId - The ID of the sheet (not the name)
 * @param {number} startIndex - 0-based start index
 * @param {number} endIndex - 0-based end index (exclusive)
 */
async function deleteRows(sheetId, startIndex, endIndex) {
    const spreadsheetId = getSpreadsheetId();
    try {
        await sheets.spreadsheets.batchUpdate({
            spreadsheetId,
            requestBody: {
                requests: [
                    {
                        deleteDimension: {
                            range: {
                                sheetId: sheetId,
                                dimension: 'ROWS',
                                startIndex: startIndex,
                                endIndex: endIndex
                            }
                        }
                    }
                ]
            }
        });
        clearReadCache();
    } catch (error) {
        console.error(`Error deleting rows ${startIndex}-${endIndex}:`, error);
        throw error;
    }
}

/**
 * Create a new sheet in the spreadsheet
 * @param {string} sheetName - Name of the sheet to create
 * @param {Array<string>} headers - Optional header row
 */
async function createSheet(sheetName, headers = null) {
    const spreadsheetId = getSpreadsheetId();
    try {
        // First check if sheet already exists
        const titles = await loadSheetTitles(spreadsheetId);
        if (titles.has(sheetName)) {
            console.log(`Sheet "${sheetName}" already exists`);
            return;
        }

        // Create the sheet
        await sheets.spreadsheets.batchUpdate({
            spreadsheetId,
            requestBody: {
                requests: [{
                    addSheet: {
                        properties: {
                            title: sheetName
                        }
                    }
                }]
            }
        });

        // Clear cache so new sheet is recognized
        sheetTitleCache = null;
        sheetIdCache = null;

        console.log(`Created sheet: ${sheetName}`);

        // Add headers if provided
        if (headers && headers.length > 0) {
            await writeRange(`${sheetName}!A1`, [headers]);
            console.log(`Added headers to ${sheetName}: ${headers.join(', ')}`);
        }
    } catch (error) {
        console.error(`Error creating sheet ${sheetName}:`, error);
        throw error;
    }
}

/**
 * Ensure a sheet exists, create it if not
 * @param {string} sheetName
 * @param {Array<string>} headers
 */
async function ensureSheet(sheetName, headers = null) {
    const spreadsheetId = getSpreadsheetId();
    const titles = await loadSheetTitles(spreadsheetId);
    if (!titles.has(sheetName)) {
        await createSheet(sheetName, headers);
    }
}

/**
 * Convert column number to column letter (1 -> A, 26 -> Z, 27 -> AA, etc.)
 */
function numberToColumnLetter(num) {
    let result = '';
    while (num > 0) {
        num--;
        result = String.fromCharCode(65 + (num % 26)) + result;
        num = Math.floor(num / 26);
    }
    return result;
}

/**
 * Update a specific row in a sheet
 * @param {string} sheetName - Name of the sheet
 * @param {number} rowIndex - 1-based row index
 * @param {Array} values - Array of values for the row
 */
async function updateRow(sheetName, rowIndex, values) {
    // Build range like "Sheet1!A2:AB2"
    const endCol = numberToColumnLetter(values.length);
    const range = `${sheetName}!A${rowIndex}:${endCol}${rowIndex}`;
    await writeRange(range, [values]);
}

/**
 * Delete a single row from a sheet by row number
 * @param {string} sheetName - Name of the sheet
 * @param {number} rowIndex - 1-based row index to delete
 */
async function deleteRow(sheetName, rowIndex) {
    const sheetId = await getSheetId(sheetName);
    await deleteRows(sheetId, rowIndex - 1, rowIndex); // Convert to 0-based
}

module.exports = {
    readRange,
    writeRange,
    batchUpdate,
    appendRow,
    clearRange,
    deleteRows,
    deleteRowsBatch,
    getSheetId,
    createSheet,
    ensureSheet,
    updateRow,
    deleteRow
};
