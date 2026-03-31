/**
 * Auth Routes — Login, Face Login, Change Password
 *
 * Public routes (no JWT required for login/face-login).
 */
const router = require('express').Router();
const users = require('../../../backend/firebase/users_fb');
const { generateToken, authenticateToken } = require('../../../backend/middleware/auth');

// POST /api/auth/login
router.post('/login', async (req, res) => {
    try {
        const { username, password } = req.body;
        if (!username || !password) {
            return res.status(400).json({ success: false, error: 'Username and password are required' });
        }
        let result;
        try {
            result = await users.authenticateUser(username, password);
        } catch (authErr) {
            return res.status(500).json({ success: false, error: 'auth: ' + authErr.message });
        }
        if (result.success) {
            let token;
            try {
                token = generateToken(result.user);
            } catch (tokenErr) {
                return res.status(500).json({ success: false, error: 'token: ' + tokenErr.message });
            }
            res.json({
                success: true,
                user: result.user,
                token: token,
                mustChangePassword: result.user.mustChangePassword || false
            });
        } else {
            res.status(401).json(result);
        }
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: 'outer: ' + err.message });
    }
});

// POST /api/auth/face-login
router.post('/face-login', async (req, res) => {
    try {
        const { username, faceData } = req.body;
        if (!username || !faceData || typeof faceData !== 'object') {
            return res.status(400).json({ success: false, error: 'Username and face data are required' });
        }

        const user = await users.getUserByUsername(username);
        if (!user) {
            return res.status(401).json({ success: false, error: 'User not found' });
        }

        const storedFaceData = await users.getUserFaceData(user.id);
        if (!storedFaceData || Object.keys(storedFaceData).length === 0) {
            return res.status(401).json({ success: false, error: 'No face data enrolled for this user' });
        }

        const scanKeys = Object.keys(faceData);
        const storedKeys = Object.keys(storedFaceData);
        const isMeshScan = scanKeys.includes('leftEyeWidth');
        const isStoredMesh = storedKeys.includes('leftEyeWidth');

        let compareKeys, threshold;
        if (isMeshScan && isStoredMesh) {
            compareKeys = [
                'leftEyeWidth', 'rightEyeWidth', 'leftEyeHeight', 'rightEyeHeight',
                'leftBrowWidth', 'rightBrowWidth', 'leftBrowToEye', 'rightBrowToEye',
                'noseLength', 'noseWidth', 'noseTipToLeftEye', 'noseTipToRightEye',
                'mouthWidth', 'mouthHeight', 'noseToMouth',
                'faceWidth', 'faceHeight', 'chinToMouth', 'foreheadToNose', 'foreheadToBrow',
                'eyeWidthRatio', 'browWidthRatio', 'noseToFaceWidth', 'mouthToFaceWidth',
            ];
            threshold = 0.95;
        } else {
            compareKeys = ['noseTipToLeftEye', 'noseTipToRightEye', 'mouthWidth', 'noseToMouth', 'faceWidth', 'mouthToFaceWidth'];
            threshold = 0.88;
        }

        let totalRelErr = 0, matched = 0;
        for (const k of compareKeys) {
            const a = Number(faceData[k]) || 0;
            const b = Number(storedFaceData[k]) || 0;
            if (a === 0 || b === 0) continue;
            const mean = (a + b) / 2.0;
            if (mean > 0) {
                totalRelErr += Math.abs(a - b) / mean;
                matched++;
            }
        }

        const minKeys = (isMeshScan && isStoredMesh) ? 8 : 3;
        if (matched < minKeys) {
            return res.status(401).json({ success: false, error: 'Insufficient face data for verification' });
        }

        const similarity = 1.0 - (totalRelErr / matched);
        console.log(`[FaceLogin] User: ${username}, similarity: ${(similarity * 100).toFixed(1)}%, threshold: ${(threshold * 100).toFixed(0)}%, keys: ${matched}/${compareKeys.length}`);

        if (similarity < threshold) {
            return res.status(401).json({ success: false, error: 'Face verification failed' });
        }

        const token = generateToken(user);
        res.json({
            success: true,
            user: user,
            token: token,
            mustChangePassword: user.mustChangePassword || false,
        });
    } catch (err) {
        console.error('[FaceLogin] Error:', err);
        res.status(500).json({ success: false, error: 'Face login error' });
    }
});

// POST /api/auth/change-password (requires JWT)
router.post('/change-password', authenticateToken, async (req, res) => {
    try {
        const { currentPassword, newPassword } = req.body;

        if (!currentPassword || !newPassword) {
            return res.status(400).json({ success: false, error: 'Current password and new password are required' });
        }

        const passwordRegex = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}$/;
        if (!passwordRegex.test(newPassword)) {
            return res.status(400).json({
                success: false,
                error: 'Password must be at least 8 characters with 1 uppercase, 1 lowercase, and 1 digit'
            });
        }

        if (currentPassword === newPassword) {
            return res.status(400).json({ success: false, error: 'New password must be different from current password' });
        }

        const result = await users.changePassword(req.user.username, currentPassword, newPassword);
        if (result.success) {
            res.json({ success: true, message: 'Password changed successfully' });
        } else {
            res.status(400).json(result);
        }
    } catch (err) {
        console.error('[POST /api/auth/change-password] Error:', err);
        res.status(500).json({ success: false, error: 'Failed to change password' });
    }
});

module.exports = router;
