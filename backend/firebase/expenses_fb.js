/**
 * Expenses Module — Firebase Firestore Backend
 * Drop-in replacement for ../expenses.js (includes Express router)
 */
const { Router } = require('express');
const { getDb } = require('../firebaseClient');

const router = Router();
const EXPENSES_COL = 'expenses';
const ITEMS_COL = 'expense_items';

function expensesCol() { return getDb().collection(EXPENSES_COL); }
function itemsCol() { return getDb().collection(ITEMS_COL); }

const EXPENSE_CATEGORIES = [
    { name: 'worker_wages', type: 'fixed', requiresQuantity: false },
    { name: 'stitching', type: 'variable', requiresQuantity: true },
    { name: 'loading', type: 'variable', requiresQuantity: false, hasSubCategory: true },
    { name: 'transport', type: 'variable', requiresQuantity: false },
    { name: 'fuel', type: 'variable', requiresQuantity: false },
    { name: 'maintenance', type: 'variable', requiresQuantity: false },
    { name: 'misc', type: 'misc', requiresQuantity: false, requiresNote: true },
];

async function initExpenseSheets() {
    console.log('[Expenses-FB] Firestore collection ready (no init needed)');
}

async function getExpenseSheet(date) {
    const snap = await expensesCol().where('date', '==', date).limit(1).get();
    if (snap.empty) return null;
    const sheet = snap.docs[0].data();
    // Get items
    const itemSnap = await itemsCol().where('sheetId', '==', sheet.id).get();
    sheet.items = itemSnap.docs.map(doc => doc.data());
    return sheet;
}

async function saveExpenseSheet(date, items, submittedBy) {
    const existing = await getExpenseSheet(date);
    // Prevent editing approved or completed expense sheets
    if (existing && (existing.status === 'approved' || existing.status === 'completed')) {
        return { success: false, error: 'Cannot edit approved expense sheet' };
    }
    const id = existing?.id || `EXP-${Date.now()}`;
    const now = new Date().toISOString();

    let workerWages = 0, totalVariable = 0, totalMisc = 0;
    (items || []).forEach(item => {
        const amt = parseFloat(item.amount) || 0;
        if (item.category === 'worker_wages') workerWages += amt;
        else if (item.category === 'misc') totalMisc += amt;
        else totalVariable += amt;
    });

    const sheet = {
        id, date, workerWages, totalVariable, totalMisc,
        grandTotal: workerWages + totalVariable + totalMisc,
        status: existing?.status || 'draft',
        submittedBy: submittedBy || existing?.submittedBy || '',
        submittedAt: existing?.submittedAt || '',
        approvedBy: existing?.approvedBy || '', approvedAt: existing?.approvedAt || '', rejectionReason: existing?.rejectionReason || '',
        createdAt: existing?.createdAt || now, updatedAt: now
    };

    await expensesCol().doc(id).set(sheet, { merge: true });

    // Delete old items and write new
    const oldItems = await itemsCol().where('sheetId', '==', id).get();
    const batch = getDb().batch();
    oldItems.docs.forEach(doc => batch.delete(doc.ref));
    (items || []).forEach(item => {
        const itemId = `${id}-${Date.now()}-${Math.random().toString(36).substr(2, 5)}`;
        batch.set(itemsCol().doc(itemId), { id: itemId, sheetId: id, ...item, createdAt: now });
    });
    await batch.commit();

    return { success: true, sheet: { ...sheet, items } };
}

