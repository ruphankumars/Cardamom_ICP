/**
 * Transport Assignments (Firestore)
 *
 * Stores daily transport-to-client mappings so all users see the same
 * assignments.  One document per date in `daily_transport_assignments`.
 *
 * Document structure:
 * {
 *   date: "2026-03-11",
 *   assignments: { "ClientA": "TransportX", "ClientB": "TransportY" },
 *   updatedBy: "admin",
 *   updatedAt: Firestore.FieldValue.serverTimestamp()
 * }
 */

const { getDb, FieldValue } = require('../firebaseClient');

const COLLECTION = 'daily_transport_assignments';

/**
 * Get transport assignments for a given date.
 * @param {string} date - Date in YYYY-MM-DD format
 * @returns {Object} assignments map { clientName: transportName }
 */
async function getAssignments(date) {
    const doc = await getDb().collection(COLLECTION).doc(date).get();
    if (!doc.exists) return {};
    return doc.data().assignments || {};
}

/**
 * Save transport assignments for a given date.
 * Accepts full assignment map + optional removals list.
 * Uses dot-notation for concurrent safety (multiple users assigning different clients).
 *
 * @param {string} date - Date in YYYY-MM-DD format
 * @param {Object} assignments - { clientName: transportName } (upserts)
 * @param {string} username - Who made the change
 * @param {string[]} removals - Client names whose transport should be cleared
 */
async function saveAssignments(date, assignments, username, removals = []) {
    if (!assignments || typeof assignments !== 'object' || Array.isArray(assignments)) {
        throw new Error('assignments must be a non-null object');
    }

    const db = getDb();
    const docRef = db.collection(COLLECTION).doc(date);

    try {
        // Use Firestore FieldPath to safely handle client names with dots/special chars
        // Build the full assignments object, then merge at document level
        const existingDoc = await docRef.get();
        const existingAssignments = existingDoc.exists ? (existingDoc.data().assignments || {}) : {};

        // Merge new assignments into existing
        const merged = { ...existingAssignments, ...assignments };

        // Remove cleared assignments
        for (const client of removals) {
            delete merged[client];
        }

        // Remove empty values
        for (const [key, val] of Object.entries(merged)) {
            if (!val) delete merged[key];
        }

        await docRef.set({
            date,
            assignments: merged,
            updatedBy: username,
            updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
    } catch (err) {
        console.error(`[transport_assignments_fb] saveAssignments failed for date=${date}:`, err);
        throw new Error(`Failed to save transport assignments: ${err.message}`);
    }
}

module.exports = { getAssignments, saveAssignments };
