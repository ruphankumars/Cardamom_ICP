/**
 * Dropdown Data — Firebase Firestore CRUD
 *
 * Collection: dropdown_data
 * Documents: clients, grades, bagbox, brands
 * Each doc: { items: [...], lastUpdated: ISO string }
 */

const { getDb, FieldValue } = require('../../src/backend/database/sqliteClient');

const COLLECTION = 'dropdown_data';
const VALID_CATEGORIES = ['clients', 'grades', 'bagbox', 'brands', 'transports'];

// Map: category param -> Firestore doc ID
function _resolveDocId(category) {
    if (VALID_CATEGORIES.includes(category)) return category;
    // Also accept singular forms from frontend
    const map = { client: 'clients', grade: 'grades', brand: 'brands', transport: 'transports' };
    return map[category] || null;
}

function _norm(s) { return String(s || '').toLowerCase().replace(/\s+/g, '').trim(); }

// Levenshtein distance (same algorithm as workersAttendance_fb.js)
function levenshteinDistance(a, b) {
    const m = Array.from({ length: b.length + 1 }, (_, i) => [i]);
    for (let j = 0; j <= a.length; j++) m[0][j] = j;
    for (let i = 1; i <= b.length; i++)
        for (let j = 1; j <= a.length; j++)
            m[i][j] = Math.min(m[i - 1][j] + 1, m[i][j - 1] + 1, m[i - 1][j - 1] + (a[j - 1] !== b[i - 1] ? 1 : 0));
    return m[b.length][a.length];
}

// Compute similarity percentage (0–100)
function _similarity(a, b) {
    const na = _norm(a), nb = _norm(b);
    const maxLen = Math.max(na.length, nb.length);
    if (maxLen === 0) return 100;
    const dist = levenshteinDistance(na, nb);
    return Math.round((1 - dist / maxLen) * 100);
}

// ============================================================================
// READ
// ============================================================================

async function getDropdownOptions() {
    const db = getDb();
    const snap = await db.collection(COLLECTION).get();
    const options = { client: [], grade: [], bagbox: [], brand: [], transport: [] };
    snap.docs.forEach(doc => {
        const key = doc.id === 'clients' ? 'client' : doc.id === 'grades' ? 'grade' : doc.id === 'brands' ? 'brand' : doc.id === 'transports' ? 'transport' : doc.id;
        if (options[key] !== undefined) {
            options[key] = doc.data().items || [];
        }
    });
    return options;
}

async function getDropdownCategory(category) {
    const docId = _resolveDocId(category);
    if (!docId) throw new Error(`Invalid category: ${category}`);
    const doc = await getDb().collection(COLLECTION).doc(docId).get();
    if (!doc.exists) return { category: docId, items: [] };
    return { category: docId, items: doc.data().items || [], lastUpdated: doc.data().lastUpdated || null };
}

// ============================================================================
// SEARCH (fuzzy matching for inline add)
// ============================================================================

async function searchDropdownItems(category, query) {
    const docId = _resolveDocId(category);
    if (!docId) throw new Error(`Invalid category: ${category}`);

    const doc = await getDb().collection(COLLECTION).doc(docId).get();
    const items = doc.exists ? (doc.data().items || []) : [];
    const q = _norm(query);
    if (!q) return { exactMatches: [], similarMatches: [] };

    const exactMatches = [];
    const similarMatches = [];

    items.forEach(item => {
        const n = _norm(item);
        if (n === q) {
            exactMatches.push({ value: item, similarity: 100 });
        } else {
            const sim = _similarity(query, item);
            if (sim >= 50) { // 50%+ similarity threshold
                similarMatches.push({ value: item, similarity: sim });
            }
        }
    });

    similarMatches.sort((a, b) => b.similarity - a.similarity);

    return {
        exactMatches,
        similarMatches: similarMatches.slice(0, 10)
    };
}

// ============================================================================
// ADD (with duplicate check)
// ============================================================================

