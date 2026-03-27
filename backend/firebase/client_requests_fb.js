/**
 * Client Requests Module — Firebase Firestore Backend
 * 
 * Drop-in replacement for ../clientRequests.js (Google Sheets version).
 * Exports the EXACT same API so server.js doesn't need changes.
 * 
 * Firestore collections:
 *   - client_requests: one document per request (doc ID = request ID)
 *   - client_requests/{id}/messages: subcollection for chat (no full-scan)
 * 
 * Improvements over Sheets version:
 *   - Firestore transactions replace requestLock.js (true atomic operations)
 *   - Chat messages in subcollection (O(1) lookup, not O(all messages))
 *   - JSON fields stored natively (no stringify/parse, no crash on bad data)
 *   - getRequestMeta cache actually works (no unreachable code)
 *   - No row-index bugs, no column-range bugs
 */

const { getDb, runTransaction, serverTimestamp } = require('../firebaseClient');
const { formatSheetDate } = require('../utils/date');

// Use orderBook from the Firestore module (migrated in Phase 8)
// This is lazy-required to avoid circular dependency
let _orderBook = null;
function getOrderBook() {
    if (!_orderBook) _orderBook = require('./orderBook_fb');
    return _orderBook;
}

// Use stock module for stock validation when converting to order
// This is lazy-required to avoid circular dependency
let _stock = null;
function getStock() {
    if (!_stock) _stock = require('./stock_fb');
    return _stock;
}

// ============================================================================
// STATE MACHINE DEFINITIONS (same as Sheets version)
// ============================================================================

const REQUEST_STATUSES = {
    OPEN: 'OPEN',
    ADMIN_DRAFT: 'ADMIN_DRAFT',
    ADMIN_SENT: 'ADMIN_SENT',
    CLIENT_DRAFT: 'CLIENT_DRAFT',
    CLIENT_SENT: 'CLIENT_SENT',
    CONFIRMED: 'CONFIRMED',
    CANCELLED: 'CANCELLED',
    CONVERTED_TO_ORDER: 'CONVERTED_TO_ORDER'
};

const SUBORDER_STATUSES = {
    REQUESTED: 'REQUESTED',
    OFFERED: 'OFFERED',
    DECLINED: 'DECLINED',
    COUNTERED: 'COUNTERED',
    ACCEPTED: 'ACCEPTED',
    FINALIZED: 'FINALIZED'
};

const MESSAGE_KINDS = {
    PANEL: 'PANEL',
    TEXT: 'TEXT',
    SYSTEM: 'SYSTEM'
};

// ============================================================================
// HELPERS
// ============================================================================

function generateRequestId() {
    const timestamp = Date.now();
    const random = Math.floor(Math.random() * 1000);
    return `REQ-${timestamp}-${random}`;
}

function generateMessageId() {
    const timestamp = Date.now();
    const random = Math.floor(Math.random() * 10000);
    return `MSG-${timestamp}-${random}`;
}

function getCurrentTimestamp() {
    return new Date().toISOString();
}

function formatDate(date = new Date()) {
    return formatSheetDate(date);
}

/** Get the requests collection */
function requestsCol() {
    return getDb().collection('client_requests');
}

/** Get messages subcollection for a request */
function messagesCol(requestId) {
    return getDb().collection('client_requests').doc(requestId).collection('messages');
}

// ============================================================================
// PANEL JSON SCHEMA & VALIDATION (same as Sheets version)
// ============================================================================

function validatePanelSnapshot(panelSnapshot) {
    if (!panelSnapshot || typeof panelSnapshot !== 'object') {
        throw new Error('Panel snapshot must be an object');
    }
    if (typeof panelSnapshot.panelVersion !== 'number' || panelSnapshot.panelVersion < 1) {
        throw new Error('Panel snapshot must have valid panelVersion >= 1');
    }
    if (!panelSnapshot.items || !Array.isArray(panelSnapshot.items)) {
        throw new Error('Panel snapshot must have items array');
    }
    if (!panelSnapshot.stage || !Object.values(REQUEST_STATUSES).includes(panelSnapshot.stage)) {
        throw new Error('Panel snapshot must have valid stage');
    }
    for (const item of panelSnapshot.items) {
        if (!item.itemId) throw new Error('Each item must have itemId');
        if (typeof item.requestedNo !== 'number' || item.requestedNo < 0) throw new Error('Invalid requestedNo');
        if (typeof item.requestedKgs !== 'number' || item.requestedKgs < 0) throw new Error('Invalid requestedKgs');
        if (typeof item.offeredNo !== 'number' || item.offeredNo < 0) throw new Error('Invalid offeredNo');
        if (typeof item.offeredKgs !== 'number' || item.offeredKgs < 0) throw new Error('Invalid offeredKgs');
        if (typeof item.unitPrice !== 'number' || item.unitPrice < 0) throw new Error('Invalid unitPrice');
        if (!Object.values(SUBORDER_STATUSES).includes(item.status)) throw new Error(`Invalid status: ${item.status}`);
        if (item.status === SUBORDER_STATUSES.DECLINED && (item.offeredNo > 0 || item.offeredKgs > 0)) {
            throw new Error('Declined items must have offeredNo and offeredKgs = 0');
        }
    }
    return true;
}

function createInitialPanelSnapshot(items, requestType, initialStatus) {
    if (!items || !Array.isArray(items) || items.length === 0) {
        throw new Error('Items array is required and must not be empty');
    }
    const panelItems = items.map((item, index) => {
        if (!item) throw new Error(`Item at index ${index} is null or undefined`);
        const kgs = item.kgs !== undefined ? item.kgs : item.quantity;
        const requestedKgs = parseFloat(kgs || 0);
        const requestedNo = parseInt(item.no || 0, 10);
        const unitPrice = parseFloat(item.unitPrice || 0);

        let offeredKgs = 0, offeredNo = 0, pItemStatus = SUBORDER_STATUSES.REQUESTED;
        if (initialStatus === REQUEST_STATUSES.ADMIN_SENT) {
            offeredKgs = item.offeredKgs !== undefined ? parseFloat(item.offeredKgs) : requestedKgs;
            offeredNo = item.offeredNo !== undefined ? parseInt(item.offeredNo, 10) : requestedNo;
            pItemStatus = SUBORDER_STATUSES.OFFERED;
        }

        return {
            itemId: `I-${String(index + 1).padStart(3, '0')}`,
            type: String(item.type || '').trim() || 'N/A',
            grade: String(item.grade || '').trim(),
            bagbox: String(item.bagbox || '').trim() || '',
            requestedNo, requestedKgs, offeredNo, offeredKgs, unitPrice,
            status: pItemStatus,
            brand: String(item.brand || '').trim(),
            adminNote: String(item.adminNote || '').trim(),
            clientNote: String(item.clientNote || item.notes || '').trim()
        };
    });

    const totals = calculatePanelTotals(panelItems);
    let initialStage = REQUEST_STATUSES.OPEN;
    if (requestType === 'ENQUIRE_PRICE') initialStage = REQUEST_STATUSES.OPEN;
    else if (initialStatus) initialStage = initialStatus;

    return { panelVersion: 1, stage: initialStage, currency: 'INR', items: panelItems, totals };
}