async function submitExpenseSheet(id, submittedBy, userRole) {
    const docRef = expensesCol().doc(id);
    const snap = await docRef.get();
    if (!snap.exists) return { success: false, error: 'Not found' };
    const isAdmin = userRole === 'admin' || userRole === 'ops';
    const newStatus = isAdmin ? 'approved' : 'pending';
    await docRef.update({ status: newStatus, submittedBy, submittedAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
    return { success: true, status: newStatus };
}

async function approveExpenseSheet(id, approvedBy) {
    const docRef = expensesCol().doc(id);
    const snap = await docRef.get();
    if (!snap.exists) return { success: false, error: 'Expense sheet not found' };
    const currentStatus = snap.data().status;
    if (currentStatus !== 'pending') {
        return { success: false, error: `Can only approve pending expense sheets (current: ${currentStatus})` };
    }
    await docRef.update({ status: 'approved', approvedBy, approvedAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
    return { success: true };
}

async function rejectExpenseSheet(id, rejectedBy, reason) {
    const docRef = expensesCol().doc(id);
    const snap = await docRef.get();
    if (!snap.exists) return { success: false, error: 'Expense sheet not found' };
    const currentStatus = snap.data().status;
    if (currentStatus !== 'pending') {
        return { success: false, error: `Can only reject pending expense sheets (current: ${currentStatus})` };
    }
    await docRef.update({ status: 'rejected', rejectedBy, rejectionReason: reason, updatedAt: new Date().toISOString() });
    return { success: true };
}

async function withdrawExpenseSheet(id, withdrawnBy) {
    const docRef = expensesCol().doc(id);
    const snap = await docRef.get();
    if (!snap.exists) return { success: false, error: 'Not found' };
    // #64: Allow withdrawal from 'approved' or 'pending' status only (not rejected/draft)
    const currentStatus = snap.data().status;
    if (currentStatus !== 'approved' && currentStatus !== 'pending') {
        return { success: false, error: `Can only withdraw approved or pending expense sheets (current: ${currentStatus})` };
    }
    await docRef.update({ status: 'draft', withdrawnBy, withdrawnAt: new Date().toISOString(), submittedBy: '', submittedAt: '', updatedAt: new Date().toISOString() });
    return { success: true };
}

async function getExpenseCalendar(year, month) {
    // #60: Use date range query instead of full collection scan
    const prefix = `${year}-${String(month).padStart(2, '0')}`;
    const startDate = `${prefix}-01`;
    const endDate = `${prefix}-32`; // Safe upper bound — no month has 32 days
    const snap = await expensesCol()
        .where('date', '>=', startDate)
        .where('date', '<=', endDate)
        .get();
    const calendar = {};
    snap.docs.forEach(doc => {
        const d = doc.data();
        if (d.date) {
            calendar[d.date] = { date: d.date, grandTotal: d.grandTotal || 0, status: d.status || 'draft' };
        }
    });
    return calendar;
}

async function getPendingExpenses() {
    const snap = await expensesCol().where('status', '==', 'pending').get();
    return snap.docs.map(doc => doc.data());
}

// ========== Express Routes ==========
router.get('/pending/all', async (req, res) => {
    try { res.json(await getPendingExpenses()); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.get('/calendar/:year/:month', async (req, res) => {
    try { res.json(await getExpenseCalendar(parseInt(req.params.year), parseInt(req.params.month))); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.get('/:date', async (req, res) => {
    try {
        let sheet = await getExpenseSheet(req.params.date);
        if (!sheet) sheet = { id: null, date: req.params.date, items: [], status: 'draft', grandTotal: 0 };
        res.json(sheet);
    } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/', async (req, res) => {
    try {
        const { date, items, submittedBy } = req.body;
        if (!date) return res.status(400).json({ error: 'Date is required' });
        res.json(await saveExpenseSheet(date, items, submittedBy));
    } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/:id/submit', async (req, res) => {
    try { res.json(await submitExpenseSheet(req.params.id, req.body.submittedBy, (req.user?.role || ''))); } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/:id/approve', async (req, res) => {
    try {
        const userRole = (req.user?.role || '').toLowerCase();
        if (!['admin', 'superadmin', 'ops'].includes(userRole)) {
            return res.status(403).json({ success: false, error: 'Only admin can approve expenses' });
        }
        res.json(await approveExpenseSheet(req.params.id, req.body.approvedBy));
    } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/:id/reject', async (req, res) => {
    try {
        const userRole = (req.user?.role || '').toLowerCase();
        if (!['admin', 'superadmin', 'ops'].includes(userRole)) {
            return res.status(403).json({ success: false, error: 'Only admin can reject expenses' });
        }
        res.json(await rejectExpenseSheet(req.params.id, req.body.rejectedBy, req.body.reason));
    } catch (e) { res.status(500).json({ error: e.message }); }
});
router.post('/:id/withdraw', async (req, res) => {
    try { res.json(await withdrawExpenseSheet(req.params.id, (req.user && req.user.username) || 'unknown')); } catch (e) { res.status(500).json({ error: e.message }); }
});

module.exports = { router, initExpenseSheets, getExpenseSheet, saveExpenseSheet, EXPENSE_CATEGORIES };
