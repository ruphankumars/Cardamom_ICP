const router = require('express').Router();
const users = require('../../../backend/firebase/users_fb');
const { requireAdmin, requireSuperAdmin } = require('../../../backend/middleware/auth');

// ====== USER FACE LOGIN ROUTES (must be before /:id) ======

// NOTE: This route is PUBLIC (no auth). Since authenticateToken is applied at mount time
// for the entire /api/users prefix, this route needs auth exemption in index.ts.
// It should be mounted BEFORE the authenticated /api/users router, e.g.:
//   app.get('/api/users/face-data/all', faceDataAllHandler);
router.get('/face-data/all', async (req, res) => {
    try {
        const data = await users.getAllUserFaceData();
        res.json(data);
    } catch (err) {
        console.error('[FaceLogin] Get all user face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Store face data for current user (requires auth)
router.post('/me/face-data', async (req, res) => {
    try {
        const { faceData } = req.body;
        if (!faceData) return res.status(400).json({ success: false, error: 'faceData is required' });
        const userId = req.user.id || req.user.userId;
        const result = await users.storeUserFaceData(userId, faceData);
        res.json(result);
    } catch (err) {
        console.error('[FaceLogin] Store user face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get face data for current user (requires auth)
router.get('/me/face-data', async (req, res) => {
    try {
        const userId = req.user.id || req.user.userId;
        const data = await users.getUserFaceData(userId);
        res.json({ faceData: data });
    } catch (err) {
        console.error('[FaceLogin] Get user face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete face data for current user (requires auth)
router.delete('/me/face-data', async (req, res) => {
    try {
        const userId = req.user.id || req.user.userId;
        await users.clearUserFaceData(userId);
        res.json({ success: true });
    } catch (err) {
        console.error('[FaceLogin] Delete own face data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// =============================================
// FCM Push Notification Token Management
// =============================================

router.post('/fcm-token', async (req, res) => {
    try {
        const { token } = req.body;
        if (!token) return res.status(400).json({ success: false, error: 'Token is required' });
        await users.addFcmToken(req.user.id, token);
        res.json({ success: true });
    } catch (err) {
        console.error('[FCM] Register token error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.delete('/fcm-token', async (req, res) => {
    try {
        const { token } = req.body;
        if (!token) return res.status(400).json({ success: false, error: 'Token is required' });
        await users.removeFcmToken(req.user.id, token);
        res.json({ success: true });
    } catch (err) {
        console.error('[FCM] Remove token error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// FCM diagnostic - check registered tokens for all admins
router.get('/fcm-diagnostics', requireAdmin, async (req, res) => {
    try {
        const tokens = await users.getAdminFcmTokens(-1); // -1 = don't exclude anyone
        const allAdmins = await users.getAllUsers();
        const adminUsers = allAdmins.filter(u => ['admin', 'superadmin', 'ops'].includes(u.role));
        const diagnostics = adminUsers.map(u => ({
            username: u.username,
            role: u.role,
            tokenCount: Array.isArray(u.fcmTokens) ? u.fcmTokens.flat().filter(t => typeof t === 'string' && t.length > 0).length : 0,
            hasTokens: Array.isArray(u.fcmTokens) && u.fcmTokens.flat().filter(t => typeof t === 'string' && t.length > 0).length > 0,
        }));
        res.json({
            success: true,
            totalTokens: tokens.length,
            admins: diagnostics,
        });
    } catch (err) {
        console.error('[FCM] Diagnostics error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ====== CRUD ROUTES ======

// Get all users (admin only)
router.get('/', requireAdmin, async (req, res) => {
    try {
        const userList = await users.getAllUsers();
        res.json({ success: true, users: userList });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Store face data for a specific user (admin only)
router.post('/:id/face-data', requireAdmin, async (req, res) => {
    try {
        const { faceData } = req.body;
        if (!faceData) return res.status(400).json({ success: false, error: 'faceData is required' });
        const result = await users.storeUserFaceData(req.params.id, faceData);
        res.json(result);
    } catch (err) {
        console.error('[FaceLogin] Store user face data by ID error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get face data for a specific user (admin only)
router.get('/:id/face-data', requireAdmin, async (req, res) => {
    try {
        const data = await users.getUserFaceData(req.params.id);
        res.json({ faceData: data });
    } catch (err) {
        console.error('[FaceLogin] Get user face data by ID error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get user by ID (admin only)
router.get('/:id', requireAdmin, async (req, res) => {
    try {
        const user = await users.getUserById(req.params.id);
        if (!user) {
            return res.status(404).json({ success: false, error: 'User not found' });
        }
        res.json({ success: true, user });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Create user (admin only)
router.post('/', requireAdmin, async (req, res) => {
    console.log(`[API] POST /api/users request received: ${req.body.username}`);
    try {
        const { username, email, role, password, clientName, fullName, pageAccess } = req.body;
        if (!username) {
            return res.status(400).json({ success: false, error: 'Username is required' });
        }
        if (password && password.length < 6) {
            return res.status(400).json({ success: false, error: 'Password must be at least 6 characters' });
        }

        // Check if username already exists
        console.log(`[API] Checking existing user: ${username}`);
        const existingUser = await users.getUserByUsername(username);
        if (existingUser) {
            console.log(`[API] User already exists: ${username}`);
            return res.status(400).json({ success: false, error: 'Username already exists' });
        }

        console.log(`[API] Adding new user: ${username}`);
        const result = await users.addUser({ username, email, role, password, clientName, fullName, pageAccess });

        console.log(`[API] Add user result:`, result.success);
        if (result.success) {
            res.json(result);
        } else {
            res.status(500).json(result);
        }
    } catch (err) {
        console.error('[API] Error in POST /api/users:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Update user (admin only)
router.put('/:id', requireAdmin, async (req, res) => {
    console.log(`[API] PUT /api/users/${req.params.id} request received`);
    try {
        const { username, email, role, password, clientName, fullName, pageAccess } = req.body;
        const callerRole = req.user.role?.toLowerCase();

        // Only superadmin can edit admin/superadmin/ops users
        const targetUser = await users.getUserById(req.params.id);
        if (targetUser) {
            const targetRole = targetUser.role?.toLowerCase();
            if (['superadmin', 'admin', 'ops'].includes(targetRole) && callerRole !== 'superadmin') {
                return res.status(403).json({ success: false, error: 'Only Super Admin can modify admin users' });
            }
        }
        // Only superadmin can assign superadmin/admin roles
        if (['superadmin', 'admin'].includes(role?.toLowerCase()) && callerRole !== 'superadmin') {
            return res.status(403).json({ success: false, error: 'Only Super Admin can assign admin roles' });
        }

        const result = await users.updateUser(req.params.id, { username, email, role, password, clientName, fullName, pageAccess });

        console.log(`[API] Update user result:`, result.success);
        if (result.success) {
            res.json(result);
        } else {
            res.status(404).json(result);
        }
    } catch (err) {
        console.error('[API] Error in PUT /api/users:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete user (admin only)
router.delete('/:id', requireAdmin, async (req, res) => {
    try {
        const result = await users.deleteUser(req.params.id);
        if (result.success) {
            res.json(result);
        } else {
            res.status(400).json(result);
        }
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete face data for a specific user (admin only)
router.delete('/:id/face-data', requireAdmin, async (req, res) => {
    try {
        const cleared = await users.clearUserFaceData(req.params.id);
        if (!cleared) return res.status(404).json({ success: false, error: 'User not found' });
        res.json({ success: true });
    } catch (err) {
        console.error('[FaceLogin] Delete user face data by ID error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
