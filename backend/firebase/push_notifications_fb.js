/**
 * Push Notifications Module — ICP Polling-Based Queue
 *
 * Replaces Firebase Cloud Messaging with a SQLite-backed notification queue.
 * Notifications are persisted to the `notifications` table and polled by
 * the Flutter app via GET /api/notifications/poll.
 *
 * On ICP, FCM is not available. Instead of push, clients poll for new
 * notifications at regular intervals.
 */

const { getDb } = require('../../src/backend/database/sqliteClient');
const users = require('./users_fb');

/**
 * Notify all admins/superadmins (except the creator) about new order(s).
 *
 * @param {string|number} creatorId - The user ID of the order creator
 * @param {string} creatorName - Display name of the creator
 * @param {Array<Object>} orders - Array of order objects that were created
 */
async function notifyNewOrders(creatorId, creatorName, orders) {
    try {
        // Get FCM tokens for all admins except the creator
        const tokens = await users.getAdminFcmTokens(creatorId);

        if (!tokens || tokens.length === 0) {
            console.log('[FCM] No admin FCM tokens found — skipping push notification');
            return;
        }

        const orderCount = orders.length;
        const isBatch = orderCount > 1;

        // Build notification content
        let title, body, data;

        // Format: "Grade - Qty x rate - Brand - Notes"
        const formatOrderLine = (order) => {
            const grade = order.grade || '';
            const kgs = order.kgs || order.no || '';
            const price = order.price || '';
            const brand = order.brand || '';
            const notes = order.notes || '';
            let line = grade;
            if (kgs && price) line += ` - ${kgs}kg x ₹${price}`;
            else if (kgs) line += ` - ${kgs}kg`;
            if (brand) line += ` - ${brand}`;
            if (notes) line += ` - ${notes}`;
            return line;
        };

        // Extract billing entity short code (e.g. "ESPL" from "Emperor Spices Pvt Ltd")
        const billingFrom = orders[0]?.billingFrom || '';
        const clientName = orders[0]?.client || orders[0]?.clientName || 'Unknown';

        // Title: "ESPL - Client Name" or "billingFrom - Client Name"
        const billingShort = billingFrom || 'ESPL';
        title = `${billingShort} — ${clientName}`;

        // Body: order lines
        const lines = orders.map(formatOrderLine).filter(l => l.length > 0);
        body = lines.join('\n');

        data = {
            type: isBatch ? 'new_orders_batch' : 'new_order',
            orderCount: String(orderCount),
            screen: '/',
            createdBy: creatorName,
            client: clientName,
            billingFrom: billingShort,
            orderDetails: `Client: ${clientName}\n${body}`,
            orderId: String(orders[0]?.id || orders[0]?.orderId || ''),
        };

        console.log(`[Notifications] Persisting notification for ${tokens.length} admin device(s): "${body}"`);

        // On ICP, we persist notifications to SQLite instead of sending via FCM.
        // The Flutter app polls GET /api/notifications/poll to retrieve them.
        await persistNotification({ title, body, type: isBatch ? 'new_orders_batch' : 'new_order', data });
    } catch (err) {
        console.error('[FCM] Push notification error:', err.message);
        console.error('[FCM] Stack:', err.stack);
    }
}

/**
 * General-purpose push notification sender.
 *
 * @param {Object} opts
 * @param {string}   opts.title       - Notification title
 * @param {string}   opts.body        - Notification body text
 * @param {Object}   opts.data        - Custom data payload (all values must be strings)
 * @param {string}   [opts.excludeUserId] - User ID to exclude from recipients
 * @param {string}   [opts.threadId]  - iOS thread grouping ID
 * @param {string}   [opts.channelId] - Android notification channel (default: 'general')
 */
async function sendPush({ title, body, data = {}, excludeUserId, threadId, channelId = 'general' }) {
    try {
        console.log(`[Notifications] Persisting push notification: "${title}"`);

        // On ICP, persist to SQLite notification queue instead of FCM
        await persistNotification({ title, body, type: data.type || 'general', data });
    } catch (err) {
        console.error('[Notifications] sendPush error:', err.message);
    }
}

/**
 * Notify admins about a new approval request from a non-admin user.
 */
async function notifyApprovalRequest(requesterName, actionType, resourceType, details) {
    const actionLabel = actionType === 'create' ? 'New' :
        actionType === 'edit' ? 'Edit' :
            actionType === 'delete' ? 'Delete' : actionType;
    const resourceLabel = (resourceType || '').charAt(0).toUpperCase() + (resourceType || '').slice(1);

    await sendPush({
        title: `Approval Needed — ${resourceLabel}`,
        body: `${requesterName} requests ${actionLabel.toLowerCase()} ${resourceLabel.toLowerCase()}${details ? ': ' + details : ''}`,
        data: {
            type: 'approval_request',
            actionType: actionType || '',
            resourceType: resourceType || '',
            requesterName: requesterName || '',
            details: details || '',
        },
        threadId: 'approvals',
        channelId: 'approvals',
    });
}