async function addDropdownItem(category, value) {
    const docId = _resolveDocId(category);
    if (!docId) throw new Error(`Invalid category: ${category}`);
    const trimmed = String(value || '').trim();
    if (!trimmed) throw new Error('Value cannot be empty');

    const db = getDb();
    const ref = db.collection(COLLECTION).doc(docId);

    return await db.runTransaction(async (transaction) => {
        const doc = await transaction.get(ref);
        const items = doc.exists ? (doc.data().items || []) : [];

        // Case-insensitive duplicate check
        const norm = _norm(trimmed);
        const dup = items.find(item => _norm(item) === norm);
        if (dup) {
            return { success: false, error: `"${dup}" already exists`, isDuplicate: true, existingValue: dup };
        }

        const newItems = [...items, trimmed];
        transaction.set(ref, { items: newItems, lastUpdated: new Date().toISOString() });

        console.log(`[Dropdown] Added "${trimmed}" to ${docId}`);
        return { success: true, item: trimmed };
    });
}

// ============================================================================
// FORCE ADD (skip duplicate check)
// ============================================================================

async function forceAddDropdownItem(category, value) {
    const docId = _resolveDocId(category);
    if (!docId) throw new Error(`Invalid category: ${category}`);
    const trimmed = String(value || '').trim();
    if (!trimmed) throw new Error('Value cannot be empty');

    const ref = getDb().collection(COLLECTION).doc(docId);
    await ref.set({
        items: FieldValue.arrayUnion(trimmed),
        lastUpdated: new Date().toISOString()
    }, { merge: true });

    console.log(`[Dropdown] Force-added "${trimmed}" to ${docId}`);
    return { success: true, item: trimmed };
}

// ============================================================================
// UPDATE (rename item)
// ============================================================================

async function updateDropdownItem(category, oldValue, newValue) {
    const docId = _resolveDocId(category);
    if (!docId) throw new Error(`Invalid category: ${category}`);
    const oldTrimmed = String(oldValue || '').trim();
    const newTrimmed = String(newValue || '').trim();
    if (!oldTrimmed || !newTrimmed) throw new Error('Both old and new values are required');
    if (oldTrimmed === newTrimmed) return { success: true, message: 'No change' };

    const db = getDb();
    const ref = db.collection(COLLECTION).doc(docId);

    return await db.runTransaction(async (transaction) => {
        const doc = await transaction.get(ref);
        const items = doc.exists ? (doc.data().items || []) : [];

        // Check new value doesn't already exist
        if (items.find(item => _norm(item) === _norm(newTrimmed))) {
            return { success: false, error: `"${newTrimmed}" already exists` };
        }

        const idx = items.findIndex(item => item === oldTrimmed);
        if (idx === -1) {
            return { success: false, error: `"${oldTrimmed}" not found` };
        }

        const newItems = [...items];
        newItems[idx] = newTrimmed;
        transaction.set(ref, { items: newItems, lastUpdated: new Date().toISOString() });

        console.log(`[Dropdown] Renamed "${oldTrimmed}" → "${newTrimmed}" in ${docId}`);
        return { success: true, oldValue: oldTrimmed, newValue: newTrimmed };
    });
}

// ============================================================================
// DELETE
// ============================================================================

async function deleteDropdownItem(category, value) {
    const docId = _resolveDocId(category);
    if (!docId) throw new Error(`Invalid category: ${category}`);
    const trimmed = String(value || '').trim();
    if (!trimmed) throw new Error('Value cannot be empty');

    const ref = getDb().collection(COLLECTION).doc(docId);
    await ref.update({
        items: FieldValue.arrayRemove(trimmed),
        lastUpdated: new Date().toISOString()
    });

    console.log(`[Dropdown] Deleted "${trimmed}" from ${docId}`);
    return { success: true, deleted: trimmed };
}

// ============================================================================
// CLIENT MERGE (deduplicate old vs new name formats)
// ============================================================================