function calculatePanelTotals(items) {
    return {
        requestedKgs: items.reduce((sum, i) => sum + (i.requestedKgs || 0), 0),
        offeredKgs: items.reduce((sum, i) => sum + (i.offeredKgs || 0), 0),
        offeredValue: items.reduce((sum, i) => sum + (i.offeredKgs || 0) * (i.unitPrice || 0), 0)
    };
}

// ============================================================================
// REQUEST CRUD
// ============================================================================

/** Get request metadata by ID */
async function getRequestMeta(requestId) {
    const doc = await requestsCol().doc(requestId).get();
    if (!doc.exists) throw new Error('Request not found');
    return { requestId: doc.id, ...doc.data() };
}

/** No-op (Firestore doesn't need cache invalidation) */
function invalidateRequestCache() { }

/** No-op for Firestore */
async function ensureSheetsInitialized() { }

/** Update request fields (batch) */
async function batchUpdateRequestFields(requestId, updates) {
    await requestsCol().doc(requestId).update({
        ...updates,
        updatedAt: getCurrentTimestamp()
    });
}

// ============================================================================
// INSERT CHAT MESSAGES (subcollection)
// ============================================================================

async function insertPanelMessage({ requestId, senderRole, senderUsername, panelSnapshot }) {
    validatePanelSnapshot(panelSnapshot);
    const messageId = generateMessageId();
    const timestamp = getCurrentTimestamp();

    await messagesCol(requestId).doc(messageId).set({
        messageId, requestId, timestamp,
        senderRole, senderUsername,
        messageKind: MESSAGE_KINDS.PANEL,
        panelVersion: panelSnapshot.panelVersion,
        panelSnapshot,  // Stored as native Firestore map — no JSON.stringify
        textMessage: null
    });
    await requestsCol().doc(requestId).update({ updatedAt: timestamp });
    return { success: true, messageId };
}

async function insertTextMessage({ requestId, senderRole, senderUsername, text, messageType = 'TEXT', payload = null }) {
    const messageId = generateMessageId();
    const timestamp = getCurrentTimestamp();

    await messagesCol(requestId).doc(messageId).set({
        messageId, requestId, timestamp,
        senderRole, senderUsername,
        messageKind: messageType,
        panelVersion: null,
        panelSnapshot: payload || null,
        textMessage: text
    });
    await requestsCol().doc(requestId).update({ updatedAt: timestamp });
    return { success: true, messageId };
}

// ============================================================================
// TASK 4.1.1: CREATE CLIENT REQUEST
// ============================================================================

async function createClientRequest({ clientUsername, clientName, requestType, items, initialText, initialStatus, sourceRequestId }) {
    if (!clientUsername || typeof clientUsername !== 'string' || clientUsername.trim() === '') throw new Error('clientUsername is required');
    if (!clientName || typeof clientName !== 'string' || clientName.trim() === '') throw new Error('clientName is required');
    if (!requestType || !['REQUEST_ORDER', 'ENQUIRE_PRICE'].includes(requestType)) throw new Error('requestType must be REQUEST_ORDER or ENQUIRE_PRICE');
    if (!items || !Array.isArray(items) || items.length === 0) throw new Error('items must be a non-empty array');

    for (let i = 0; i < items.length; i++) {
        const item = items[i];
        if (!item || typeof item !== 'object') throw new Error(`Item at index ${i} must be an object`);
        if (!item.grade || typeof item.grade !== 'string' || item.grade.trim() === '') throw new Error(`Item at index ${i} must have a non-empty grade`);
        const kgs = item.kgs !== undefined ? item.kgs : item.quantity;
        if (typeof kgs !== 'number' || kgs <= 0) throw new Error(`Item at index ${i} must have valid kgs > 0`);
    }

    const requestId = generateRequestId();
    const now = getCurrentTimestamp();
    const startStatus = initialStatus || REQUEST_STATUSES.OPEN;
    const initialPanel = createInitialPanelSnapshot(items, requestType, startStatus);

    let linkedData = '';
    if (sourceRequestId && requestType === 'REQUEST_ORDER') {
        linkedData = `CONVERTED_FROM:${sourceRequestId}`;
    }

    // Create the request document
    await requestsCol().doc(requestId).set({
        requestId,
        clientUsername, clientName, requestType,
        status: startStatus,
        createdAt: now, updatedAt: now,
        draftOwner: 'CLIENT',
        panelVersion: 1,
        requestedItems: items,         // Original items (native array, no JSON.stringify)
        currentItems: initialPanel.items,  // Working negotiated version
        finalItems: [],
        linkedOrderIds: linkedData,
        cancelReason: ''
    });

    // If conversion from enquiry, update source
    if (sourceRequestId) {
        await requestsCol().doc(sourceRequestId).update({
            linkedOrderIds: `CONVERTED_TO:${requestId}`
        });
    }

    // Insert initial PANEL message
    const initialSenderRole = startStatus === REQUEST_STATUSES.ADMIN_SENT ? 'ADMIN' : 'CLIENT';
    const initialSenderUsername = startStatus === REQUEST_STATUSES.ADMIN_SENT ? 'admin' : clientUsername;

    await insertPanelMessage({
        requestId, senderRole: initialSenderRole, senderUsername: initialSenderUsername,
        panelSnapshot: { ...initialPanel, totals: calculatePanelTotals(initialPanel.items) }
    });

    if (initialText) {
        await insertTextMessage({
            requestId, senderRole: initialSenderRole, senderUsername: initialSenderUsername, text: initialText
        });
    }

    return { success: true, requestId };
}

// ============================================================================
// TASK 4.1.2: GET CHAT THREAD
// ============================================================================

