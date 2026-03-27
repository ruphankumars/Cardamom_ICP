/**
 * Outstanding Payments Module — Google Sheets → Firestore name matching
 *
 * Reads "Formatted_Outstanding" tab from two Google Sheets (SYGT, ESPL),
 * parses payment data, and matches party names to Firebase client_contacts.
 *
 * Env vars: OUTSTANDING_SYGT_SHEET_ID, OUTSTANDING_ESPL_SHEET_ID
 * Firestore collection: client_name_mappings
 */

const { google } = require('googleapis');
const path = require('path');
const fs = require('fs');
const { getDb } = require('../firebaseClient');
const { getAllClientContacts } = require('./client_contacts_fb');

// ── Google Sheets auth (mirrors sheetsClient.js pattern) ───────────────
const KEYFILEPATH = path.join(__dirname, '../../credentials.json');
const SCOPES = ['https://www.googleapis.com/auth/spreadsheets.readonly'];

let _auth;
function _getAuth() {
    if (_auth) return _auth;
    if (process.env.GOOGLE_SERVICE_ACCOUNT_EMAIL && process.env.GOOGLE_PRIVATE_KEY) {
        _auth = new google.auth.GoogleAuth({
            credentials: {
                client_email: process.env.GOOGLE_SERVICE_ACCOUNT_EMAIL,
                private_key: process.env.GOOGLE_PRIVATE_KEY.replace(/\\n/g, '\n'),
            },
            scopes: SCOPES,
        });
    } else if (fs.existsSync(KEYFILEPATH)) {
        _auth = new google.auth.GoogleAuth({ keyFile: KEYFILEPATH, scopes: SCOPES });
    } else {
        throw new Error('[Outstanding] No Google credentials found');
    }
    return _auth;
}

let _sheets;
function _getSheetsApi() {
    if (_sheets) return _sheets;
    _sheets = google.sheets({ version: 'v4', auth: _getAuth() });
    return _sheets;
}

// ── Sheet config ───────────────────────────────────────────────────────
const SHEET_CONFIG = {
    sygt: {
        id: () => process.env.OUTSTANDING_SYGT_SHEET_ID,
        company: 'SYGT',
    },
    espl: {
        id: () => process.env.OUTSTANDING_ESPL_SHEET_ID,
        company: 'ESPL',
    },
};

const MAPPING_COLLECTION = 'client_name_mappings';
function mappingCol() { return getDb().collection(MAPPING_COLLECTION); }

// ── Google Sheets reader ───────────────────────────────────────────────
async function _readSheet(spreadsheetId, range) {
    const api = _getSheetsApi();
    const res = await api.spreadsheets.values.get({
        spreadsheetId,
        range,
        valueRenderOption: 'FORMATTED_VALUE',
    });
    return res.data.values || [];
}

// ── Parser: Formatted_Outstanding tab → structured data ────────────────
function _parseOutstandingSheet(rows, companyKey) {
    if (!rows || rows.length < 5) return null;

    // Row 1: company name, Row 2: "As on: dd/MM/yyyy", Row 3: spacer, Row 4: headers
    const companyFull = String(rows[0][0] || '').trim();
    const asOnRaw = String(rows[1][0] || '').trim();
    const asOnDate = asOnRaw.replace(/^As on:\s*/i, '').trim();

    // Parse data rows (starting from row 5, index 4)
    const clients = {};
    for (let i = 4; i < rows.length; i++) {
        const row = rows[i];
        if (!row || !row[0] || !String(row[0]).trim()) continue; // skip blank/spacer rows

        const date = String(row[0] || '').trim();
        const ref = String(row[1] || '').trim();
        const partyName = String(row[2] || '').trim();
        const amountRaw = String(row[3] || '').replace(/[₹\s,]/g, '').trim();
        const amount = Number(amountRaw) || 0;
        const days = parseInt(row[4], 10) || 0;

        if (!partyName) continue;

        if (!clients[partyName]) {
            clients[partyName] = { sheetName: partyName, bills: [], totalAmount: 0, oldestDays: 0 };
        }
        clients[partyName].bills.push({ date, ref, amount, days });
        clients[partyName].totalAmount += amount;
        if (days > clients[partyName].oldestDays) clients[partyName].oldestDays = days;
    }

    // Convert to sorted array (oldest first)
    const clientList = Object.values(clients)
        .map(c => ({ ...c, billCount: c.bills.length }))
        .sort((a, b) => b.oldestDays - a.oldestDays);

    return {
        company: companyKey.toUpperCase(),
        companyFull,
        asOnDate,
        clients: clientList,
    };
}

