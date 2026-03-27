/**
 * Approval Requests Module — Firebase Firestore Backend
 * 
 * Drop-in replacement for ../approval_requests.js (Google Sheets version).
 * Exports the EXACT same API so server.js doesn't need changes.
 * 
 * Firestore collection: "approval_requests"
 * 
 * Improvements over Sheets version:
 *   - No column-range bugs (dismissed field works correctly)
 *   - Indexed queries (no full-collection scan for getUserRequests)
 *   - Atomic updates (no read-modify-write race)
 *   - No JSON.parse crashes (data stored natively as objects)
 *   - Real-time listeners possible (future enhancement)
 */

const { v4: uuidv4 } = require('uuid');
const { getDb } = require('../firebaseClient');

const COLLECTION = 'approval_requests';

// ============================================================================
// HELPERS
// ============================================================================

function approvalCol() {
    return getDb().collection(COLLECTION);
}

/** Valid rejection categories for the rejection dropdown */
const REJECTION_CATEGORIES = ['price_too_high', 'quality_concern', 'timing', 'insufficient_info', 'duplicate', 'other'];

/** Map resourceType to its Firestore collection name */
function resourceTypeToCollection(resourceType) {
    const mapping = {
        'order': 'orders',
        'orders': 'orders',
        'expense': 'expenses',
        'expenses': 'expenses',
        'gatepass': 'gatepasses',
        'gatepasses': 'gatepasses',
    };
    return mapping[resourceType] || resourceType;
}

/** Convert Firestore doc to response object (matches Sheets version format) */
function docToRequest(doc) {
    const data = doc.data();
    return {
        id: data.id || doc.id,
        requesterId: data.requesterId || '',
        requesterName: data.requesterName || '',
        actionType: data.actionType || '',
        resourceType: data.resourceType || '',
        resourceId: data.resourceId || '',
        resourceData: data.resourceData || null,       // Stored natively as object — no JSON.parse needed
        proposedChanges: data.proposedChanges || null,  // Stored natively as object — no JSON.parse needed
        reason: data.reason || '',
        status: data.status || 'pending',
        rejectionReason: data.rejectionReason || null,
        rejectionCategory: data.rejectionCategory || null,
        createdAt: data.createdAt || new Date().toISOString(),
        updatedAt: data.updatedAt || new Date().toISOString(),
        processedBy: data.processedBy || null,
        processedAt: data.processedAt || null,
        dismissed: data.dismissed === true,
        lockedByApproval: data.lockedByApproval || false,
        lockApprovalId: data.lockApprovalId || null,
    };
}

// ============================================================================
// CRUD — Same API signatures as ../approval_requests.js
// ============================================================================

/**
 * Create a new approval request
 */