async function getChatThread(requestId, role, username, since = null) {
    const normalizedRole = role ? role.toUpperCase() : 'ADMIN';
    const meta = await getRequestMeta(requestId);

    if (normalizedRole === 'CLIENT' && meta.clientUsername !== username) {
        throw new Error('Access denied: You can only view your own requests');
    }

    let query = messagesCol(requestId).orderBy('timestamp', 'asc');

    if (since) {
        try {
            const sinceDate = new Date(since);
            if (!isNaN(sinceDate.getTime())) {
                query = query.where('timestamp', '>', since);
            }
        } catch (e) { /* ignore invalid since */ }
    }

    const snapshot = await query.get();

    return snapshot.docs
        .map(doc => {
            const d = doc.data();
            return {
                messageId: d.messageId || doc.id,
                requestId: d.requestId,
                timestamp: d.timestamp,
                senderRole: d.senderRole,
                senderUsername: d.senderUsername || 'unknown',
                messageType: d.messageKind || 'TEXT',
                panelVersion: d.panelVersion || null,
                panelSnapshot: d.panelSnapshot || null,  // Already a native object — no JSON.parse needed
                textMessage: d.textMessage || null,
                message: d.textMessage || null
            };
        })
        .filter(msg => {
            if (msg.messageType === 'PANEL' && !msg.panelSnapshot) return false;
            if (msg.messageType === 'TEXT' && !msg.textMessage) return false;
            return true;
        });
}

// ============================================================================
// TASK 4.1.4: ADMIN START DRAFT
// ============================================================================

async function adminStartDraft(requestId) {
    return runTransaction(async (txn) => {
        const docRef = requestsCol().doc(requestId);
        const doc = await txn.get(docRef);
        if (!doc.exists) throw new Error('Request not found');
        const meta = doc.data();

        if (meta.status === REQUEST_STATUSES.ADMIN_DRAFT) {
            return { success: true, currentItems: meta.currentItems || [] };
        }

        const allowed = [REQUEST_STATUSES.OPEN, REQUEST_STATUSES.CLIENT_SENT];
        if (!allowed.includes(meta.status)) {
            throw new Error(`Cannot start draft. Current: ${meta.status}. Allowed: ${allowed.join(', ')}`);
        }

        txn.update(docRef, {
            status: REQUEST_STATUSES.ADMIN_DRAFT,
            draftOwner: 'ADMIN',
            updatedAt: getCurrentTimestamp()
        });

        return { success: true, currentItems: meta.currentItems || [] };
    });
}

// ============================================================================
// TASK 4.1.5: CLIENT START BARGAIN
// ============================================================================

async function clientStartBargain(requestId) {
    return runTransaction(async (txn) => {
        const docRef = requestsCol().doc(requestId);
        const doc = await txn.get(docRef);
        if (!doc.exists) throw new Error('Request not found');
        const meta = doc.data();

        if (meta.status !== REQUEST_STATUSES.ADMIN_SENT) {
            throw new Error(`Cannot start bargain. Current: ${meta.status}. Must be ${REQUEST_STATUSES.ADMIN_SENT}`);
        }
        if ((meta.panelVersion || 1) >= 4) {
            throw new Error('Bargaining is closed after two rounds.');
        }

        txn.update(docRef, {
            status: REQUEST_STATUSES.CLIENT_DRAFT,
            draftOwner: 'CLIENT',
            updatedAt: getCurrentTimestamp()
        });

        return { success: true, currentItems: meta.currentItems || [] };
    });
}

// ============================================================================
// TASK 4.1.6: SAVE DRAFT PANEL
// ============================================================================

async function saveDraftPanel(requestId, role, panelDraft) {
    return runTransaction(async (txn) => {
        const docRef = requestsCol().doc(requestId);
        const doc = await txn.get(docRef);
        if (!doc.exists) throw new Error('Request not found');
        const meta = doc.data();

        const expectedOwner = role === 'ADMIN' ? 'ADMIN' : 'CLIENT';
        if (meta.draftOwner !== expectedOwner) {
            throw new Error(`Cannot save draft. Owner: ${meta.draftOwner}, expected: ${expectedOwner}`);
        }
        if (!panelDraft.items || !Array.isArray(panelDraft.items)) {
            throw new Error('Panel draft must have items array');
        }

        // BUG 8 fix: Validate against currentItems (which have proper itemIds)
        // requestedItems are raw client-submitted items and may not have itemId fields
        const currentItems = meta.currentItems || [];
        if (panelDraft.items.length !== currentItems.length) {
            throw new Error(
                `Panel items count (${panelDraft.items.length}) must match ` +
                `current items count (${currentItems.length})`
            );
        }

        // Validate itemIds match current items
        const originalItemIds = new Set(
            currentItems.map(item => item.itemId)
        );
        const draftItemIds = new Set(
            panelDraft.items.map(item => item.itemId)
        );

        if (originalItemIds.size !== draftItemIds.size ||
            ![...originalItemIds].every(id => draftItemIds.has(id))) {
            throw new Error('Panel items must have matching itemIds with current items');
        }

        txn.update(docRef, {
            currentItems: panelDraft.items,
            updatedAt: getCurrentTimestamp()
        });

        return { success: true };
    });
}

// ============================================================================
// TASK 4.1.7: SEND PANEL MESSAGE
// ============================================================================

