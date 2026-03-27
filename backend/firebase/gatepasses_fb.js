/**
 * Gate Passes Module — Firebase Firestore Backend
 * Drop-in replacement for ../gatepasses.js (includes Express router)
 */
const { Router } = require('express');
const { getDb } = require('../../src/backend/database/sqliteClient');

const router = Router();
const COL = 'gate_passes';
function col() { return getDb().collection(COL); }

let passSequence = 0;

async function generatePassNumber() {
    const db = getDb();
    const currentYear = new Date().getFullYear();
    // Use year-specific counter so sequence resets at year boundary
    const counterRef = db.collection('counters').doc(`gate_pass_sequence_${currentYear}`);

    const newSeq = await db.runTransaction(async (transaction) => {
        const doc = await transaction.get(counterRef);
        const current = doc.exists ? (doc.data().sequence || 0) : 0;
        const next = current + 1;
        transaction.set(counterRef, { sequence: next, year: currentYear });
        return next;
    });

    passSequence = newSeq;
    return `GP-${currentYear}-${String(newSeq).padStart(4, '0')}`;
}

async function initGatePassesSheet() {
    // No-op: sequence is now managed via year-specific counter docs in Firestore.
    // The old full-collection scan is no longer needed (saves 2-5s on startup).
    console.log('[GatePasses-FB] Using Firestore counter docs for sequence management');
}

function docToPass(doc) {
    return { ...doc.data(), _docId: doc.id };
}

function calculateReminderDates(expectedReturn) {
    if (!expectedReturn) return [];
    const returnDate = new Date(expectedReturn);
    if (isNaN(returnDate.getTime())) return [];
    const reminders = [];
    // Same day
    reminders.push(returnDate.toISOString().split('T')[0]);
    // 1 day before
    const oneDayBefore = new Date(returnDate);
    oneDayBefore.setDate(oneDayBefore.getDate() - 1);
    reminders.push(oneDayBefore.toISOString().split('T')[0]);
    // 2 days before
    const twoDaysBefore = new Date(returnDate);
    twoDaysBefore.setDate(twoDaysBefore.getDate() - 2);
    reminders.push(twoDaysBefore.toISOString().split('T')[0]);
    return reminders;
}

async function createGatePass(data) {
    // Server-side validation — reject gate passes with empty required fields
    if (!data.vehicleNumber || !String(data.vehicleNumber).trim()) {
        return { success: false, error: 'Vehicle number is required' };
    }
    if (!data.purpose || !String(data.purpose).trim()) {
        return { success: false, error: 'Purpose is required' };
    }
    const _bagCount = Number(data.bagCount) || 0;
    const _boxCount = Number(data.boxCount) || 0;
    if (_bagCount <= 0 && _boxCount <= 0) {
        return { success: false, error: 'At least one bag or box is required' };
    }

    const id = `GP-${Date.now()}`;
    const now = new Date().toISOString();
    const reminderDates = calculateReminderDates(data.expectedReturn);
    const bagCount = Number(data.bagCount) || 0;
    const boxCount = Number(data.boxCount) || 0;
    const { DEFAULT_BAG_WEIGHT, DEFAULT_BOX_WEIGHT } = require('../utils/constants');
    const bagWeight = Number(data.bagWeight) || DEFAULT_BAG_WEIGHT;
    const boxWeight = Number(data.boxWeight) || DEFAULT_BOX_WEIGHT;
    const calculatedWeight = (bagCount * bagWeight) + (boxCount * boxWeight);
    const actualWeight = Number(data.actualWeight) || calculatedWeight;
    const finalWeight = Number(data.finalWeight) || actualWeight || calculatedWeight;
    const pass = {
        id, passNumber: await generatePassNumber(),
        type: data.type || 'exit', packaging: data.packaging || '',
        bagCount, boxCount,
        bagWeight, boxWeight,
        calculatedWeight,
        actualWeight,
        finalWeight,
        purpose: data.purpose || '', notes: data.notes || '',
        vehicleNumber: data.vehicleNumber || '', driverName: data.driverName || '', driverPhone: data.driverPhone || '',
        expectedReturn: data.expectedReturn || '',
        reminderDates,
        status: 'pending', requestedBy: data.requestedBy || '', requestedAt: now,
        approvedBy: '', approvedAt: '', signatureData: '', rejectionReason: '',
        actualEntryTime: '', actualExitTime: '', isCompleted: false, completedBy: '',
        updatedAt: now
    };
    await col().doc(id).set(pass);
    return pass;
}