async function createRequest(params) {
    try {
        const requestId = uuidv4();
        const now = new Date().toISOString();

        const newRequest = {
            id: requestId,
            requesterId: String(params.requesterId || ''),  // Always store as string for consistent querying
            requesterName: params.requesterName || '',
            actionType: params.actionType || '',
            resourceType: params.resourceType || '',
            resourceId: params.resourceId || '',
            resourceData: params.resourceData || null,       // Stored as native Firestore map
            proposedChanges: params.proposedChanges || null,  // Stored as native Firestore map
            reason: params.reason || '',
            status: 'pending',
            rejectionReason: null,
            createdAt: now,
            updatedAt: now,
            processedBy: null,
            processedAt: null,
            dismissed: false,
        };

        // Use the UUID as document ID for direct lookup
        await approvalCol().doc(requestId).set(newRequest);

        // Lock the target resource to prevent concurrent modifications while approval is pending
        if (params.resourceId) {
            try {
                const collectionName = resourceTypeToCollection(params.resourceType);
                const resourceRef = getDb().collection(collectionName).doc(params.resourceId);
                const resourceSnap = await resourceRef.get();
                if (resourceSnap.exists) {
                    await resourceRef.update({ lockedByApproval: true, lockApprovalId: requestId });
                    console.log(`[Approvals-FB] Locked resource ${collectionName}/${params.resourceId} for approval ${requestId}`);
                }
            } catch (lockErr) {
                console.warn('[Approvals-FB] Could not lock resource (non-fatal):', lockErr.message);
            }
        }

        return { success: true, request: newRequest };
    } catch (err) {
        console.error('[Approvals-FB] Error creating:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Get all pending requests (for admin)
 */
async function getPendingRequests() {
    const snapshot = await approvalCol()
        .where('status', '==', 'pending')
        .orderBy('createdAt', 'desc')
        .get();
    return snapshot.docs.map(docToRequest);
}

/**
 * Get all requests (for admin)
 */
async function getAllRequests() {
    const snapshot = await approvalCol()
        .orderBy('createdAt', 'desc')
        .get();
    return snapshot.docs.map(docToRequest);
}

/**
 * Get user's own requests
 * @param {string} userId
 * @param {boolean} includeDismissed - If false, filter out dismissed requests
 */
async function getUserRequests(userId, includeDismissed = false) {
    const userIdStr = String(userId);

    // Firestore is type-strict: requesterId may be stored as number or string
    // (legacy data from Sheets migration may have numbers). Query both types.
    const userIdNum = Number(userId);
    const possibleValues = [userIdStr];
    if (!isNaN(userIdNum)) possibleValues.push(userIdNum);

    let query = approvalCol().where('requesterId', 'in', possibleValues);

    if (!includeDismissed) {
        query = query.where('dismissed', '==', false);
    }

    const snapshot = await query.orderBy('createdAt', 'desc').get();
    const results = snapshot.docs.map(docToRequest);

    console.log(`[Approvals-FB] getUserRequests(${userIdStr}, includeDismissed=${includeDismissed}) → ${results.length} results`);
    return results;
}

/**
 * Approve a request
 */
async function approveRequest(requestId, adminId, adminName, adminRole) {
    try {
        const docRef = approvalCol().doc(requestId);

        const result = await getDb().runTransaction(async (transaction) => {
            const snap = await transaction.get(docRef);

            if (!snap.exists) {
                return { success: false, error: 'Request not found' };
            }

            const request = snap.data();

            if (request.status !== 'pending') {
                return { success: false, error: 'Request already processed' };
            }

            // Prevent self-approval for non-superadmin users
            // Superadmin can approve their own requests (highest authority)
            if (String(request.requesterId) === String(adminId) && adminRole !== 'superadmin') {
                return { success: false, error: 'Cannot approve your own request' };
            }

            const now = new Date().toISOString();
            const adminUsername = adminName || adminId;

            transaction.update(docRef, {
                status: 'approved',
                processedBy: adminUsername,
                processedAt: now,
                updatedAt: now,
            });

            // Return updated request object (matches Sheets version)
            const updated = {
                ...request,
                status: 'approved',
                processedBy: adminUsername,
                processedAt: now,
                updatedAt: now,
            };

            return {
                success: true,
                request: updated,
                shouldExecute: true,
                actionType: request.actionType,
                resourceType: request.resourceType,
                resourceId: request.resourceId,
                resourceData: request.resourceData,
                proposedChanges: request.proposedChanges,
            };
        });

        if (!result.success) return result;

        const request = result.request;
        const adminUsername = adminName || adminId;

        // Post-transaction side effects (notifications, stock adjustments, lock clearing)

        // Create notification for the requester
        try {
            const notifDoc = getDb().collection('notifications').doc();
            await notifDoc.set({
                id: notifDoc.id,
                userId: request.requesterId,
                userName: request.requesterName,
                title: `Request Approved: ${request.actionType} ${request.resourceType}`,
                body: `Your ${request.actionType} request for ${request.resourceType} has been approved by ${adminUsername}.`,
                type: 'approval_result',
                relatedRequestId: requestId,
                isRead: false,
                createdAt: new Date().toISOString()
            });
        } catch (notifErr) {
            console.warn('[Approvals-FB] Could not create approval notification (non-fatal):', notifErr.message);
        }

        // Handle special approval types that need post-approval actions
        // ISSUE STK-4: Apply stock adjustment when approval is granted
        if (result.actionType === 'stock_adjustment') {
            try {
                const stockFb = require('./stock_fb');
                await stockFb.applyApprovedStockAdjustment(requestId);
                console.log(`[Approvals-FB] Applied approved stock adjustment ${requestId}`);
            } catch (stockErr) {
                console.error('[Approvals-FB] Error applying stock adjustment:', stockErr.message);
                // Continue anyway - approval was recorded, just notify about the adjustment error
            }
        }

        // Clear lock on target resource
        if (result.resourceId) {
            try {
                const collectionName = resourceTypeToCollection(result.resourceType);
                const resourceRef = getDb().collection(collectionName).doc(result.resourceId);
                await resourceRef.update({ lockedByApproval: false, lockApprovalId: null });
                console.log(`[Approvals-FB] Unlocked resource ${collectionName}/${result.resourceId} after approval`);
            } catch (unlockErr) {
                console.warn('[Approvals-FB] Could not unlock resource (non-fatal):', unlockErr.message);
            }
        }

        return result;
    } catch (err) {
        console.error('[Approvals-FB] Error approving:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Reject a request
 * @param {string} requestId
 * @param {string} adminId
 * @param {string} adminName
 * @param {string} reason - Free-text rejection reason
 * @param {string} rejectionCategory - Category from REJECTION_CATEGORIES: 'price_too_high', 'quality_concern', 'timing', 'insufficient_info', 'duplicate', 'other'
 */
async function rejectRequest(requestId, adminId, adminName, reason, rejectionCategory = 'other') {
    try {
        const docRef = approvalCol().doc(requestId);

        // Validate rejection category
        const validCategory = REJECTION_CATEGORIES.includes(rejectionCategory) ? rejectionCategory : 'other';
        const adminUsername = adminName || adminId;
        const rejectionReason = reason || 'No reason provided';

        const result = await getDb().runTransaction(async (transaction) => {
            const snap = await transaction.get(docRef);

            if (!snap.exists) {
                return { success: false, error: 'Request not found' };
            }

            const request = snap.data();

            if (request.status !== 'pending') {
                return { success: false, error: 'Request already processed' };
            }

            const now = new Date().toISOString();

            transaction.update(docRef, {
                status: 'rejected',
                rejectionReason: rejectionReason,
                rejectionCategory: validCategory,
                processedBy: adminUsername,
                processedAt: now,
                updatedAt: now,
            });

            const updated = {
                ...request,
                status: 'rejected',
                rejectionReason: rejectionReason,
                rejectionCategory: validCategory,
                processedBy: adminUsername,
                processedAt: now,
                updatedAt: now,
            };

            return { success: true, request: updated };
        });

        if (!result.success) return result;

        const request = result.request;

        // Post-transaction side effects (notifications, lock clearing)

        // Create notification for the requester
        try {
            const notifDoc = getDb().collection('notifications').doc();
            await notifDoc.set({
                id: notifDoc.id,
                userId: request.requesterId,
                userName: request.requesterName,
                title: `Request Rejected: ${request.actionType} ${request.resourceType}`,
                body: `Your ${request.actionType} request for ${request.resourceType} has been rejected. Reason: ${rejectionReason}`,
                type: 'approval_result',
                relatedRequestId: requestId,
                isRead: false,
                createdAt: new Date().toISOString()
            });
        } catch (notifErr) {
            console.warn('[Approvals-FB] Could not create rejection notification (non-fatal):', notifErr.message);
        }

        // Clear lock on target resource
        if (request.resourceId) {
            try {
                const collectionName = resourceTypeToCollection(request.resourceType);
                const resourceRef = getDb().collection(collectionName).doc(request.resourceId);
                await resourceRef.update({ lockedByApproval: false, lockApprovalId: null });
                console.log(`[Approvals-FB] Unlocked resource ${collectionName}/${request.resourceId} after rejection`);
            } catch (unlockErr) {
                console.warn('[Approvals-FB] Could not unlock resource (non-fatal):', unlockErr.message);
            }
        }

        return result;
    } catch (err) {
        console.error('[Approvals-FB] Error rejecting:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Get all requests with cursor-based pagination.
 */
async function getAllRequestsPaginated({ limit = 25, cursor = null } = {}) {
    limit = Math.max(1, Math.min(limit, 100));

    let query = approvalCol().orderBy('createdAt', 'desc').limit(limit + 1);

    if (cursor) {
        try {
            const cursorDoc = await approvalCol().doc(cursor).get();
            if (cursorDoc.exists) {
                query = approvalCol().orderBy('createdAt', 'desc').startAfter(cursorDoc).limit(limit + 1);
            }
        } catch (e) { /* ignore */ }
    }

    const snapshot = await query.get();
    const docs = snapshot.docs.slice(0, limit);
    const hasMore = snapshot.docs.length > limit;

    return {
        data: docs.map(docToRequest),
        pagination: {
            cursor: hasMore ? docs[docs.length - 1].id : null,
            hasMore,
            limit
        }
    };
}

/**
 * Get user's own requests with cursor-based pagination.
 */
async function getUserRequestsPaginated(userId, { limit = 25, cursor = null, includeDismissed = false } = {}) {
    limit = Math.max(1, Math.min(limit, 100));
    const userIdStr = String(userId);
    const userIdNum = Number(userId);
    const possibleValues = [userIdStr];
    if (!isNaN(userIdNum)) possibleValues.push(userIdNum);

    let query = approvalCol().where('requesterId', 'in', possibleValues);
    if (!includeDismissed) {
        query = query.where('dismissed', '==', false);
    }
    query = query.orderBy('createdAt', 'desc').limit(limit + 1);

    if (cursor) {
        try {
            const cursorDoc = await approvalCol().doc(cursor).get();
            if (cursorDoc.exists) {
                let q2 = approvalCol().where('requesterId', 'in', possibleValues);
                if (!includeDismissed) {
                    q2 = q2.where('dismissed', '==', false);
                }
                query = q2.orderBy('createdAt', 'desc').startAfter(cursorDoc).limit(limit + 1);
            }
        } catch (e) { /* ignore */ }
    }

    const snapshot = await query.get();
    const docs = snapshot.docs.slice(0, limit);
    const hasMore = snapshot.docs.length > limit;

    return {
        data: docs.map(docToRequest),
        pagination: {
            cursor: hasMore ? docs[docs.length - 1].id : null,
            hasMore,
            limit
        }
    };
}

/**
 * Get pending count (for badge)
 */
async function getPendingCount() {
    const snapshot = await approvalCol()
        .where('status', '==', 'pending')
        .count()
        .get();
    return snapshot.data().count;
}

/**
 * Dismiss a resolved request (hide from user's view)
 */
async function dismissRequest(requestId) {
    try {
        const docRef = approvalCol().doc(requestId);
        const snap = await docRef.get();

        if (!snap.exists) {
            return { success: false, error: 'Request not found' };
        }

        const request = snap.data();

        if (request.status === 'pending') {
            return { success: false, error: 'Cannot dismiss pending request' };
        }

        await docRef.update({
            dismissed: true,
            updatedAt: new Date().toISOString(),
        });

        console.log(`[Approvals-FB] Dismissed request ${requestId}`);
        return { success: true, request: { ...request, dismissed: true } };
    } catch (err) {
        console.error('[Approvals-FB] Error dismissing:', err.message);
        return { success: false, error: err.message };
    }
}

module.exports = {
    createRequest,
    getPendingRequests,
    getAllRequests,
    getAllRequestsPaginated,
    getUserRequests,
    getUserRequestsPaginated,
    approveRequest,
    rejectRequest,
    getPendingCount,
    dismissRequest,
};