async function sendPanelMessage(requestId, role, username, panelSnapshot, optionalText = null) {
    if (!panelSnapshot.items || !Array.isArray(panelSnapshot.items) || panelSnapshot.items.length === 0) {
        throw new Error('Panel snapshot must have at least one item');
    }

    // Use transaction for atomic read-then-write (BUG 6 fix)
    const result = await runTransaction(async (txn) => {
        const docRef = requestsCol().doc(requestId);
        const doc = await txn.get(docRef);
        if (!doc.exists) throw new Error('Request not found');
        const meta = doc.data();

        // 2-round max enforcement: panelVersion >= 4 means 4 panels sent (2 full rounds)
        if ((meta.panelVersion || 1) >= 4) {
            throw new Error('Bargaining closed after two rounds.');
        }

        if (role === 'ADMIN') {
            const allowed = [REQUEST_STATUSES.ADMIN_DRAFT, REQUEST_STATUSES.CLIENT_SENT];
            if (!allowed.includes(meta.status)) throw new Error(`Cannot send. Status: ${meta.status}`);
        } else if (role === 'CLIENT') {
            const allowed = [REQUEST_STATUSES.CLIENT_DRAFT, REQUEST_STATUSES.ADMIN_SENT];
            if (!allowed.includes(meta.status)) throw new Error(`Cannot send. Status: ${meta.status}`);
            if (meta.clientUsername !== username) throw new Error('Access denied.');
        }

        // Business rule validation
        for (const item of panelSnapshot.items) {
            if (!item.itemId) throw new Error('All items must have itemId');
            if (typeof item.offeredKgs !== 'number' || item.offeredKgs < 0) throw new Error(`Invalid offeredKgs for ${item.itemId}`);
            if (typeof item.unitPrice !== 'number' || item.unitPrice < 0) throw new Error(`Invalid unitPrice for ${item.itemId}`);

            // unitPrice must be > 0 for all non-declined items in ALL rounds
            if (item.status !== SUBORDER_STATUSES.DECLINED && item.unitPrice <= 0) {
                throw new Error(`Unit price must be greater than 0 for ${item.grade}`);
            }

            // Bag/Box multiplier validation
            if (item.status !== SUBORDER_STATUSES.DECLINED && item.offeredKgs > 0) {
                const { DEFAULT_BAG_WEIGHT, DEFAULT_BOX_WEIGHT } = require('../utils/constants');
                if (item.bagbox === 'Bag' && item.offeredKgs % DEFAULT_BAG_WEIGHT !== 0) throw new Error(`${item.grade}: Kgs must be multiple of ${DEFAULT_BAG_WEIGHT} for Bag`);
                if (item.bagbox === 'Box' && item.offeredKgs % DEFAULT_BOX_WEIGHT !== 0) throw new Error(`${item.grade}: Kgs must be multiple of ${DEFAULT_BOX_WEIGHT} for Box`);
            }

            const original = (meta.currentItems || []).find(i => i.itemId === item.itemId);
            const requestedItem = (meta.requestedItems || []).find(i => i.itemId === item.itemId);
            if (role === 'CLIENT' && original) {
                // Client can ONLY modify unitPrice in counter-offer — all other fields must match previous panel
                if (item.offeredKgs !== original.offeredKgs) throw new Error(`Client can only modify rate in counter-offer. Cannot change kgs for ${item.grade}`);
                if (item.offeredNo !== original.offeredNo) throw new Error(`Client can only modify rate in counter-offer. Cannot change quantity for ${item.grade}`);
                if (item.bagbox !== original.bagbox) throw new Error(`Client can only modify rate in counter-offer. Cannot change packaging for ${item.grade}`);
                if (item.grade !== original.grade) throw new Error(`Client can only modify rate in counter-offer. Cannot change grade for ${item.grade}`);
                if (item.brand !== original.brand) throw new Error(`Client can only modify rate in counter-offer. Cannot change brand for ${item.grade}`);
                // BUG 11 fix: Client cannot offer higher than admin's last offer price
                // 'original' is from currentItems which is the admin's last sent offer when status is ADMIN_SENT/CLIENT_DRAFT
                if (original.unitPrice > 0 && item.unitPrice > original.unitPrice) throw new Error(`Client cannot offer price higher than admin's offer for ${item.grade}`);
            } else if (role === 'ADMIN' && meta.panelVersion === 1 && requestedItem) {
                // Round 1: Admin cannot increase bags/boxes beyond what client requested (reduce-only)
                if (item.offeredNo > (requestedItem.no || requestedItem.requestedNo || 0)) {
                    throw new Error(`Admin cannot offer more bags/boxes than requested for ${item.grade}. Requested: ${requestedItem.no || requestedItem.requestedNo || 0}, Offered: ${item.offeredNo}`);
                }
            } else if (role === 'ADMIN' && meta.panelVersion > 1 && original) {
                // BUG 12/13 fix: Admin can only edit Price after Round 1 (keep existing restriction as user intended)
                if (item.offeredKgs !== original.offeredKgs || item.offeredNo !== original.offeredNo || item.bagbox !== original.bagbox || item.grade !== original.grade) {
                    throw new Error('Admin can only edit Price after Round 1.');
                }
            }
        }

        // Atomic update
        const newVersion = meta.panelVersion + 1;
        panelSnapshot.panelVersion = newVersion;
        panelSnapshot.totals = calculatePanelTotals(panelSnapshot.items);

        const updateFields = {
            currentItems: panelSnapshot.items,
            panelVersion: newVersion,
            draftOwner: '',
            status: role === 'ADMIN' ? REQUEST_STATUSES.ADMIN_SENT : REQUEST_STATUSES.CLIENT_SENT,
            updatedAt: getCurrentTimestamp(),
            lastPanelSentAt: getCurrentTimestamp()
        };
        txn.update(docRef, updateFields);

        return { newVersion };
    });

    // Insert messages outside transaction (non-critical)
    await insertPanelMessage({
        requestId,
        senderRole: role === 'ADMIN' ? 'ADMIN' : 'CLIENT',
        senderUsername: username,
        panelSnapshot
    });

    if (optionalText) {
        await insertTextMessage({
            requestId, senderRole: role === 'ADMIN' ? 'ADMIN' : 'CLIENT',
            senderUsername: username, text: optionalText
        });
    }

    const thread = await getChatThread(requestId, role, username);
    return { success: true, panelVersion: result.newVersion, thread };
}

// ============================================================================
// TASK 4.1.8: CANCEL REQUEST
// ============================================================================

async function cancelRequest(requestId, role, reason, username) {
    // Use transaction to prevent TOCTOU race with confirmRequest
    const db = getDb();
    const docRef = requestsCol().doc(requestId);

    const meta = await db.runTransaction(async (transaction) => {
        const snap = await transaction.get(docRef);
        if (!snap.exists) throw new Error('Request not found');
        const data = snap.data();

        const finalized = [REQUEST_STATUSES.CONFIRMED, REQUEST_STATUSES.CONVERTED_TO_ORDER];
        if (finalized.includes(data.status)) throw new Error(`Cannot cancel finalized request (${data.status})`);
        if (role === 'CLIENT' && data.clientUsername !== username) throw new Error('Access denied.');

        transaction.update(docRef, {
            status: REQUEST_STATUSES.CANCELLED,
            cancelReason: reason || '',
            draftOwner: '',
            updatedAt: getCurrentTimestamp()
        });

        return data;
    });

    let cancelerName = role === 'CLIENT' ? (meta.clientName || 'Client') : 'Admin';
    let itemsStr = '';
    if (meta.currentItems && meta.currentItems.length) {
        itemsStr = '\n\nCancelled Items:\n' + meta.currentItems.map(item =>
            `- ${item.grade}: ${item.offeredKgs || item.requestedKgs}kg (${item.offeredNo || item.requestedNo} ${item.bagbox}) @ ₹${item.unitPrice}`
        ).join('\n');
    }

    await insertTextMessage({
        requestId, senderRole: 'SYSTEM', senderUsername: 'system', messageType: 'SYSTEM',
        text: `X Order is cancelled by (${cancelerName})${itemsStr}\n\nReason: ${reason || 'N/A'}`
    });

    // BUG 22 fix: Archive only when an admin offer was actually sent (panelVersion >= 2)
    // panelVersion 1 is the initial client request - no offer has been made yet
    if ((meta.panelVersion || 0) >= 2) {
        try {
            await archiveRejectedOffer(requestId);
        } catch (archiveErr) {
            // Don't block cancellation if archiving fails — log and continue
            console.error(`Failed to archive rejected offer for ${requestId}:`, archiveErr.message);
        }
    }

    return { success: true };
}

