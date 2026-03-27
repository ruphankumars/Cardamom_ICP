/**
 * WhatsApp Send Logs Module — Firestore
 * Logs all outbound WhatsApp messages sent via Meta Cloud API.
 * Collection: whatsapp_send_logs
 */
const { getDb, serverTimestamp } = require('../../src/backend/database/sqliteClient');

const COL = 'whatsapp_send_logs';
function col() { return getDb().collection(COL); }

/**
 * Log a WhatsApp send attempt
 * @param {Object} entry
 * @param {string} entry.recipient - Phone number sent to (e.g. "919940715653")
 * @param {string} entry.channel - "meta-sygt" or "meta-espl"
 * @param {string} entry.sender - Sender phone (e.g. "919790005649" or "916006560069")
 * @param {string} entry.templateName - Template used
 * @param {string} entry.status - "accepted", "failed"
 * @param {string} [entry.messageId] - WhatsApp message ID (wamid)
 * @param {string} [entry.error] - Error message if failed
 * @param {string} [entry.clientName] - Client/customer name
 * @param {string} [entry.company] - ESPL or SYGT
 * @param {string} [entry.type] - Message type (payment_reminder, order_confirm, etc.)
 * @param {string} [entry.requestId] - Request ID for correlation
 */
async function logSend(entry) {
    try {
        const doc = {
            ...entry,
            timestamp: new Date().toISOString(),
            createdAt: serverTimestamp(),
        };
        await col().add(doc);
    } catch (err) {
        console.error(`[WhatsAppLog] Failed to log send: ${err.message}`);
    }
}

/**
 * Get send logs with optional filters
 * @param {Object} [filters]
 * @param {string} [filters.recipient] - Filter by recipient phone
 * @param {string} [filters.channel] - Filter by channel (meta-sygt/meta-espl)
 * @param {string} [filters.type] - Filter by message type
 * @param {string} [filters.status] - Filter by status
 * @param {number} [filters.limit] - Max results (default 100)
 * @param {string} [filters.startDate] - ISO date string
 * @param {string} [filters.endDate] - ISO date string
 */
async function getLogs(filters = {}) {
    try {
        let q = col();
        // Apply equality filters first, then orderBy to avoid composite index requirements
        if (filters.channel) q = q.where('channel', '==', filters.channel);
        if (filters.type) q = q.where('type', '==', filters.type);
        if (filters.status) q = q.where('status', '==', filters.status);
        if (filters.recipient) q = q.where('recipient', '==', filters.recipient);
        q = q.orderBy('timestamp', 'desc');
        q = q.limit(filters.limit || 100);
        const snap = await q.get();
        return snap.docs.map(d => ({ id: d.id, ...d.data() }));
    } catch (err) {
        // Fallback without orderBy if composite index is missing
        console.error('[WhatsAppLogs] getLogs error (falling back):', err.message);
        let q = col();
        if (filters.channel) q = q.where('channel', '==', filters.channel);
        if (filters.type) q = q.where('type', '==', filters.type);
        if (filters.status) q = q.where('status', '==', filters.status);
        q = q.limit(filters.limit || 100);
        const snap = await q.get();
        const docs = snap.docs.map(d => ({ id: d.id, ...d.data() }));
        // Sort in JS instead
        docs.sort((a, b) => (b.timestamp || '').localeCompare(a.timestamp || ''));
        return docs;
    }
}

/**
 * Get send summary stats
 */
async function getStats() {
    const now = new Date();
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString();
    const snap = await col().where('timestamp', '>=', todayStart).get();
    let sent = 0, failed = 0;
    snap.docs.forEach(d => {
        const data = d.data();
        if (data.status === 'accepted') sent++;
        else failed++;
    });
    return { today: { sent, failed, total: snap.size } };
}

module.exports = { logSend, getLogs, getStats };