/**
 * Find potential duplicate client names by grouping on normalized form.
 * Returns groups where the same client appears under multiple name formats.
 */
async function findDuplicateClients() {
    const doc = await getDb().collection(COLLECTION).doc('clients').get();
    const items = doc.exists ? (doc.data().items || []) : [];

    // Group by normalized key: lowercase, strip non-alphanumeric, remove common suffixes
    const groups = {};
    for (const name of items) {
        // Normalize: lowercase, strip " - CityName" suffix, remove non-alphanumeric
        const withoutCity = name.replace(/\s*-\s*[^-]+$/, '');
        const key = withoutCity.toLowerCase().replace(/[^a-z0-9]/g, '');
        if (!key) continue;
        if (!groups[key]) groups[key] = [];
        groups[key].push(name);
    }

    // Return only groups with duplicates
    const duplicates = [];
    for (const [, names] of Object.entries(groups)) {
        if (names.length <= 1) continue;
        // Prefer the name with a city suffix (" - ") as canonical
        names.sort((a, b) => {
            const aHasCity = a.includes(' - ') ? 1 : 0;
            const bHasCity = b.includes(' - ') ? 1 : 0;
            if (aHasCity !== bHasCity) return bHasCity - aHasCity;
            return a.length - b.length; // shorter = probably abbreviated
        });
        duplicates.push({
            canonical: names[0],
            duplicates: names.slice(1),
        });
    }

    return { success: true, count: duplicates.length, groups: duplicates };
}

/**
 * Merge one client name into another across all order collections.
 *
 * @param {string} oldName - The old/duplicate client name to merge FROM
 * @param {string} newName - The canonical client name to merge INTO
 * @param {boolean} dryRun - If true, only return counts without making changes
 */