// ============================================================================
// TASK 4.1.9: CONFIRM REQUEST
// ============================================================================

async function confirmRequest(requestId, role, username) {
    // Check acceptance window for CLIENT before entering transaction
    if (role === 'CLIENT') {
        const expired = await isAcceptanceExpired(requestId);
        if (expired) {
            throw new Error('Acceptance window has expired (1 hour). Please reinitiate negotiation.');
        }
    }

    return runTransaction(async (txn) => {
        const docRef = requestsCol().doc(requestId);
        const doc = await txn.get(docRef);
        if (!doc.exists) throw new Error('Request not found');
        const meta = doc.data();

        if (role === 'CLIENT') {
            const allowed = [REQUEST_STATUSES.ADMIN_SENT, REQUEST_STATUSES.CLIENT_DRAFT];
            if (!allowed.includes(meta.status)) throw new Error(`Cannot confirm. Status: ${meta.status}`);
            if (meta.clientUsername !== username) throw new Error('Access denied.');
            // Double-check acceptance window inside transaction using stored timestamp
            if (meta.lastPanelSentAt) {
                const elapsed = Date.now() - new Date(meta.lastPanelSentAt).getTime();
                if (elapsed > 3600000) {
                    throw new Error('Acceptance window has expired (1 hour). Please reinitiate negotiation.');
                }
            }
        } else if (role === 'ADMIN') {
            // BUG 9 fix: Admin cannot confirm from OPEN or ADMIN_SENT (skipping negotiation)
            // BUG 10: Admin CAN confirm from ADMIN_DRAFT (user decision: not rectified)
            const allowed = [REQUEST_STATUSES.CLIENT_SENT, REQUEST_STATUSES.ADMIN_DRAFT];
            if (!allowed.includes(meta.status)) throw new Error(`Cannot confirm. Status: ${meta.status}. Admin can only confirm after drafting or client responds.`);
        }

        txn.update(docRef, {
            status: REQUEST_STATUSES.CONFIRMED,
            draftOwner: '',
            finalItems: meta.currentItems,
            updatedAt: getCurrentTimestamp()
        });

        // Return richer response with item details for New Order prefill
        const currentItems = meta.currentItems || [];
        return {
            success: true,
            requestId,
            status: REQUEST_STATUSES.CONFIRMED,
            items: currentItems.map(item => ({
                grade: item.grade,
                type: item.type || 'N/A',
                bagbox: item.bagbox,
                no: item.offeredNo || item.no || item.requestedNo || 0,
                kgs: item.offeredKgs || item.kgs || item.requestedKgs || 0,
                price: item.unitPrice,
                brand: item.brand || '',
                notes: item.notes || item.clientNote || ''
            })),
            clientName: meta.clientName,
            clientUsername: meta.clientUsername
        };
    }).then(async (result) => {
        // Insert system message outside transaction
        const confirmer = role === 'ADMIN' ? 'Admin' : 'Client';
        await insertTextMessage({
            requestId, senderRole: 'SYSTEM', senderUsername: 'system',
            text: `Confirmed by ${confirmer}. Converting to order...`
        });
        return result;
    });
}

// ============================================================================
// TASK 4.1.10: CONVERT CONFIRMED TO ORDER
// ============================================================================

async function convertConfirmedToOrder(requestId, billingFrom, brand, manualOrders = null) {
    const meta = await getRequestMeta(requestId);

    if (meta.status !== REQUEST_STATUSES.CONFIRMED && meta.status !== REQUEST_STATUSES.CONVERTED_TO_ORDER) {
        throw new Error(`Cannot convert. Status: ${meta.status}. Must be ${REQUEST_STATUSES.CONFIRMED}`);
    }

    const orderBook = getOrderBook();
    const stock = getStock();
    const today = formatDate();
    const orders = [];
    const linkedOrderIds = [];

    if (manualOrders && Array.isArray(manualOrders) && manualOrders.length > 0) {
        manualOrders.forEach(o => {
            orders.push({ ...o, client: meta.clientName, orderDate: o.orderDate || today, status: 'Pending' });
            linkedOrderIds.push(o.lot || 'Unknown');
        });
    } else {
        let finalItems = meta.finalItems || [];
        if (!Array.isArray(finalItems) || finalItems.length === 0) {
            finalItems = meta.currentItems || [];
            if (!Array.isArray(finalItems) || finalItems.length === 0) throw new Error('No final items found.');
        }

        const itemsToConvert = finalItems.filter(item => item.status !== SUBORDER_STATUSES.DECLINED);
        if (itemsToConvert.length === 0) throw new Error('All items were declined.');

        // Validate stock availability for all items BEFORE creating orders
        for (const item of itemsToConvert) {
            if ((item.offeredKgs || 0) === 0 && (item.offeredNo || 0) === 0) continue;

            const grade = item.grade || '';
            const requestedKgs = item.offeredKgs || 0;

            // Infer type from grade text (same logic as stock module)
            const gradeNorm = String(grade || '').toLowerCase().replace(/\s+/g, ' ').trim();
            let type = null;
            if (gradeNorm.includes('colour') || gradeNorm.includes('color')) {
                type = 'Colour Bold';
            } else if (gradeNorm.includes('fruit')) {
                type = 'Fruit Bold';
            } else if (gradeNorm.includes('rejection') || gradeNorm.includes('split') || gradeNorm.includes('sick')) {
                type = 'Rejection';
            }

            if (!type) {
                throw new Error(`Cannot determine product type for grade: ${grade}. Grade must contain 'Colour', 'Fruit', or 'Rejection'.`);
            }

            // Validate that sufficient stock exists for this grade
            const validation = await stock.validateStockSufficiency(type, grade, requestedKgs);
            if (!validation.valid) {
                throw new Error(`Insufficient stock: ${validation.message}`);
            }
        }

        // Use transactional lot number generation to prevent duplicate lot numbers
        // when multiple requests are converted concurrently for the same client.
        // Each call to getNextLotNumberTransactional atomically increments the counter.
        for (const item of itemsToConvert) {
            if ((item.offeredKgs || 0) === 0 && (item.offeredNo || 0) === 0) continue;
            const { nextLot: currentLot } = await orderBook.getNextLotNumberTransactional(meta.clientName);
            orders.push({
                orderDate: today, billingFrom, client: meta.clientName, lot: currentLot,
                grade: item.grade || '', bagbox: item.bagbox || '',
                no: item.offeredNo || 0, kgs: item.offeredKgs || 0,
                price: item.unitPrice || 0, brand, status: 'Pending',
                notes: (item.adminNote || item.clientNote || '').substring(0, 500)
            });
            linkedOrderIds.push(currentLot);
        }
    }

    if (orders.length === 0) throw new Error('No items to convert.');

    await orderBook.addOrders(orders);

    // BUG 27 fix: Store linkedOrderIds as array (not comma-separated string)
    await requestsCol().doc(requestId).update({
        status: REQUEST_STATUSES.CONVERTED_TO_ORDER,
        linkedOrderIds: linkedOrderIds,
        updatedAt: getCurrentTimestamp()
    });

    const itemsSummary = orders.map(o =>
        `- ${o.lot}: ${o.grade} - ${o.no} ${o.bagbox} - ${o.kgs} kgs @ ₹${o.price}${o.brand ? ' (' + o.brand + ')' : ''}`
    ).join('\n');

    await insertTextMessage({
        requestId, senderRole: 'SYSTEM', senderUsername: 'system', messageType: 'ORDER_SUMMARY',
        text: `✅ Order Created!\n\nLot Numbers: ${linkedOrderIds.join(', ')}\n\nDetails:\n${itemsSummary}`,
        payload: { orders: orders.map(o => ({ lot: o.lot, grade: o.grade, kgs: o.kgs, price: o.price, brand: o.brand, bagbox: o.bagbox, no: o.no })), linkedOrderIds }
    });

    return { success: true, message: `Created ${orders.length} order(s)`, linkedOrderIds };
}