async function getGatePasses(filters = {}) {
    let snap = await col().orderBy('requestedAt', 'desc').get();
    let passes = snap.docs.map(docToPass);
    if (filters.status) passes = passes.filter(p => p.status === filters.status);
    if (filters.type) passes = passes.filter(p => p.type === filters.type);
    if (filters.requestedBy) passes = passes.filter(p => p.requestedBy === filters.requestedBy);
    return passes;
}

/**
 * Get gate passes with cursor-based pagination and optional filters.
 */
async function getGatePassesPaginated({ limit = 25, cursor = null, filters = {} } = {}) {
    limit = Math.max(1, Math.min(limit, 100));

    // Apply ALL filters at Firestore level where possible
    let query = col();
    if (filters.status) query = query.where('status', '==', filters.status);
    if (filters.type) query = query.where('type', '==', filters.type);
    if (filters.requestedBy) query = query.where('requestedBy', '==', filters.requestedBy);
    query = query.orderBy('requestedAt', 'desc').limit(limit + 1);

    if (cursor) {
        try {
            const cursorDoc = await col().doc(cursor).get();
            if (cursorDoc.exists) {
                let q2 = col();
                if (filters.status) q2 = q2.where('status', '==', filters.status);
                if (filters.type) q2 = q2.where('type', '==', filters.type);
                if (filters.requestedBy) q2 = q2.where('requestedBy', '==', filters.requestedBy);
                query = q2.orderBy('requestedAt', 'desc').startAfter(cursorDoc).limit(limit + 1);
            }
        } catch (e) { /* ignore */ }
    }

    const snap = await query.get();
    const allDocs = snap.docs.map(docToPass);

    const passes = allDocs.slice(0, limit);
    const hasMore = allDocs.length > limit;

    const lastDoc = snap.docs.length > 0 ? snap.docs[Math.min(snap.docs.length - 1, limit - 1)] : null;

    return {
        data: passes,
        pagination: {
            cursor: hasMore && lastDoc ? lastDoc.id : null,
            hasMore,
            limit
        }
    };
}

async function getGatePassById(id) {
    const doc = await col().doc(id).get();
    return doc.exists ? docToPass(doc) : null;
}

async function getPendingPasses() {
    const snap = await col().where('status', '==', 'pending').get();
    return snap.docs.map(docToPass);
}

async function updateGatePass(id, data) {
    const ref = col().doc(id);
    const snap = await ref.get();
    if (!snap.exists) throw new Error('Gate pass not found');
    if (snap.data().status !== 'pending') throw new Error('Can only edit pending passes');
    const allowedFields = ['vehicleNumber', 'driverName', 'driverPhone', 'purpose', 'notes', 'bagCount', 'boxCount', 'bagWeight', 'boxWeight', 'calculatedWeight', 'actualWeight', 'finalWeight', 'expectedReturn', 'packaging', 'type'];
    const safeData = {};
    for (const key of allowedFields) {
        if (data[key] !== undefined) safeData[key] = data[key];
    }
    await ref.update({ ...safeData, updatedAt: new Date().toISOString() });
    return { ...snap.data(), ...safeData };
}

