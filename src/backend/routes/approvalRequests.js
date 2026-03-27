const router = require('express').Router();
const approvalRequests = require('../../../backend/firebase/approval_requests_fb');
const pushNotifications = require('../../../backend/firebase/push_notifications_fb');
const { requireAdmin } = require('../../../backend/middleware/auth');
const { getCachedResponse, setCachedResponse } = require('../middleware/apiCache');
const featureFlags = require('../../../backend/featureFlags');
const orderBook = require('../../../backend/firebase/orderBook_fb');
const stockCalc = require('../../../backend/firebase/stock_fb');
const expenses = require('../../../backend/firebase/expenses_fb');
const gatepasses = require('../../../backend/firebase/gatepasses_fb');

// POST /api/approval-requests -> POST /
router.post('/', async (req, res) => {
    try {
        const result = await approvalRequests.createRequest(req.body);

        if (result.success && result.request) {
            // Push notification for approval request
            pushNotifications.notifyApprovalRequest(
                result.request.requesterName,
                result.request.actionType,
                result.request.resourceType,
                result.request.summary || ''
            ).catch(err => console.error('[FCM] Approval push error:', err.message));
        }

        res.json(result);
    } catch (err) {
        console.error('[Approval Request] Create error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get all pending requests (admin only)
router.get('/pending', requireAdmin, async (req, res) => {
    try {
        const requests = await approvalRequests.getPendingRequests();
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[Approval Request] Pending error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get all requests (admin only)
router.get('/', requireAdmin, async (req, res) => {
    try {
        const cacheKey = '/api/approval-requests?' + JSON.stringify(req.query);
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        let data;
        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await approvalRequests.getAllRequestsPaginated({ limit, cursor });
            data = { success: true, requests: result.data, pagination: result.pagination };
        } else {
            const requests = await approvalRequests.getAllRequests();
            data = { success: true, requests };
        }
        setCachedResponse(cacheKey, data);
        res.json(data);
    } catch (err) {
        console.error('[Approval Request] Get all error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get user's own requests
router.get('/my/:userId', async (req, res) => {
    try {
        // IDOR protection: users can only access their own requests (admins can access any)
        const userRole = req.user?.role?.toLowerCase();
        if (req.user && req.user.id !== req.params.userId && userRole !== 'admin' && userRole !== 'superadmin' && userRole !== 'ops') {
            return res.status(403).json({ success: false, error: 'Access denied' });
        }
        const includeDismissed = req.query.includeDismissed === 'true';
        console.log(`[Approval] Fetching MY REQUESTS for userId: ${req.params.userId}, includeDismissed: ${includeDismissed}`);
        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await approvalRequests.getUserRequestsPaginated(req.params.userId, { limit, cursor, includeDismissed });
            return res.json({ success: true, requests: result.data, pagination: result.pagination });
        }
        const requests = await approvalRequests.getUserRequests(req.params.userId, includeDismissed);
        console.log(`[Approval] Found ${requests.length} requests for userId: ${req.params.userId}`);
        if (requests.length > 0) {
            console.log(`[Approval] First request requesterId: ${requests[0].requesterId}`);
        }
        res.json({ success: true, requests });
    } catch (err) {
        console.error('[Approval Request] User requests error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get pending count (for badge)
router.get('/count', async (req, res) => {
    try {
        const count = await approvalRequests.getPendingCount();
        res.json({ success: true, count });
    } catch (err) {
        console.error('[Approval Request] Count error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Approve request (admin only) - also executes the action
router.put('/:id/approve', requireAdmin, async (req, res) => {
    try {
        const { adminId, adminName } = req.body;
        const adminRole = req.user?.role?.toLowerCase() || '';
        const result = await approvalRequests.approveRequest(req.params.id, adminId, adminName, adminRole);

        if (result.success && result.shouldExecute) {
            // Execute the approved action
            try {
                console.log(`[Approval] Execution: resourceType=${result.resourceType}, actionType=${result.actionType}`);
                console.log(`[Approval] resourceData:`, JSON.stringify(result.resourceData, null, 2));
                console.log(`[Approval] proposedChanges:`, JSON.stringify(result.proposedChanges, null, 2));

                if (result.resourceType === 'order') {
                    if (result.actionType === 'delete') {
                        await orderBook.deleteOrder(result.resourceId);
                    } else if (result.actionType === 'edit') {
                        await orderBook.updateOrder(result.resourceId, result.proposedChanges);
                    } else if (result.actionType === 'create' || result.actionType === 'new_order') {
                        // Create new order from resourceData or proposedChanges
                        const orderData = result.resourceData || result.proposedChanges;
                        console.log(`[Approval] Creating new order with data:`, JSON.stringify(orderData, null, 2));
                        await orderBook.addOrder(orderData);
                        console.log(`✅ [Approval] Created new order from approval request`);
                        // Push notification to admins about approved order creation
                        pushNotifications.notifyNewOrders(adminId, adminName || 'Admin', [orderData])
                            .catch(err => console.error('[FCM] Push error:', err.message));
                    }
                } else if (result.resourceType === 'stock' || result.resourceType === 'stock_adjustment' || result.resourceType === 'purchase') {
                    if (result.actionType === 'stock_adjustment' || result.actionType === 'edit' || result.actionType === 'adjust') {
                        // Stock adjustment: extract data from whichever format was used
                        const adjData = result.resourceData || result.proposedChanges?.adjustment || result.proposedChanges;
                        await stockCalc.addStockAdjustment({
                            ...adjData,
                            userRole: 'admin', // Approval grants admin-level execution
                            requesterName: adminName || 'admin',
                        });
                    } else if (result.actionType === 'add_purchase' || result.actionType === 'create') {
                        // Purchase addition
                        const purchaseData = result.proposedChanges || result.resourceData;
                        await stockCalc.addPurchase(purchaseData);
                        console.log(`✅ [Approval] Added purchase from approval request`);
                    }
                } else if (result.resourceType === 'expense') {
                    // Execute expense addition (uses Firestore expenses module from Phase 7)
                    if (result.actionType === 'add_expense' || result.actionType === 'create') {
                        const expenseData = result.proposedChanges || result.resourceData;
                        await expenses.saveExpenseSheet(expenseData.date, expenseData.items || [], expenseData.submittedBy);
                        console.log(`✅ [Approval] Added expense from approval request`);
                    }
                } else if (result.resourceType === 'gatepass') {
                    // Execute gatepass creation (uses Firestore gatepasses module from Phase 7)
                    if (result.actionType === 'create') {
                        await gatepasses.createGatePass(result.resourceData);
                        console.log(`✅ [Approval] Created gatepass from approval request`);
                    }
                }
                result.executed = true;
            } catch (execErr) {
                console.error(`❌ [Approval] Execution error:`, execErr);
                result.executed = false;
                result.executionError = execErr.message;
            }
        }

        if (result.success && result.request) {
            // Push notification for approval resolved
            pushNotifications.notifyApprovalResolved(
                'approved', adminName,
                result.request.requesterName,
                result.request.actionType,
                result.request.resourceType,
                result.request.summary || ''
            ).catch(err => console.error('[FCM] Approval resolved push error:', err.message));
        }

        res.json(result);
    } catch (err) {
        console.error('[Approval Request] Approve error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Reject request (admin only)
router.put('/:id/reject', requireAdmin, async (req, res) => {
    try {
        const { adminId, adminName, reason, rejectionCategory } = req.body;
        const result = await approvalRequests.rejectRequest(req.params.id, adminId, adminName, reason, rejectionCategory);

        if (result.success && result.request) {
            // Push notification for rejection
            pushNotifications.notifyApprovalResolved(
                'rejected', adminName,
                result.request.requesterName,
                result.request.actionType,
                result.request.resourceType,
                reason || ''
            ).catch(err => console.error('[FCM] Rejection push error:', err.message));
        }

        res.json(result);
    } catch (err) {
        console.error('[Approval Request] Reject error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Dismiss a resolved request (hide from user's view after reading)
router.put('/:id/dismiss', async (req, res) => {
    try {
        console.log(`[Approval] Dismissing request ${req.params.id}`);
        const result = await approvalRequests.dismissRequest(req.params.id);
        res.json(result);
    } catch (err) {
        console.error('[Approval Request] Dismiss error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