// ============================================================================
// CANCEL REQUEST ITEM
// ============================================================================

async function cancelRequestItem(requestId, itemIndex, role, reason) {
    return runTransaction(async (txn) => {
        const docRef = requestsCol().doc(requestId);
        const doc = await txn.get(docRef);
        if (!doc.exists) throw new Error('Request not found');
        const meta = doc.data();

        let items = [...(meta.currentItems || [])];
        if (itemIndex < 0 || itemIndex >= items.length) throw new Error('Invalid item index');

        // BUG 7 fix: Set DECLINED status instead of splice to preserve item indices
        const item = { ...items[itemIndex] };
        items[itemIndex] = {
            ...items[itemIndex],
            status: SUBORDER_STATUSES.DECLINED,
            offeredNo: 0,
            offeredKgs: 0,
            unitPrice: 0,
            adminNote: reason || items[itemIndex].adminNote || ''
        };

        txn.update(docRef, {
            currentItems: items,
            status: REQUEST_STATUSES.ADMIN_DRAFT,
            updatedAt: getCurrentTimestamp()
        });

        return { item, items, panelVersion: meta.panelVersion };
    }).then(async ({ item, items, panelVersion }) => {
        const canceler = role === 'ADMIN' ? 'Admin' : 'Client';
        const itemDetails = `${item.grade}: ${item.offeredKgs || item.requestedKgs}kg @ ₹${item.unitPrice}`;

        await insertTextMessage({
            requestId, senderRole: 'SYSTEM', senderUsername: 'system', messageType: 'SYSTEM',
            text: `(Sub-order Declined) ${canceler} declined: ${itemDetails}${reason ? ' | Reason: ' + reason : ''}`
        });

        await insertPanelMessage({
            requestId,
            senderRole: role === 'ADMIN' ? 'ADMIN' : 'CLIENT',
            senderUsername: role === 'ADMIN' ? 'admin' : 'client',
            panelSnapshot: { panelVersion, stage: REQUEST_STATUSES.ADMIN_DRAFT, items }
        });

        return { success: true, currentItems: items };
    });
}

// ============================================================================
// ACCEPTANCE WINDOW TIMEOUT (1 hour)
// ============================================================================

/**
 * Check if the acceptance window has expired for a request.
 * The window is 1 hour from when the last PANEL message was sent.
 */
async function isAcceptanceExpired(requestId) {
    const meta = await getRequestMeta(requestId);
    if (!meta.lastPanelSentAt) return false;
    const elapsed = Date.now() - new Date(meta.lastPanelSentAt).getTime();
    return elapsed > 3600000; // 1 hour in ms
}

// ============================================================================
// REINITIATE NEGOTIATION
// ============================================================================

/**
 * Reinitiate negotiation after acceptance window expires.
 * Only admin can reinitiate, and only when:
 * 1. Current status is ADMIN_SENT
 * 2. Acceptance window has expired
 * 3. No client counter-offer exists for current round (client hasn't responded)
 */
async function reinitiateNegotiation(requestId, role) {
    if (role !== 'ADMIN') {
        throw new Error('Only admin can reinitiate negotiation.');
    }

    const meta = await getRequestMeta(requestId);

    if (meta.status !== REQUEST_STATUSES.ADMIN_SENT) {
        throw new Error(`Cannot reinitiate. Current status: ${meta.status}. Must be ${REQUEST_STATUSES.ADMIN_SENT}`);
    }

    const expired = await isAcceptanceExpired(requestId);
    if (!expired) {
        throw new Error('Acceptance window has not expired yet. Cannot reinitiate.');
    }

    // Check that client hasn't sent a counter-offer for the current round
    // Get all messages to see if client sent a PANEL after the last admin PANEL
    const snapshot = await messagesCol(requestId)
        .orderBy('timestamp', 'desc')
        .limit(5)
        .get();

    const recentMessages = snapshot.docs.map(doc => doc.data());
    // Find the most recent PANEL message
    const lastPanel = recentMessages.find(m => m.messageKind === MESSAGE_KINDS.PANEL);
    if (lastPanel && lastPanel.senderRole === 'CLIENT') {
        throw new Error('Client has already sent a counter-offer. Cannot reinitiate.');
    }

    // BUG 23 fix: Reset panelVersion to allow fresh 2-round negotiation
    await requestsCol().doc(requestId).update({
        status: REQUEST_STATUSES.ADMIN_DRAFT,
        draftOwner: 'ADMIN',
        lastPanelSentAt: null,
        panelVersion: 1,
        updatedAt: getCurrentTimestamp()
    });

    await insertTextMessage({
        requestId,
        senderRole: 'SYSTEM',
        senderUsername: 'system',
        messageType: 'SYSTEM',
        text: 'Negotiation reinitiated. Admin is preparing a new offer.'
    });

    return { success: true, requestId, status: REQUEST_STATUSES.ADMIN_DRAFT };
}

// ============================================================================
// REJECTED OFFERS ANALYTICS
// ============================================================================

/** Get the rejected_offers collection */
function rejectedOffersCol() {
    return getDb().collection('rejected_offers');
}

/**
 * Archive a rejected offer with full details and gap analysis.
 * Called from cancelRequest() when the request has had at least one offer sent.
 */
