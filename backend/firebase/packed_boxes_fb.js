/**
 * Packed Boxes Module — Firebase Firestore Backend
 *
 * Tracks packed boxes kept aside daily, billed later, with remaining inventory.
 *
 * Collection: packedBoxes
 */
const { getDb } = require('../../src/backend/database/sqliteClient');

const COLLECTION = 'packedBoxes';

function col() { return getDb().collection(COLLECTION); }

/**
 * Add today's packed boxes entry
 */
async function addPackedBoxes(date, grade, brand, boxesAdded, addedBy) {
    try {
        const now = new Date().toISOString();
        const kgsPerBox = 20;
        const totalKgs = boxesAdded * kgsPerBox;

        const doc = {
            date,
            grade,
            brand,
            boxesAdded: Number(boxesAdded),
            boxesBilled: 0,
            kgsPerBox,
            totalKgs,
            billedKgs: 0,
            addedBy: addedBy || '',
            updatedBy: addedBy || '',
            createdAt: now,
            updatedAt: now
        };

        const ref = await col().add(doc);
        return { success: true, id: ref.id, ...doc };
    } catch (err) {
        console.error('[PackedBoxes] addPackedBoxes error:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Update billed count for a specific date/grade/brand entry
 */
async function updateBilledBoxes(date, grade, brand, boxesBilled, updatedBy) {
    try {
        const now = new Date().toISOString();
        const kgsPerBox = 20;

        // Find the matching entry
        const snap = await col()
            .where('date', '==', date)
            .where('grade', '==', grade)
            .where('brand', '==', brand)
            .get();

        if (snap.empty) {
            return { success: false, error: 'No matching packed box entry found' };
        }

        const docRef = snap.docs[0].ref;
        const existing = snap.docs[0].data();
        const newBilled = Number(boxesBilled);

        if (newBilled > existing.boxesAdded) {
            return { success: false, error: 'Billed boxes cannot exceed added boxes' };
        }

        await docRef.update({
            boxesBilled: newBilled,
            billedKgs: newBilled * kgsPerBox,
            updatedBy: updatedBy || '',
            updatedAt: now
        });

        return { success: true, id: snap.docs[0].id };
    } catch (err) {
        console.error('[PackedBoxes] updateBilledBoxes error:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Get all entries for a specific date
 */
async function getTodayEntries(date) {
    try {
        const snap = await col().where('date', '==', date).get();
        const entries = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
        return { success: true, entries };
    } catch (err) {
        console.error('[PackedBoxes] getTodayEntries error:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Get remaining boxes across ALL dates, grouped by grade+brand.
 * remaining = sum(boxesAdded) - sum(boxesBilled) per grade+brand
 */
async function getRemainingBoxes() {
    try {
        const snap = await col().get();
        const grouped = {};

        snap.docs.forEach(doc => {
            const d = doc.data();
            const key = `${d.grade}|||${d.brand}`;
            if (!grouped[key]) {
                grouped[key] = { grade: d.grade, brand: d.brand, totalAdded: 0, totalBilled: 0 };
            }
            grouped[key].totalAdded += (d.boxesAdded || 0);
            grouped[key].totalBilled += (d.boxesBilled || 0);
        });

        const remaining = Object.values(grouped)
            .map(g => ({
                grade: g.grade,
                brand: g.brand,
                totalAdded: g.totalAdded,
                totalBilled: g.totalBilled,
                remainingBoxes: g.totalAdded - g.totalBilled,
                remainingKgs: (g.totalAdded - g.totalBilled) * 20
            }))
            .filter(g => g.remainingBoxes > 0);

        return { success: true, remaining };
    } catch (err) {
        console.error('[PackedBoxes] getRemainingBoxes error:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Get history for a specific date
 */
async function getHistoryForDate(date) {
    try {
        const snap = await col().where('date', '==', date).get();
        const entries = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
        return { success: true, entries };
    } catch (err) {
        console.error('[PackedBoxes] getHistoryForDate error:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Delete a packed box entry by document ID
 */
async function deletePackedBoxEntry(docId) {
    try {
        const docRef = col().doc(docId);
        const doc = await docRef.get();
        if (!doc.exists) {
            return { success: false, error: 'Entry not found' };
        }
        await docRef.delete();
        return { success: true, id: docId };
    } catch (err) {
        console.error('[PackedBoxes] deletePackedBoxEntry error:', err.message);
        return { success: false, error: err.message };
    }
}

module.exports = {
    addPackedBoxes,
    updateBilledBoxes,
    getTodayEntries,
    getRemainingBoxes,
    getHistoryForDate,
    deletePackedBoxEntry
};
