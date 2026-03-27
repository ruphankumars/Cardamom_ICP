/**
 * Notifications Routes — Get, Mark Read, Poll
 *
 * Uses sqliteClient instead of firebaseClient for ICP compatibility.
 */
const router = require('express').Router();
const { getDb } = require('../database/sqliteClient');

// GET /api/notifications — get unread notifications
router.get('/', async (req, res) => {
    try {
        const db = getDb();
        const snap = await db.collection('notifications')
            .where('read', '==', false)
            .orderBy('createdAt', 'desc')
            .limit(50)
            .get();
        const notifications = snap.docs.map(d => d.data());
        res.json({ success: true, notifications });
    } catch (err) {
        console.error('[Notifications] GET error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/notifications/mark-read — mark notifications as read
router.post('/mark-read', async (req, res) => {
    try {
        const db = getDb();
        let query = db.collection('notifications').where('read', '==', false);
        if (req.user && req.user.id) {
            query = query.where('userId', '==', req.user.id);
        }
        const snap = await query.get();
        if (snap.empty) {
            return res.json({ success: true, count: 0 });
        }
        const batch = db.batch();
        snap.docs.forEach(doc => batch.update(doc.ref, { read: true }));
        await batch.commit();
        res.json({ success: true, count: snap.size });
    } catch (err) {
        console.error('[Notifications] mark-read error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /api/notifications/poll — poll for new notifications (replaces Socket.IO)
router.get('/poll', async (req, res) => {
    try {
        const since = req.query.since || new Date(0).toISOString();
        const db = getDb();
        const snap = await db.collection('notifications')
            .where('read', '==', false)
            .where('createdAt', '>', since)
            .orderBy('createdAt', 'desc')
            .limit(50)
            .get();
        const notifications = snap.docs.map(d => d.data());
        res.json({ success: true, notifications, serverTime: new Date().toISOString() });
    } catch (err) {
        console.error('[Notifications] poll error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
