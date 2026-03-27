/**
 * Audit Trail System - Phase 4.3
 * Records all critical operations (New Order, Dispatch, Edit, Delete)
 * Now backed by Firestore instead of Google Sheets
 */

const { getDb } = require('./firebaseClient');

/**
 * Log an action to the Firestore audit_log collection
 * @param {string} user User email or identifier
 * @param {string} action Action type (CREATE, UPDATE, DELETE, DISPATCH)
 * @param {string} target Target entity/ID
 * @param {Object} details Additional context/payload
 */
async function logAction(user, action, target, details = {}) {
    try {
        const timestamp = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' });
        const db = getDb();
        await db.collection('audit_log').add({
            timestamp,
            user: user || 'System',
            action,
            target,
            details: typeof details === 'object' ? details : { raw: details },
            createdAt: new Date().toISOString()
        });
        console.log(`[Audit] Action logged: ${action} by ${user} on ${target}`);
    } catch (err) {
        console.error('[Audit] Failed to log action:', err);
    }
}

/**
 * Retrieve recent audit logs from Firestore (legacy, no cursor).
 */
async function getRecentLogs(limit = 100) {
    try {
        const db = getDb();
        const snap = await db.collection('audit_log')
            .orderBy('createdAt', 'desc')
            .limit(limit)
            .get();
        return snap.docs.map(doc => {
            const d = doc.data();
            return {
                id: doc.id,
                timestamp: d.timestamp,
                user: d.user,
                action: d.action,
                target: d.target,
                details: d.details || {}
            };
        });
    } catch (err) {
        console.error('[Audit] Failed to fetch logs:', err);
        return [];
    }
}

/**
 * Retrieve paginated audit logs from Firestore using cursor-based pagination.
 *
 * @param {object} params
 * @param {number} params.limit - Page size (default 25, max 100)
 * @param {string|null} params.cursor - Firestore doc ID to start after
 * @returns {Promise<{ data: Array, pagination: { cursor, hasMore, limit } }>}
 */
async function getPaginatedLogs({ limit = 25, cursor = null } = {}) {
    try {
        limit = Math.max(1, Math.min(limit, 100));
        const db = getDb();
        const colRef = db.collection('audit_log');

        let query = colRef.orderBy('createdAt', 'desc').limit(limit + 1);

        if (cursor) {
            try {
                const cursorDoc = await colRef.doc(cursor).get();
                if (cursorDoc.exists) {
                    query = colRef.orderBy('createdAt', 'desc').startAfter(cursorDoc).limit(limit + 1);
                }
            } catch (e) { /* ignore invalid cursor */ }
        }

        const snap = await query.get();
        const docs = snap.docs.slice(0, limit);
        const hasMore = snap.docs.length > limit;

        const data = docs.map(doc => {
            const d = doc.data();
            return {
                id: doc.id,
                timestamp: d.timestamp,
                user: d.user,
                action: d.action,
                target: d.target,
                details: d.details || {}
            };
        });

        return {
            data,
            pagination: {
                cursor: hasMore ? docs[docs.length - 1].id : null,
                hasMore,
                limit
            }
        };
    } catch (err) {
        console.error('[Audit] Failed to fetch paginated logs:', err);
        return {
            data: [],
            pagination: { cursor: null, hasMore: false, limit }
        };
    }
}

module.exports = { logAction, getRecentLogs, getPaginatedLogs };
