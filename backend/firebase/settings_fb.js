/**
 * Settings Firebase Helper
 *
 * Manages app settings stored in Firestore `settings` collection.
 * Currently handles: notification_numbers (admin phones for order confirmations)
 */

const { getDb } = require('../firebaseClient');

const COLLECTION = 'settings';
const NOTIF_DOC = 'notification_numbers';

/**
 * Get notification phone numbers for order confirmations.
 * Returns { phones: [...], updatedAt, updatedBy } or defaults if not set.
 */
async function getNotificationNumbers() {
    const doc = await getDb().collection(COLLECTION).doc(NOTIF_DOC).get();
    if (!doc.exists) {
        // Return default seed numbers
        return {
            phones: ['919790005649', '919600308400'],
            updatedAt: null,
            updatedBy: null,
        };
    }
    const data = doc.data();
    return {
        phones: Array.isArray(data.phones) ? data.phones : [],
        updatedAt: data.updatedAt || null,
        updatedBy: data.updatedBy || null,
    };
}

/**
 * Update notification phone numbers.
 * @param {string[]} phones - Array of phone strings (with country code, e.g. "919790005649")
 * @param {string} updatedBy - Username of who made the change
 */
async function updateNotificationNumbers(phones, updatedBy) {
    const cleaned = (phones || []).map(p => String(p || '').trim()).filter(Boolean);
    await getDb().collection(COLLECTION).doc(NOTIF_DOC).set({
        phones: cleaned,
        updatedAt: new Date().toISOString(),
        updatedBy: updatedBy || 'unknown',
    });
    return { success: true, phones: cleaned };
}

module.exports = {
    getNotificationNumbers,
    updateNotificationNumbers,
};