async function mergeClients(oldName, newName, dryRun = true) {
    const oldTrimmed = String(oldName || '').trim();
    const newTrimmed = String(newName || '').trim();
    if (!oldTrimmed || !newTrimmed) throw new Error('Both oldName and newName are required');
    if (oldTrimmed === newTrimmed) throw new Error('oldName and newName cannot be the same');

    const db = getDb();

    // Verify both names exist in the dropdown
    const clientsDoc = await db.collection(COLLECTION).doc('clients').get();
    const items = clientsDoc.exists ? (clientsDoc.data().items || []) : [];
    const hasOld = items.includes(oldTrimmed);
    const hasNew = items.includes(newTrimmed);

    if (!hasOld && !hasNew) throw new Error(`Neither "${oldTrimmed}" nor "${newTrimmed}" found in clients dropdown`);
    if (!hasNew) throw new Error(`Target name "${newTrimmed}" not found in clients dropdown`);

    // Query all 3 order collections for the old name
    const COLLECTIONS = ['orders', 'cart_orders', 'packed_orders'];
    const counts = {};
    const allDocs = {};

    for (const col of COLLECTIONS) {
        const snap = await db.collection(col).where('client', '==', oldTrimmed).get();
        counts[col] = snap.size;
        allDocs[col] = snap.docs;
    }

    const totalOrders = Object.values(counts).reduce((a, b) => a + b, 0);

    if (dryRun) {
        return {
            success: true,
            dryRun: true,
            oldName: oldTrimmed,
            newName: newTrimmed,
            oldNameInDropdown: hasOld,
            orders: counts.orders || 0,
            cart_orders: counts.cart_orders || 0,
            packed_orders: counts.packed_orders || 0,
            totalOrders,
        };
    }

    // Execute merge — batch update all orders with rollback tracking
    const BATCH_SIZE = 450;
    let totalUpdated = 0;
    const completedBatches = []; // Track for partial failure diagnosis

    for (const col of COLLECTIONS) {
        const docs = allDocs[col];
        for (let i = 0; i < docs.length; i += BATCH_SIZE) {
            const batch = db.batch();
            const chunk = docs.slice(i, i + BATCH_SIZE);
            for (const doc of chunk) {
                batch.update(doc.ref, { client: newTrimmed, _mergedFrom: oldTrimmed, _mergedAt: new Date().toISOString() });
            }
            try {
                await batch.commit();
                totalUpdated += chunk.length;
                completedBatches.push({ col, offset: i, count: chunk.length });
            } catch (err) {
                console.error(`[Merge] PARTIAL FAILURE at ${col} offset ${i}:`, err.message);
                console.error(`[Merge] Completed batches before failure:`, JSON.stringify(completedBatches));
                throw new Error(`Merge partially failed at ${col} (${totalUpdated} of ${totalOrders} updated). Check logs for recovery.`);
            }
        }
    }

    // Remove old name from dropdown
    let dropdownRemoved = false;
    if (hasOld) {
        await db.collection(COLLECTION).doc('clients').update({
            items: FieldValue.arrayRemove(oldTrimmed),
            lastUpdated: new Date().toISOString(),
        });
        dropdownRemoved = true;
    }

    // Merge client_contacts: transfer data from old → new, delete old
    let contactMerged = false;
    try {
        const contactsSnap = await db.collection('client_contacts').get();
        const normOld = oldTrimmed.toLowerCase().replace(/\s+/g, '').trim();
        const normNew = newTrimmed.toLowerCase().replace(/\s+/g, '').trim();
        let oldContact = null;
        let newContact = null;

        for (const doc of contactsSnap.docs) {
            const data = doc.data();
            const normName = (data._normalizedName || data.name || '').toLowerCase().replace(/\s+/g, '').trim();
            if (normName === normOld) oldContact = { ref: doc.ref, data };
            if (normName === normNew) newContact = { ref: doc.ref, data };
        }

        if (oldContact) {
            if (newContact) {
                // Merge: copy non-empty fields from old to new (don't overwrite existing)
                const updates = {};
                if (!newContact.data.address && oldContact.data.address) updates.address = oldContact.data.address;
                if (!newContact.data.gstin && oldContact.data.gstin) updates.gstin = oldContact.data.gstin;
                const oldPhones = oldContact.data.phones || (oldContact.data.phone ? [oldContact.data.phone] : []);
                const newPhones = newContact.data.phones || (newContact.data.phone ? [newContact.data.phone] : []);
                const mergedPhones = [...new Set([...newPhones, ...oldPhones])].filter(Boolean);
                if (mergedPhones.length > newPhones.length) updates.phones = mergedPhones;
                if (Object.keys(updates).length > 0) {
                    updates._updatedAt = new Date().toISOString();
                    await newContact.ref.update(updates);
                }
                await oldContact.ref.delete();
            } else {
                // No new contact exists — rename the old one
                await oldContact.ref.update({
                    name: newTrimmed,
                    _normalizedName: newTrimmed.toLowerCase().replace(/\s+/g, ''),
                    _updatedAt: new Date().toISOString(),
                });
            }
            contactMerged = true;
        }
    } catch (err) {
        console.error('[Merge] Contact merge error (non-fatal):', err.message);
    }

    console.log(`[Merge] Merged "${oldTrimmed}" → "${newTrimmed}": ${totalUpdated} orders updated`);

    return {
        success: true,
        dryRun: false,
        oldName: oldTrimmed,
        newName: newTrimmed,
        ordersUpdated: counts.orders || 0,
        cartUpdated: counts.cart_orders || 0,
        packedUpdated: counts.packed_orders || 0,
        totalUpdated,
        dropdownRemoved,
        contactMerged,
    };
}

// ============================================================================
// EXPORTS
// ============================================================================

module.exports = {
    getDropdownOptions,
    getDropdownCategory,
    searchDropdownItems,
    addDropdownItem,
    forceAddDropdownItem,
    updateDropdownItem,
    deleteDropdownItem,
    findDuplicateClients,
    mergeClients,
};