async function approveGatePass(id, approvedBy, signatureData) {
    const snap = await col().doc(id).get();
    if (!snap.exists) throw new Error('Gate pass not found');
    if (snap.data().status !== 'pending') throw new Error('Can only approve pending gate passes');
    const updateData = { status: 'approved', approvedBy, approvedAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    // Signature is optional — only store if provided
    if (signatureData) updateData.signatureData = signatureData;
    await col().doc(id).update(updateData);
    return await getGatePassById(id);
}

async function rejectGatePass(id, rejectedBy, reason) {
    const snap = await col().doc(id).get();
    if (!snap.exists) throw new Error('Gate pass not found');
    if (snap.data().status !== 'pending') throw new Error('Can only reject pending gate passes');
    await col().doc(id).update({ status: 'rejected', rejectionReason: reason || '', updatedAt: new Date().toISOString() });
    return await getGatePassById(id);
}

async function recordEntry(id, recordedBy) {
    const snap = await col().doc(id).get();
    if (!snap.exists) throw new Error('Gate pass not found');
    if (snap.data().status !== 'approved') throw new Error('Can only record entry on approved gate passes');
    await col().doc(id).update({ actualEntryTime: new Date().toISOString(), updatedAt: new Date().toISOString() });
    return await getGatePassById(id);
}

async function recordExit(id, recordedBy) {
    const ref = col().doc(id);
    const snap = await ref.get();
    if (!snap.exists) throw new Error('Gate pass not found');

    const pass = snap.data();
    if (!pass.actualEntryTime) {
        throw new Error('Entry must be recorded before exit can be recorded');
    }

    await ref.update({ actualExitTime: new Date().toISOString(), updatedAt: new Date().toISOString() });
    return await getGatePassById(id);
}

async function completePass(id, completedBy) {
    const snap = await col().doc(id).get();
    if (!snap.exists) throw new Error('Gate pass not found');
    const status = snap.data().status;
    if (status !== 'approved') throw new Error('Can only complete approved gate passes');
    await col().doc(id).update({ status: 'completed', isCompleted: true, completedBy, updatedAt: new Date().toISOString() });
    return await getGatePassById(id);
}

// ========== Express Routes ==========
router.get('/', async (req, res) => {
    try {
        const f = {};
        if (req.query.status) f.status = req.query.status;
        if (req.query.type) f.type = req.query.type;
        if (req.query.requestedBy) f.requestedBy = req.query.requestedBy;

        // Use paginated query when limit or cursor is provided
        const featureFlags = require('../featureFlags');
        if (featureFlags.usePagination()) {
            const limit = Math.max(1, Math.min(parseInt(req.query.limit) || 25, 100));
            const cursor = req.query.cursor || null;
            const result = await getGatePassesPaginated({ limit, cursor, filters: f });
            return res.json(result);
        }
        res.json(await getGatePasses(f));
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});
router.get('/pending', async (req, res) => {
    try { res.json(await getPendingPasses()); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.get('/reminders/upcoming', async (req, res) => {
    try { res.json(await getUpcomingReminders()); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.get('/:id', async (req, res) => {
    try { const p = await getGatePassById(req.params.id); if (!p) return res.status(404).json({ error: 'Not found' }); res.json(p); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/', async (req, res) => {
    try { res.status(201).json(await createGatePass(req.body)); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.put('/:id', async (req, res) => {
    try {
        const userRole = (req.user?.role || '').toLowerCase();
        if (userRole === 'guard' || userRole === 'security') {
            return res.status(403).json({ error: 'Guards can only record entry/exit times' });
        }
        res.json(await updateGatePass(req.params.id, req.body));
    } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/:id/approve', async (req, res) => {
    try {
        const userRole = (req.user?.role || '').toLowerCase();
        if (!['admin', 'superadmin', 'ops', 'supervisor'].includes(userRole)) {
            return res.status(403).json({ error: 'Only admin or supervisor can approve gate passes' });
        }
        const approvedBy = (req.user && req.user.username) || req.body.approvedBy || 'unknown';
        res.json(await approveGatePass(req.params.id, approvedBy, req.body.signatureData || null));
    } catch (e) {
        console.error(`[GatePasses] Approve error for ${req.params.id}:`, e.message);
        res.status(500).json({ error: e.message });
    }
});
router.post('/:id/reject', async (req, res) => {
    try {
        const rejectedBy = (req.user && req.user.username) || 'unknown';
        res.json(await rejectGatePass(req.params.id, rejectedBy, req.body.reason));
    } catch (e) {
        console.error(`[GatePasses] Reject error for ${req.params.id}:`, e.message);
        res.status(500).json({ error: e.message });
    }
});
router.post('/:id/record-entry', async (req, res) => {
    try { res.json(await recordEntry(req.params.id, (req.user && req.user.username) || 'system')); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/:id/record-exit', async (req, res) => {
    try { res.json(await recordExit(req.params.id, (req.user && req.user.username) || 'system')); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/:id/complete', async (req, res) => {
    try { res.json(await completePass(req.params.id, (req.user && req.user.username) || 'unknown')); } catch (e) { res.status(500).json({ error: e.message }); }
});

function getReminderType(today, expectedReturn) {
    const diff = Math.ceil((new Date(expectedReturn) - new Date(today)) / (1000 * 60 * 60 * 24));
    if (diff === 0) return 'same_day';
    if (diff === 1) return '1_day_before';
    if (diff === 2) return '2_days_before';
    return 'other';
}

async function getUpcomingReminders() {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const todayStr = today.toISOString().split('T')[0];

    // Query gate passes that are still active (approved or entry_recorded)
    const snapshot = await col()
        .where('status', 'in', ['approved', 'entry_recorded'])
        .get();

    const reminders = [];
    snapshot.forEach(doc => {
        const data = doc.data();
        if (data.reminderDates && data.reminderDates.includes(todayStr)) {
            reminders.push({
                passId: doc.id,
                passNumber: data.passNumber,
                workerName: data.requestedBy,
                purpose: data.purpose,
                expectedReturn: data.expectedReturn,
                reminderType: getReminderType(todayStr, data.expectedReturn)
            });
        }
    });
    return reminders;
}

module.exports = { router, initGatePassesSheet, createGatePass, getGatePasses, getGatePassesPaginated, getGatePassById, getUpcomingReminders };