// ── Name matching engine ───────────────────────────────────────────────

/** Aggressive normalize: lowercase, remove dots/commas/punctuation, collapse spaces */
function _normalizeForMatch(name) {
    return String(name || '')
        .toLowerCase()
        .replace(/[.\-,()&/\\'"]/g, ' ')   // punctuation → space
        .replace(/\b(pvt|private|ltd|limited|llp|co|inc|corp|corporation|enterprises?|traders?|trading)\b/gi, '')
        .replace(/\s+/g, ' ')
        .trim();
}

/** Split into word tokens */
function _tokenize(name) {
    return _normalizeForMatch(name).split(/\s+/).filter(t => t.length > 0);
}

/** Score match 0–100 between a sheet name and a DB name */
function _scoreName(sheetName, dbName) {
    const normSheet = _normalizeForMatch(sheetName);
    const normDb = _normalizeForMatch(dbName);

    // Exact normalized match
    if (normSheet === normDb) return 100;

    // Substring match (one contains the other)
    if (normSheet.includes(normDb) || normDb.includes(normSheet)) return 85;

    // Token-based Jaccard similarity
    const tokA = new Set(_tokenize(sheetName));
    const tokB = new Set(_tokenize(dbName));
    if (tokA.size === 0 || tokB.size === 0) return 0;

    let intersection = 0;
    for (const t of tokA) { if (tokB.has(t)) intersection++; }
    const union = new Set([...tokA, ...tokB]).size;
    const jaccard = intersection / union;

    // If all tokens of one set appear in the other, boost
    if (intersection === tokA.size || intersection === tokB.size) {
        return Math.max(80, Math.round(jaccard * 100));
    }

    return Math.round(jaccard * 100);
}

/** Match sheet client names to Firebase contacts using saved mappings + auto-match */
async function _matchClients(sheetClients, dbContacts, savedMappings) {
    const mappingBySheet = {};
    for (const m of savedMappings) {
        const key = `${_normalizeForMatch(m.sheetName)}||${(m.company || '').toLowerCase()}`;
        mappingBySheet[key] = m.firebaseClientName;
    }

    return sheetClients.map(client => {
        // 1. Check saved mapping first
        for (const comp of ['sygt', 'espl', '']) {
            const key = `${_normalizeForMatch(client.sheetName)}||${comp}`;
            if (mappingBySheet[key]) {
                const contact = dbContacts.find(c =>
                    _normalizeForMatch(c.name) === _normalizeForMatch(mappingBySheet[key])
                );
                if (contact) {
                    return {
                        ...client,
                        matchedContact: {
                            name: contact.name,
                            phones: contact.phones || [],
                            matchScore: 100,
                            matchSource: 'saved',
                        },
                    };
                }
            }
        }

        // 2. Auto-match: score all DB contacts, pick best
        let bestMatch = null;
        let bestScore = 0;
        for (const contact of dbContacts) {
            const score = _scoreName(client.sheetName, contact.name);
            if (score > bestScore) {
                bestScore = score;
                bestMatch = contact;
            }
        }

        if (bestMatch && bestScore >= 50) {
            return {
                ...client,
                matchedContact: {
                    name: bestMatch.name,
                    phones: bestMatch.phones || [],
                    matchScore: bestScore,
                    matchSource: 'auto',
                },
            };
        }

        // 3. Unmatched
        return { ...client, matchedContact: null };
    });
}

// ── Firestore: name mappings CRUD ──────────────────────────────────────

async function getNameMappings() {
    const snap = await mappingCol().get();
    return snap.docs.map(d => ({ id: d.id, ...d.data() }));
}

async function saveNameMapping({ sheetName, company, firebaseClientName }) {
    if (!sheetName || !firebaseClientName) throw new Error('sheetName and firebaseClientName required');

    const norm = _normalizeForMatch(sheetName);
    const comp = (company || '').toLowerCase();

    // Upsert: check if mapping already exists for this sheetName + company
    const snap = await mappingCol()
        .where('_normSheetName', '==', norm)
        .where('company', '==', comp)
        .get();

    const data = {
        sheetName: String(sheetName).trim(),
        company: comp,
        firebaseClientName: String(firebaseClientName).trim(),
        _normSheetName: norm,
        _updatedAt: new Date().toISOString(),
    };

    if (!snap.empty) {
        await mappingCol().doc(snap.docs[0].id).update(data);
        return { success: true, action: 'updated', id: snap.docs[0].id };
    }

    data._createdAt = new Date().toISOString();
    const ref = await mappingCol().add(data);
    return { success: true, action: 'created', id: ref.id };
}

// ── Main export: get outstanding data ──────────────────────────────────

async function getOutstandingData(company = 'all') {
    const keys = company === 'all'
        ? Object.keys(SHEET_CONFIG)
        : [company.toLowerCase()];

    // Fetch in parallel: sheets + DB contacts + saved mappings
    const sheetPromises = keys.map(async (key) => {
        const cfg = SHEET_CONFIG[key];
        if (!cfg) throw new Error(`Unknown company: ${key}`);
        const sheetId = cfg.id();
        if (!sheetId) throw new Error(`Sheet ID not configured for ${key}. Set OUTSTANDING_${key.toUpperCase()}_SHEET_ID`);

        try {
            const rows = await _readSheet(sheetId, 'Formatted_Outstanding!A:E');
            return _parseOutstandingSheet(rows, key);
        } catch (err) {
            console.error(`[Outstanding] Failed to read ${key} sheet:`, err.message);
            return { company: key.toUpperCase(), companyFull: cfg.company, asOnDate: '', clients: [], error: err.message };
        }
    });

    const [sheetResults, dbContacts, savedMappings] = await Promise.all([
        Promise.all(sheetPromises),
        getAllClientContacts(),
        getNameMappings(),
    ]);

    // Match client names for each company
    const data = [];
    for (const result of sheetResults) {
        if (!result || !result.clients) { data.push(result); continue; }
        const matched = await _matchClients(result.clients, dbContacts, savedMappings);
        data.push({ ...result, clients: matched });
    }

    return data;
}

// ── Lightweight date check (avoids full data fetch) ─────────────────────

/**
 * Read ONLY row 2 ("As on: dd/MM/yyyy") from each Google Sheet.
 * Returns dates so the client can compare with cached data and skip re-fetch if unchanged.
 * Very cheap call — reads only 1 cell per sheet.
 */
async function getOutstandingDates() {
    const results = {};

    for (const [key, cfg] of Object.entries(SHEET_CONFIG)) {
        const sheetId = cfg.id();
        if (!sheetId) {
            results[key] = { date: null, error: `Sheet ID not configured for ${key}` };
            continue;
        }

        try {
            const rows = await _readSheet(sheetId, 'Formatted_Outstanding!A2:A2');
            const asOnRaw = String((rows[0] && rows[0][0]) || '').trim();
            const asOnDate = asOnRaw.replace(/^As on:\s*/i, '').trim();
            results[key] = { date: asOnDate || null };
        } catch (err) {
            console.error(`[Outstanding] Failed to read date for ${key}:`, err.message);
            results[key] = { date: null, error: err.message };
        }
    }

    return results;
}

module.exports = {
    getOutstandingData,
    getOutstandingDates,
    saveNameMapping,
    getNameMappings,
};