async function archiveRejectedOffer(requestId) {
    const meta = await getRequestMeta(requestId);

    // Get all messages to find last admin offer and last client counter
    const snapshot = await messagesCol(requestId)
        .orderBy('timestamp', 'desc')
        .get();

    const messages = snapshot.docs.map(doc => doc.data());

    // Find last admin panel and last client panel
    let finalOffer = [];
    let clientLastCounter = [];
    let adminUsername = 'admin';

    for (const msg of messages) {
        if (msg.messageKind === MESSAGE_KINDS.PANEL && msg.senderRole === 'ADMIN' && finalOffer.length === 0) {
            finalOffer = (msg.panelSnapshot && msg.panelSnapshot.items) || [];
            adminUsername = msg.senderUsername || 'admin';
        }
        if (msg.messageKind === MESSAGE_KINDS.PANEL && msg.senderRole === 'CLIENT' && clientLastCounter.length === 0) {
            clientLastCounter = (msg.panelSnapshot && msg.panelSnapshot.items) || [];
        }
        if (finalOffer.length > 0 && clientLastCounter.length > 0) break;
    }

    // Build gap analysis between admin offer and client counter
    const gapItems = [];
    if (finalOffer.length > 0 && clientLastCounter.length > 0) {
        for (const adminItem of finalOffer) {
            const clientItem = clientLastCounter.find(c => c.itemId === adminItem.itemId);
            if (clientItem) {
                gapItems.push({
                    grade: adminItem.grade,
                    adminRate: adminItem.unitPrice || 0,
                    clientRate: clientItem.unitPrice || 0,
                    gap: (adminItem.unitPrice || 0) - (clientItem.unitPrice || 0)
                });
            }
        }
    }

    const archiveDoc = {
        requestId: meta.requestId,
        clientId: meta.clientUsername,
        clientName: meta.clientName,
        requestedItems: meta.requestedItems || [],
        finalOffer,
        clientLastCounter,
        rejectionReason: meta.cancelReason || '',
        adminUsername,
        gapAnalysis: {
            items: gapItems
        },
        createdAt: getCurrentTimestamp()
    };

    await rejectedOffersCol().doc(requestId).set(archiveDoc);
    return { success: true, requestId };
}

/**
 * Query rejected offers with optional filters.
 * @param {Object} filters - { clientId, grade, dateFrom, dateTo, limit }
 */
async function getRejectedOffers(filters = {}) {
    let query = rejectedOffersCol().orderBy('createdAt', 'desc');

    if (filters.clientId) {
        query = query.where('clientId', '==', filters.clientId);
    }

    if (filters.limit) {
        query = query.limit(filters.limit);
    }

    const snapshot = await query.get();
    let results = snapshot.docs.map(doc => doc.data());

    // In-memory filters for fields that Firestore can't compound-query easily
    if (filters.grade) {
        results = results.filter(r =>
            (r.requestedItems || []).some(item => item.grade === filters.grade) ||
            (r.finalOffer || []).some(item => item.grade === filters.grade)
        );
    }
    if (filters.dateFrom) {
        const from = new Date(filters.dateFrom).getTime();
        results = results.filter(r => new Date(r.createdAt).getTime() >= from);
    }
    if (filters.dateTo) {
        const to = new Date(filters.dateTo).getTime();
        results = results.filter(r => new Date(r.createdAt).getTime() <= to);
    }

    return results;
}

/**
 * Aggregate analytics from rejected offers.
 * Returns average gap by client, by grade, rejection count, and monthly trends.
 * @param {Object} filters - { dateFrom, dateTo }
 */
async function getRejectedOffersAnalytics(filters = {}) {
    const offers = await getRejectedOffers(filters);

    // Average gap by client
    const gapByClient = {};
    const gapByGrade = {};
    let totalGap = 0;
    let gapCount = 0;

    // Monthly trends
    const monthlyData = {};

    for (const offer of offers) {
        const items = (offer.gapAnalysis && offer.gapAnalysis.items) || [];
        const month = offer.createdAt ? offer.createdAt.substring(0, 7) : 'unknown'; // YYYY-MM

        if (!monthlyData[month]) {
            monthlyData[month] = { count: 0, totalGap: 0, gapItemCount: 0 };
        }
        monthlyData[month].count++;

        for (const gi of items) {
            const absGap = Math.abs(gi.gap || 0);

            // By client
            if (!gapByClient[offer.clientName]) {
                gapByClient[offer.clientName] = { totalGap: 0, count: 0 };
            }
            gapByClient[offer.clientName].totalGap += absGap;
            gapByClient[offer.clientName].count++;

            // By grade
            if (!gapByGrade[gi.grade]) {
                gapByGrade[gi.grade] = { totalGap: 0, count: 0 };
            }
            gapByGrade[gi.grade].totalGap += absGap;
            gapByGrade[gi.grade].count++;

            totalGap += absGap;
            gapCount++;

            monthlyData[month].totalGap += absGap;
            monthlyData[month].gapItemCount++;
        }
    }

    // Build averages
    const avgGapByClient = {};
    for (const [name, data] of Object.entries(gapByClient)) {
        avgGapByClient[name] = data.count > 0 ? Math.round((data.totalGap / data.count) * 100) / 100 : 0;
    }

    const avgGapByGrade = {};
    for (const [grade, data] of Object.entries(gapByGrade)) {
        avgGapByGrade[grade] = data.count > 0 ? Math.round((data.totalGap / data.count) * 100) / 100 : 0;
    }

    const trendByMonth = Object.entries(monthlyData)
        .map(([month, data]) => ({
            month,
            count: data.count,
            avgGap: data.gapItemCount > 0 ? Math.round((data.totalGap / data.gapItemCount) * 100) / 100 : 0
        }))
        .sort((a, b) => a.month.localeCompare(b.month));

    return {
        avgGapByClient,
        avgGapByGrade,
        rejectionCount: offers.length,
        trendByMonth
    };
}

// ============================================================================
// LEGACY COMPATIBILITY FUNCTIONS
// ============================================================================

async function createRequest({ clientUsername, clientName, requestType, items, initialMessage }) {
    return createClientRequest({ clientUsername, clientName, requestType, items, initialText: initialMessage });
}

async function getRequestsForClient(clientUsername) {
    const snapshot = await requestsCol()
        .where('clientUsername', '==', clientUsername)
        .orderBy('updatedAt', 'desc')
        .get();

    return snapshot.docs.map(doc => {
        const d = doc.data();
        return {
            requestId: d.requestId, clientUsername: d.clientUsername, clientName: d.clientName,
            requestType: d.requestType, status: d.status, createdAt: d.createdAt, updatedAt: d.updatedAt,
            requestedItems: d.requestedItems || [],
            agreedItems: d.currentItems || [],
            linkedOrderIds: d.linkedOrderIds || '',
            notes: d.cancelReason || ''
        };
    });
}