/**
 * Notify the requester (and admins) when an approval is resolved.
 */
async function notifyApprovalResolved(status, adminName, requesterName, actionType, resourceType, details) {
    const isApproved = status === 'approved';
    const resourceLabel = (resourceType || '').charAt(0).toUpperCase() + (resourceType || '').slice(1);

    await sendPush({
        title: isApproved ? `✅ ${resourceLabel} Approved` : `❌ ${resourceLabel} Rejected`,
        body: `${adminName} ${status} ${requesterName}'s ${resourceLabel.toLowerCase()} request${details ? ': ' + details : ''}`,
        data: {
            type: 'approval_resolved',
            status: status || '',
            adminName: adminName || '',
            requesterName: requesterName || '',
            actionType: actionType || '',
            resourceType: resourceType || '',
            details: details || '',
        },
        threadId: 'approvals',
        channelId: 'approvals',
    });
}

// ═══════════════════════════════════════════════════════════════════════════
// DISPATCH & TRANSPORT DOC NOTIFICATIONS — Superadmin only + SQLite persistence
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Persist a notification to SQLite so it survives app restarts.
 * Stored in the `notifications` collection with { read: false }.
 */
async function persistNotification({ title, body, type, data = {} }) {
    try {
        const db = getDb();
        const id = `notif-${Date.now()}-${Math.random().toString(36).substr(2, 6)}`;
        await db.collection('notifications').doc(id).set({
            id,
            title,
            body,
            type,
            data,
            read: false,
            createdAt: new Date().toISOString(),
        });
        console.log(`[FCM] Notification persisted: ${id}`);
    } catch (err) {
        console.error('[FCM] Failed to persist notification:', err.message);
    }
}

/**
 * Send push to superadmin only (not all admins).
 */
async function sendSuperadminPush({ title, body, data = {}, threadId, channelId = 'documents' }) {
    try {
        console.log(`[Notifications] Persisting superadmin notification: "${title}"`);

        // On ICP, persist to SQLite notification queue instead of FCM
        await persistNotification({ title, body, type: data.type || 'document', data });
    } catch (err) {
        console.error('[Notifications] sendSuperadminPush error:', err.message);
    }
}

/**
 * Notify superadmin when a dispatch document is sent.
 * Format: "SYGT_Despatch_Doc sent for 'Client' for Invoice No XXXX by Sender"
 */
async function notifyDispatchDocSent({ companyName, clientName, invoiceNumber, createdBy }) {
    const company = (companyName || '').toLowerCase();
    const companyShort = (company === 'espl' || company.includes('emperor')) ? 'ESPL' : 'SYGT';
    const title = `${companyShort} — Despatch Document`;
    const body = `${companyShort}_Despatch_Doc sent for '${clientName || 'Unknown'}' for Invoice No ${invoiceNumber || 'N/A'} by ${createdBy || 'Unknown'}`;

    const data = {
        type: 'dispatch_doc',
        company: companyShort,
        clientName: clientName || '',
        invoiceNumber: invoiceNumber || '',
        createdBy: createdBy || '',
    };

    // Persist to SQLite notification queue
    await persistNotification({ title, body, type: 'dispatch_doc', data });
}

/**
 * Notify superadmin when a transport document is sent.
 * Format: "'Transporter' - Transport_Doc sent with 'X' page pdf dated - DD MMM YYYY by Sender"
 */
async function notifyTransportDocSent({ transportName, pageCount, date, createdBy }) {
    const title = `${transportName || 'Transport'} — Transport Document`;
    const body = `'${transportName || 'Unknown'}' - Transport_Doc sent with '${pageCount || '?'}' page pdf dated - ${date || 'N/A'} by ${createdBy || 'Unknown'}`;

    const data = {
        type: 'transport_doc',
        transportName: transportName || '',
        pageCount: String(pageCount || 0),
        date: date || '',
        createdBy: createdBy || '',
    };

    // Persist to SQLite notification queue
    await persistNotification({ title, body, type: 'transport_doc', data });
}

module.exports = {
    notifyNewOrders,
    sendPush,
    notifyApprovalRequest,
    notifyApprovalResolved,
    notifyDispatchDocSent,
    notifyTransportDocSent,
};
