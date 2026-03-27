const router = require('express').Router();
const clientRequests = require('../../../backend/firebase/client_requests_fb');
const users = require('../../../backend/firebase/users_fb');
const pushNotifications = require('../../../backend/firebase/push_notifications_fb');
const featureFlags = require('../../../backend/featureFlags');
const { requireAdmin, requireClient } = require('../../../backend/middleware/auth');

// Helper: extract user info from JWT-authenticated request
function getUserFromRequest(req) {
    if (req.user) {
        return { username: req.user.username, role: req.user.role };
    }
    // Never trust headers for auth — return unknown if JWT not present
    return { username: 'unknown', role: 'unknown' };
}

// Create a new client request
router.post('/', requireClient, async (req, res) => {
    try {
        const { requestType, items, initialStatus, sourceRequestId } = req.body;
        const initialMessage = req.body.initialMessage || req.body.initialText;
        // Extract username from JWT (secure) - ignore body values
        const { username } = getUserFromRequest(req);

        if (!username) {
            return res.status(400).json({ success: false, error: 'Username is required' });
        }

        // Get clientName from user profile in DB
        let finalClientName = req.body.clientName;
        if (!finalClientName) {
            const user = await users.getUserByUsername(username);
            if (user && user.clientName) {
                finalClientName = user.clientName;
            } else {
                finalClientName = username; // Fallback to username
            }
        }

        const result = await clientRequests.createClientRequest({
            clientUsername: username,
            clientName: finalClientName,
            requestType,
            items,
            initialText: initialMessage,
            initialStatus,
            sourceRequestId
        });

        res.json(result);
    } catch (err) {
        console.error('[POST /api/client-requests] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get requests for current client
router.get('/my', requireClient, async (req, res) => {
    try {
        // Extract username from JWT (secure)
        const { username } = getUserFromRequest(req);

        if (!username) {
            return res.status(400).json({ success: false, error: 'Username is required' });
        }

        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await clientRequests.getRequestsForClientPaginated(username, { limit, cursor });
            return res.json({ success: true, requests: result.data, pagination: result.pagination });
        }
        const requests = await clientRequests.getRequestsForClient(username);
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[GET /api/client-requests/my] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get all requests (admin only)
router.get('/', requireAdmin, async (req, res) => {
    try {
        const { status, client, type } = req.query;

        const filters = {};
        if (status) filters.status = status;
        if (client) filters.client = client; // Changed to client for name matching
        if (type) filters.type = type;

        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await clientRequests.getRequestsForAdminPaginated({ limit, cursor, filters });
            return res.json({ success: true, requests: result.data, pagination: result.pagination });
        }
        const requests = await clientRequests.getRequestsForAdmin(filters);
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[GET /api/client-requests] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get single request metadata
router.get('/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { username, role } = getUserFromRequest(req);

        if (!username) {
            return res.status(400).json({ success: false, error: 'Username required' });
        }

        const requestMeta = await clientRequests.getRequestMeta(id);

        // Verify access
        if (role === 'client' && requestMeta.clientUsername !== username) {
            return res.status(403).json({ success: false, error: 'Access denied' });
        }

        res.json({ success: true, request: requestMeta });
    } catch (err) {
        console.error('[GET /api/client-requests/:id] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get chat thread (with since parameter support)
router.get('/:id/chat', async (req, res) => {
    try {
        const { id } = req.params;
        const { since } = req.query;

        // Extract username and role from JWT (secure)
        const { username: finalUsername, role: finalRole } = getUserFromRequest(req);

        if (!finalUsername) {
            return res.status(400).json({ success: false, error: 'Username required' });
        }

        const messages = await clientRequests.getChatThread(id, finalRole, finalUsername, since);
        res.json({ success: true, messages });
    } catch (err) {
        console.error('[GET /api/client-requests/:id/chat] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Send a chat message
router.post('/:requestId/chat', async (req, res) => {
    try {
        const { requestId } = req.params;
        const { messageType, message, payload } = req.body;
        // Extract username and role from JWT (secure)
        const { username, role } = getUserFromRequest(req);

        if (!username || !role) {
            return res.status(400).json({ success: false, error: 'Username and role are required' });
        }

        // Authorization: only the request owner (client) or admin/ops can post
        const normalRole = role.toLowerCase();
        if (!['admin', 'superadmin', 'ops'].includes(normalRole)) {
            const requestMeta = await clientRequests.getRequestMeta(requestId);
            if (requestMeta.clientUsername !== username) {
                return res.status(403).json({ success: false, error: 'Not authorized to post to this request' });
            }
        }

        const senderRole = role === 'client' ? 'CLIENT' : 'ADMIN';

        const result = await clientRequests.appendChatMessage({
            requestId,
            senderRole,
            senderUsername: username,
            messageType: messageType || 'TEXT',
            message,
            payload
        });

        res.json(result);
    } catch (err) {
        console.error('[POST /api/client-requests/:requestId/chat] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Save agreed items (admin only)
router.post('/:requestId/agreed-items', requireAdmin, async (req, res) => {
    try {
        const { requestId } = req.params;
        const { agreedItems } = req.body;

        if (!agreedItems || !Array.isArray(agreedItems)) {
            return res.status(400).json({ success: false, error: 'agreedItems must be an array' });
        }

        const result = await clientRequests.saveAgreedItems(requestId, agreedItems);

        // Also append a system chat message
        await clientRequests.appendChatMessage({
            requestId,
            senderRole: 'ADMIN',
            senderUsername: 'system',
            messageType: 'SYSTEM',
            message: 'Admin has marked these items as agreed with prices.'
        });

        res.json(result);
    } catch (err) {
        console.error('[POST /api/client-requests/:requestId/agreed-items] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Update request status (admin only)
router.post('/:requestId/status', requireAdmin, async (req, res) => {
    try {
        const { requestId } = req.params;
        const { status } = req.body;

        if (!status) {
            return res.status(400).json({ success: false, error: 'status is required' });
        }

        const result = await clientRequests.updateRequestStatus(requestId, status);

        // Append a system chat message
        const statusMessages = {
            'NEGOTIATING': 'Admin has started negotiations.',
            'REJECTED': 'Admin has rejected this request.',
            'CANCELLED': 'This request has been cancelled.',
            'AGREED': 'Admin has agreed to this request.'
        };

        if (statusMessages[status]) {
            await clientRequests.appendChatMessage({
                requestId,
                senderRole: 'ADMIN',
                senderUsername: 'system',
                messageType: 'SYSTEM',
                message: statusMessages[status]
            });
        }

        res.json(result);
    } catch (err) {
        console.error('[POST /api/client-requests/:requestId/status] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Client starts bargaining
router.post('/:id/bargain', requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { username } = getUserFromRequest(req);

        const result = await clientRequests.clientStartBargain(id);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/bargain] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Save draft panel (client)
router.post(['/:id/draft', '/:id/save-draft'], requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { panelDraft } = req.body;
        const { username } = getUserFromRequest(req);

        if (!panelDraft) {
            return res.status(400).json({ success: false, error: 'panelDraft required' });
        }

        const result = await clientRequests.saveDraftPanel(id, 'CLIENT', panelDraft);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/save-draft] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Send panel message (client)
router.post(['/:id/send', '/:id/send-panel'], requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { panelSnapshot, optionalText } = req.body;
        const { username } = getUserFromRequest(req);

        if (!panelSnapshot) {
            return res.status(400).json({ success: false, error: 'panelSnapshot required' });
        }

        const result = await clientRequests.sendPanelMessage(id, 'CLIENT', username, panelSnapshot, optionalText);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/send-panel] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Confirm request (client)
router.post('/:id/confirm', requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { username } = getUserFromRequest(req);

        const result = await clientRequests.confirmRequest(id, 'CLIENT', username);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/confirm] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Cancel request (client)
router.post('/:id/cancel', requireClient, async (req, res) => {
    try {
        const { id } = req.params;
        const { reason } = req.body;
        const { username } = getUserFromRequest(req);

        const result = await clientRequests.cancelRequest(id, 'CLIENT', reason, username);
        res.json({ success: true, ...result });
    } catch (err) {
        console.error('[POST /api/client-requests/:id/cancel] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Cancel specific item / sub-order (admin only)
router.post('/:requestId/cancel-item', requireAdmin, async (req, res) => {
    console.log(`[Server] Received cancel-item request for ${req.params.requestId}`, req.body);
    try {
        const { index, reason } = req.body;
        // Extract role from JWT (secure)
        const { role } = getUserFromRequest(req);
        const result = await clientRequests.cancelRequestItem(req.params.requestId, index, role, reason);
        console.log('[Server] cancelRequestItem result:', result);
        res.json(result);
    } catch (err) {
        console.error('Error cancelling item:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Convert confirmed request to order (admin/ops only)
router.post('/:id/convert-to-order', requireAdmin, async (req, res) => {
    try {
        const { id } = req.params;
        const { billingFrom, brand, orders } = req.body;

        const result = await clientRequests.convertConfirmedToOrder(id, billingFrom, brand, orders);
        res.json({ success: true, ...result });

        // Push notification to other admins (fire-and-forget)
        pushNotifications.notifyNewOrders(req.user.id, req.user.username || 'Admin', orders || [])
            .catch(err => console.error('[FCM] Push error (convert):', err.message));
    } catch (err) {
        console.error('[POST /api/client-requests/:id/convert-to-order] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