async function getRequestsForAdmin(filters = {}) {
    let query = requestsCol().orderBy('updatedAt', 'desc');
    // Note: Firestore doesn't support multiple inequality filters easily.
    // For admin filtering, we fetch all and filter in memory (same as Sheets version did).
    const snapshot = await query.get();

    let results = snapshot.docs.map(doc => {
        const d = doc.data();
        return {
            requestId: d.requestId, clientUsername: d.clientUsername, clientName: d.clientName,
            requestType: d.requestType, status: d.status, createdAt: d.createdAt, updatedAt: d.updatedAt,
            requestedItems: d.requestedItems || [],
            agreedItems: d.currentItems || [],
            linkedOrderIds: d.linkedOrderIds || '',
            notes: d.cancelReason || ''
        };
    });

    if (filters.status) results = results.filter(r => r.status.toUpperCase() === filters.status.toUpperCase());
    if (filters.clientUsername) results = results.filter(r => r.clientUsername === filters.clientUsername);
    if (filters.type) results = results.filter(r => r.requestType.toUpperCase() === filters.type.toUpperCase());
    if (filters.client) results = results.filter(r => r.clientName.toLowerCase().includes(filters.client.toLowerCase()));

    return results;
}

/** Docmap for client request list responses */
function docToRequestSummary(doc) {
    const d = doc.data();
    return {
        requestId: d.requestId, clientUsername: d.clientUsername, clientName: d.clientName,
        requestType: d.requestType, status: d.status, createdAt: d.createdAt, updatedAt: d.updatedAt,
        requestedItems: d.requestedItems || [],
        agreedItems: d.currentItems || [],
        linkedOrderIds: d.linkedOrderIds || '',
        notes: d.cancelReason || ''
    };
}

/**
 * Get paginated client requests for admin with optional filters.
 * Uses cursor-based pagination on updatedAt descending.
 */
async function getRequestsForAdminPaginated({ limit = 25, cursor = null, filters = {} } = {}) {
    limit = Math.max(1, Math.min(limit, 100));

    // Build Firestore query with status filter if possible (single equality is supported)
    let query = requestsCol();
    if (filters.status) {
        query = query.where('status', '==', filters.status.toUpperCase());
    }
    query = query.orderBy('updatedAt', 'desc').limit(limit + 1);

    if (cursor) {
        try {
            const cursorDoc = await requestsCol().doc(cursor).get();
            if (cursorDoc.exists) {
                let q2 = requestsCol();
                if (filters.status) {
                    q2 = q2.where('status', '==', filters.status.toUpperCase());
                }
                query = q2.orderBy('updatedAt', 'desc').startAfter(cursorDoc).limit(limit + 1);
            }
        } catch (e) { /* ignore */ }
    }

    const snapshot = await query.get();
    let results = snapshot.docs.slice(0, limit).map(docToRequestSummary);
    const hasMore = snapshot.docs.length > limit;

    // Client-side filters for fields Firestore can't compound query on
    if (filters.clientUsername) results = results.filter(r => r.clientUsername === filters.clientUsername);
    if (filters.type) results = results.filter(r => r.requestType.toUpperCase() === filters.type.toUpperCase());
    if (filters.client) results = results.filter(r => r.clientName.toLowerCase().includes(filters.client.toLowerCase()));

    const lastDoc = snapshot.docs.length > 0 ? snapshot.docs[Math.min(snapshot.docs.length - 1, limit - 1)] : null;

    return {
        data: results,
        pagination: {
            cursor: hasMore && lastDoc ? lastDoc.id : null,
            hasMore,
            limit
        }
    };
}

/**
 * Get paginated requests for a specific client.
 */
async function getRequestsForClientPaginated(clientUsername, { limit = 25, cursor = null } = {}) {
    limit = Math.max(1, Math.min(limit, 100));

    let query = requestsCol()
        .where('clientUsername', '==', clientUsername)
        .orderBy('updatedAt', 'desc')
        .limit(limit + 1);

    if (cursor) {
        try {
            const cursorDoc = await requestsCol().doc(cursor).get();
            if (cursorDoc.exists) {
                query = requestsCol()
                    .where('clientUsername', '==', clientUsername)
                    .orderBy('updatedAt', 'desc')
                    .startAfter(cursorDoc)
                    .limit(limit + 1);
            }
        } catch (e) { /* ignore */ }
    }

    const snapshot = await query.get();
    const docs = snapshot.docs.slice(0, limit);
    const hasMore = snapshot.docs.length > limit;

    return {
        data: docs.map(docToRequestSummary),
        pagination: {
            cursor: hasMore ? docs[docs.length - 1].id : null,
            hasMore,
            limit
        }
    };
}

async function getChatThreadLegacy(requestId) {
    return getChatThread(requestId, 'ADMIN', 'system');
}

async function appendChatMessage({ requestId, senderRole, senderUsername, messageType, message, payload }) {
    if (messageType === 'PANEL' && payload) {
        await insertPanelMessage({ requestId, senderRole, senderUsername, panelSnapshot: payload });
    } else {
        await insertTextMessage({ requestId, senderRole, senderUsername, text: message });
    }
    return { success: true };
}

async function updateRequestStatus(requestId, newStatus) {
    await requestsCol().doc(requestId).update({ status: newStatus, updatedAt: getCurrentTimestamp() });
    return { success: true };
}

async function saveAgreedItems(requestId, agreedItems) {
    await requestsCol().doc(requestId).update({ currentItems: agreedItems, updatedAt: getCurrentTimestamp() });
    return { success: true };
}

// ============================================================================
// EXPORTS (same surface as ../clientRequests.js)
// ============================================================================

module.exports = {
    createClientRequest, getChatThread, getRequestMeta,
    adminStartDraft, clientStartBargain, saveDraftPanel, sendPanelMessage,
    cancelRequest, confirmRequest, convertConfirmedToOrder,
    REQUEST_STATUSES, SUBORDER_STATUSES, MESSAGE_KINDS,
    invalidateRequestCache,
    createRequest, getRequestsForClient, getRequestsForAdmin,
    getRequestsForAdminPaginated, getRequestsForClientPaginated,
    getChatThreadLegacy, appendChatMessage, updateRequestStatus, saveAgreedItems,
    ensureSheetsInitialized, batchUpdateRequestFields,
    cancelRequestItem,

    // Internal functions exposed for unit testing only
    _test: {
        generateRequestId,
        generateMessageId,
        getCurrentTimestamp,
        validatePanelSnapshot,
        createInitialPanelSnapshot,
    },
    // Stream 1A: Negotiation Backend Engine additions
    isAcceptanceExpired,
    reinitiateNegotiation,
    archiveRejectedOffer,
    getRejectedOffers,
    getRejectedOffersAnalytics
};
