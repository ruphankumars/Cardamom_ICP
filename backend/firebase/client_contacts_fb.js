/**
 * Client Contacts Module — Firebase Firestore Backend
 * Replaces the ClientContactDetails Google Sheet lookup
 *
 * Collection: client_contacts
 * Document model: { name, phones: [String], phone (legacy), address, gstin, _normalizedName }
 */

const { getDb } = require('../../src/backend/database/sqliteClient');

const COLLECTION = 'client_contacts';

function col() { return getDb().collection(COLLECTION); }

function _norm(s) { return String(s || '').toLowerCase().replace(/\s+/g, ' ').trim(); }

// #61: Cache contacts in memory to avoid full collection scan on every lookup
let _contactsCache = null;
let _contactsCacheTime = 0;
const CONTACTS_CACHE_TTL = 5 * 60 * 1000; // 5 minutes

async function _getCachedContacts() {
    if (_contactsCache && (Date.now() - _contactsCacheTime) < CONTACTS_CACHE_TTL) {
        return _contactsCache;
    }
    const snap = await col().get();
    _contactsCache = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
    _contactsCacheTime = Date.now();
    return _contactsCache;
}

function _invalidateContactsCache() {
    _contactsCache = null;
    _contactsCacheTime = 0;
}

/**
 * Normalize phone data — handles both old `phone` string and new `phones` array
 */
function _normalizePhones(d) {
    if (Array.isArray(d.phones) && d.phones.length > 0) {
        return d.phones.map(p => String(p || '').trim()).filter(Boolean);
    }
    if (d.phone && String(d.phone).trim()) {
        return [String(d.phone).trim()];
    }
    return [];
}

/**
 * Get a single client's contact details by name (case-insensitive)
 */
async function getClientContact(clientName) {
    if (!clientName) return null;

    const contacts = await _getCachedContacts();
    if (!contacts.length) return null;

    const searchName = _norm(clientName);

    const _formatContact = (d) => {
        const phones = _normalizePhones(d);
        return {
            id: d.id,
            name: d.name || clientName,
            phones: phones,
            phone: phones[0] || '',    // backward compat
            address: d.address || '',
            gstin: d.gstin || ''
        };
    };

    // First pass: exact match (highest priority)
    for (const d of contacts) {
        if (_norm(d.name) === searchName) return _formatContact(d);
    }

    // Second pass: fuzzy match (substring either way)
    for (const d of contacts) {
        const docName = _norm(d.name);
        if (docName.includes(searchName) || searchName.includes(docName)) return _formatContact(d);
    }

    return null;
}

/**
 * Get all client contacts
 */
async function getAllClientContacts() {
    const snap = await col().get();
    return snap.docs.map(doc => {
        const d = doc.data();
        const phones = _normalizePhones(d);
        return {
            id: doc.id,
            ...d,
            phones: phones,
            phone: phones[0] || ''   // backward compat
        };
    });
}

/**
 * Add or update a client contact
 * Accepts either `phones` (array) or legacy `phone` (string)
 * `oldName` — if provided, searches by old name first (for rename support)
 */
async function upsertClientContact({ name, oldName, phone, phones, address, gstin }) {
    if (!name) throw new Error('Client name is required');

    // Determine if phones were explicitly provided in the request
    // phones=undefined means "not provided at all" → preserve existing
    // phones=[] means "user cleared all phones" → clear them
    // phones=["..."] means "user set these phones" → save them
    const phonesExplicit = phones !== undefined || phone !== undefined;

    // Normalize phones: prefer `phones` array, fall back to `phone` string
    let phoneArray = [];
    if (Array.isArray(phones) && phones.length > 0) {
        phoneArray = phones.map(p => String(p || '').trim()).filter(Boolean);
    } else if (phone) {
        phoneArray = [String(phone).trim()].filter(Boolean);
    }

    const normalizedName = _norm(name);
    const normalizedOldName = oldName ? _norm(oldName) : null;

    // Check for existing contact — try old name first (rename), then new name
    const snap = await col().get();
    let existingDocId = null;

    // First: try to find by oldName (if a rename is happening)
    if (normalizedOldName && normalizedOldName !== normalizedName) {
        for (const doc of snap.docs) {
            if (_norm(doc.data().name) === normalizedOldName) {
                existingDocId = doc.id;
                break;
            }
        }
    }

    // Second: fall back to finding by new name
    if (!existingDocId) {
        for (const doc of snap.docs) {
            if (_norm(doc.data().name) === normalizedName) {
                existingDocId = doc.id;
                break;
            }
        }
    }

    const data = {
        name: String(name).trim(),
        _normalizedName: normalizedName,
        _updatedAt: new Date().toISOString()
    };

    // Only overwrite phones if explicitly provided in request body
    if (phonesExplicit) {
        data.phones = phoneArray;
        data.phone = phoneArray[0] || '';    // backward compat
        console.log(`[ClientContact] Saving phones for "${name}": ${JSON.stringify(phoneArray)}`);
    } else {
        console.log(`[ClientContact] Phones not provided for "${name}", preserving existing`);
    }

    // Only overwrite address/gstin if explicitly provided (not undefined)
    if (address !== undefined) data.address = String(address || '').trim();
    if (gstin !== undefined) data.gstin = String(gstin || '').trim();

    if (existingDocId) {
        await col().doc(existingDocId).update(data);
        _invalidateContactsCache();
        return { success: true, action: 'updated', id: existingDocId };
    } else {
        // New contacts: set defaults for all fields
        if (!data.phones) { data.phones = []; data.phone = ''; }
        if (data.address === undefined) data.address = '';
        if (data.gstin === undefined) data.gstin = '';
        data._createdAt = new Date().toISOString();
        const ref = await col().add(data);
        _invalidateContactsCache();
        return { success: true, action: 'created', id: ref.id };
    }
}

module.exports = {
    getClientContact,
    getAllClientContacts,
    upsertClientContact
};
