/**
 * Users Module — Firebase Firestore Backend
 * 
 * Drop-in replacement for ../users.js (Google Sheets version).
 * Exports the EXACT same API so server.js doesn't need changes.
 * 
 * Firestore collection: "users"
 * Document ID: auto-generated or numeric string matching legacy IDs
 * 
 * Improvements over Sheets version:
 *   - bcrypt password hashing (not SHA-256)
 *   - Proper indexed queries (no full-table scan)
 *   - Atomic operations (no read-modify-write race)
 *   - No row-index issues
 */

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const { getDb, getDocs, getDoc, serverTimestamp, FieldValue } = require('../../src/backend/database/sqliteClient');

const COLLECTION = 'users';
const BCRYPT_ROUNDS = 10;

// ============================================================================
// PASSWORD HASHING — bcrypt replaces SHA-256
// ============================================================================

async function hashPassword(password) {
    return bcrypt.hash(password, BCRYPT_ROUNDS);
}

async function verifyPassword(password, hash) {
    // Support legacy SHA-256 hashes during migration
    const legacyHash = crypto.createHash('sha256').update(password).digest('hex');
    if (hash === legacyHash) {
        return true; // Legacy hash matched
    }
    // Try bcrypt
    try {
        return await bcrypt.compare(password, hash);
    } catch {
        return false;
    }
}

// ============================================================================
// DEFAULT PAGE ACCESS (same logic as Sheets version)
// ============================================================================

function getDefaultPageAccess(role) {
    const allPages = {
        new_order: true,
        view_orders: true,
        sales_summary: true,
        grade_allocator: true,
        daily_cart: true,
        add_to_cart: true,
        stock_tools: true,
        order_requests: true,
        pending_approvals: true,
        task_management: true,
        attendance: true,
        expenses: true,
        gate_passes: true,
        admin: true,
        dropdown_manager: true,
        edit_orders: true,
        delete_orders: true,
        offer_price: true,
        outstanding: true,
        dispatch_documents: true,
    };

    // Super admin, admin and ops roles get full access to all pages
    if (role === 'superadmin' || role === 'admin' || role === 'ops') return allPages;

    if (role === 'employee' || role === 'user') {
        return {
            new_order: true, view_orders: true, sales_summary: false,
            grade_allocator: false, daily_cart: true, add_to_cart: true,
            stock_tools: false, order_requests: false, pending_approvals: false,
            task_management: true, attendance: true, expenses: true,
            gate_passes: true, admin: false, dropdown_manager: false,
            edit_orders: false, delete_orders: false,
            offer_price: false, outstanding: false, dispatch_documents: true,
        };
    }

    // Default for other/unrecognized roles
    return {
        new_order: true, view_orders: true, sales_summary: true,
        grade_allocator: true, daily_cart: true, add_to_cart: true,
        stock_tools: true, order_requests: true, pending_approvals: true,
        task_management: true, attendance: true, expenses: true,
        gate_passes: true, admin: false, dropdown_manager: false,
        edit_orders: false, delete_orders: false,
        offer_price: false, outstanding: false, dispatch_documents: true,
    };
}

// ============================================================================
// HELPERS
// ============================================================================

/** Strip password from user object before returning to client */
function sanitize(user) {
    if (!user) return null;
    const { password, ...rest } = user;
    return rest;
}

/** Get the users collection */
function usersCol() {
    return getDb().collection(COLLECTION);
}

/** Generate next numeric ID (for legacy compatibility) */
async function getNextId() {
    const snapshot = await usersCol().orderBy('id', 'desc').limit(1).get();
    if (snapshot.empty) return 1;
    const maxId = snapshot.docs[0].data().id || 0;
    return maxId + 1;
}

// ============================================================================
// CRUD — Same API signatures as ../users.js
// ============================================================================

/**
 * Get all users (without passwords)
 */
async function getAllUsers() {
    const snapshot = await usersCol().get();
    return snapshot.docs.map(doc => sanitize({ id: doc.data().id, ...doc.data() }));
}

/**
 * Get user by numeric ID (without password)
 */
async function getUserById(id) {
    const numId = parseInt(id);
    const snapshot = await usersCol().where('id', '==', numId).limit(1).get();
    if (snapshot.empty) return null;
    return sanitize({ id: snapshot.docs[0].data().id, ...snapshot.docs[0].data() });
}

/**
 * Get user by username (without password)
 */
async function getUserByUsername(username) {
    const snapshot = await usersCol().where('username', '==', username).limit(1).get();
    if (snapshot.empty) return null;
    return sanitize({ id: snapshot.docs[0].data().id, ...snapshot.docs[0].data() });
}

/**
 * Authenticate user — supports both bcrypt and legacy SHA-256
 */
async function authenticateUser(username, password) {
    const snapshot = await usersCol().where('username', '==', username).limit(1).get();
    if (snapshot.empty) {
        return { success: false, error: 'Invalid username or password' };
    }

    const doc = snapshot.docs[0];
    const user = { id: doc.data().id, ...doc.data() };

    const valid = await verifyPassword(password, user.password);
    if (!valid) {
        return { success: false, error: 'Invalid username or password' };
    }

    // If user has a legacy SHA-256 hash, upgrade to bcrypt transparently
    const legacyHash = crypto.createHash('sha256').update(password).digest('hex');
    if (user.password === legacyHash) {
        const bcryptHash = await hashPassword(password);
        await doc.ref.update({ password: bcryptHash });
        console.log(`[Users-FB] Upgraded password hash for ${username} from SHA-256 to bcrypt`);
    }

    return { success: true, user: sanitize(user) };
}

/**
 * Add new user
 */
async function addUser(userData) {
    try {
        const db = getDb();
        return await db.runTransaction(async (transaction) => {
            // Check username uniqueness within transaction
            const existingSnap = await usersCol().where('username', '==', userData.username).limit(1).get();
            if (!existingSnap.empty) return { success: false, error: 'Username already exists' };

            // Atomic counter for user IDs
            const counterRef = db.collection('counters').doc('user_id_sequence');
            const counterDoc = await transaction.get(counterRef);
            let newId;
            if (!counterDoc.exists) {
                const snapshot = await usersCol().orderBy('id', 'desc').limit(1).get();
                newId = snapshot.empty ? 1 : (snapshot.docs[0].data().id || 0) + 1;
            } else {
                newId = (counterDoc.data().sequence || 0) + 1;
            }
            transaction.set(counterRef, { sequence: newId });

            const role = userData.role || 'employee';
            if (!userData.password || userData.password.length < 8) {
                throw new Error('Password is required and must be at least 8 characters');
            }
            const hashedPw = await hashPassword(userData.password);

            const newUser = {
                id: newId,
                username: userData.username,
                password: hashedPw,
                email: userData.email || '',
                role: role,
                clientName: userData.clientName || '',
                fullName: userData.fullName || '',
                pageAccess: userData.pageAccess || getDefaultPageAccess(role),
                createdAt: new Date().toISOString(),
            };

            transaction.set(usersCol().doc(String(newId)), newUser);
            return { success: true, user: sanitize(newUser) };
        });
    } catch (err) {
        console.error('[Users-FB] Error adding user:', err.message);
        return { success: false, error: 'Failed to save user: ' + err.message };
    }
}

/**
 * Update user
 */
async function updateUser(id, userData) {
    try {
        const numId = parseInt(id);
        const snapshot = await usersCol().where('id', '==', numId).limit(1).get();
        if (snapshot.empty) {
            return { success: false, error: 'User not found' };
        }

        const doc = snapshot.docs[0];
        const existing = doc.data();

        const updates = {
            username: userData.username || existing.username,
            email: userData.email !== undefined ? userData.email : existing.email,
            role: userData.role || existing.role,
            clientName: userData.clientName !== undefined ? userData.clientName : existing.clientName,
            fullName: userData.fullName !== undefined ? userData.fullName : existing.fullName,
            pageAccess: userData.pageAccess !== undefined
                ? userData.pageAccess
                : (existing.pageAccess || getDefaultPageAccess(userData.role || existing.role)),
        };

        if (userData.password) {
            updates.password = await hashPassword(userData.password);
        }

        await doc.ref.update(updates);

        const updated = { ...existing, ...updates, id: numId };
        return { success: true, user: sanitize(updated) };
    } catch (err) {
        console.error('[Users-FB] Error updating user:', err.message);
        return { success: false, error: 'Failed to update user: ' + err.message };
    }
}

/**
 * Delete user
 */
async function deleteUser(id) {
    try {
        const numId = parseInt(id);
        const snapshot = await usersCol().where('id', '==', numId).limit(1).get();
        if (snapshot.empty) {
            return { success: false, error: 'User not found' };
        }

        const doc = snapshot.docs[0];
        const user = doc.data();

        // Prevent deleting the last admin
        if (user.role === 'admin') {
            const adminCount = await usersCol().where('role', '==', 'admin').count().get();
            if (adminCount.data().count <= 1) {
                return { success: false, error: 'Cannot delete the last admin user' };
            }
        }

        await doc.ref.delete();
        return { success: true };
    } catch (err) {
        console.error('[Users-FB] Error deleting user:', err.message);
        return { success: false, error: 'Failed to delete user: ' + err.message };
    }
}

/**
 * Initialize from JSON (migration compatibility — no-op for Firestore)
 */
async function initializeFromJson() {
    // Check if collection is empty — if so, create default admin
    const snapshot = await usersCol().limit(1).get();
    if (snapshot.empty) {
        console.log('[Users-FB] No users found, creating default admin');
        const defaultPassword = crypto.randomBytes(12).toString('base64url');
        const hashedPw = await hashPassword(defaultPassword);
        await usersCol().doc('1').set({
            id: 1,
            username: 'admin',
            password: hashedPw,
            email: 'admin@example.com',
            role: 'admin',
            clientName: '',
            fullName: 'Administrator',
            pageAccess: getDefaultPageAccess('admin'),
            mustChangePassword: true,
            createdAt: new Date().toISOString(),
        });
        console.log(`\n⚠️  Default admin created. Temporary password: ${defaultPassword}\n`);
    } else {
        console.log('[Users-FB] Users collection already has data');
    }
}

/**
 * Change user password — verifies current password, hashes new one, removes mustChangePassword flag
 */
async function changePassword(username, currentPassword, newPassword) {
    // Password strength validation
    if (!newPassword || newPassword.length < 8) {
        return { success: false, error: 'New password must be at least 8 characters' };
    }

    const snapshot = await usersCol().where('username', '==', username).limit(1).get();
    if (snapshot.empty) {
        return { success: false, error: 'User not found' };
    }

    const doc = snapshot.docs[0];
    const user = doc.data();

    const valid = await verifyPassword(currentPassword, user.password);
    if (!valid) {
        return { success: false, error: 'Current password is incorrect' };
    }

    const hashedPw = await hashPassword(newPassword);
    const updateData = { password: hashedPw };

    // Remove mustChangePassword flag after successful change
    if (user.mustChangePassword) {
        updateData.mustChangePassword = FieldValue.delete();
    }

    await doc.ref.update(updateData);
    return { success: true };
}

// ============================================================================
// FCM TOKEN MANAGEMENT — for push notifications
// ============================================================================

/**
 * Add FCM token to user's token array (supports multiple devices)
 */
async function addFcmToken(userId, token) {
    const numId = parseInt(userId);
    const snapshot = await usersCol().where('id', '==', numId).limit(1).get();
    if (snapshot.empty) {
        console.warn(`[Users-FB] addFcmToken: user ${userId} not found`);
        return;
    }
    await snapshot.docs[0].ref.update({
        fcmTokens: FieldValue.arrayUnion(token),
    });
    console.log(`[Users-FB] FCM token added for user ${userId}`);
}

/**
 * Remove FCM token from user's token array (on logout or token invalidation)
 */
async function removeFcmToken(userId, token) {
    const numId = parseInt(userId);
    const snapshot = await usersCol().where('id', '==', numId).limit(1).get();
    if (snapshot.empty) return;
    await snapshot.docs[0].ref.update({
        fcmTokens: FieldValue.arrayRemove(token),
    });
    console.log(`[Users-FB] FCM token removed for user ${userId}`);
}

/**
 * Get all FCM tokens for admin/superadmin users (excluding a specific user)
 * Used for broadcasting push notifications to other admins.
 */
async function getAdminFcmTokens(excludeUserId) {
    const excludeId = typeof excludeUserId === 'number' ? excludeUserId : parseInt(excludeUserId, 10);
    const tokens = [];

    const extractTokens = (fcmTokens) => {
        if (!Array.isArray(fcmTokens)) return [];
        // Flatten in case of legacy nested arrays from previous arrayUnion([token]) bug
        return fcmTokens.flat().filter(t => typeof t === 'string' && t.length > 0);
    };

    // Get all admin, superadmin, and ops users
    const adminSnap = await usersCol().where('role', 'in', ['admin', 'superadmin', 'ops']).get();
    adminSnap.docs.forEach(doc => {
        const data = doc.data();
        if (data.id !== excludeId) {
            tokens.push(...extractTokens(data.fcmTokens));
        }
    });

    console.log(`[Users-FB] getAdminFcmTokens: found ${tokens.length} token(s) (excluded userId=${excludeId})`);
    return tokens;
}

/**
 * Remove stale FCM tokens (called when FCM reports UNREGISTERED tokens)
 */
async function removeStaleTokens(staleTokens) {
    if (!staleTokens || staleTokens.length === 0) return;

    // Get all users who have fcmTokens
    const snapshot = await usersCol().get();
    const batch = getDb().batch();
    let updateCount = 0;

    snapshot.docs.forEach(doc => {
        const data = doc.data();
        if (data.fcmTokens && data.fcmTokens.length > 0) {
            const tokensToRemove = data.fcmTokens.filter(t => staleTokens.includes(t));
            if (tokensToRemove.length > 0) {
                batch.update(doc.ref, {
                    fcmTokens: FieldValue.arrayRemove(...tokensToRemove),
                });
                updateCount++;
            }
        }
    });

    if (updateCount > 0) {
        await batch.commit();
        console.log(`[Users-FB] Removed stale FCM tokens from ${updateCount} user(s)`);
    }
}

// ============================================================================
// USER FACE DATA — for face-based login
// ============================================================================

/**
 * Store face landmark data for a user (admin face enrollment for login)
 */
async function storeUserFaceData(userId, faceData) {
    const numId = parseInt(userId);
    const snapshot = await usersCol().where('id', '==', numId).limit(1).get();
    if (snapshot.empty) {
        return { success: false, error: 'User not found' };
    }
    await snapshot.docs[0].ref.update({ faceData });
    console.log(`[Users-FB] Face data stored for user ${userId}`);
    return { success: true };
}

/**
 * Get face data for a specific user
 */
async function getUserFaceData(userId) {
    const numId = parseInt(userId);
    const snapshot = await usersCol().where('id', '==', numId).limit(1).get();
    if (snapshot.empty) return null;
    const data = snapshot.docs[0].data();
    return data.faceData || null;
}

/**
 * Clear (delete) face data for a specific user
 */
async function clearUserFaceData(userId) {
    const numId = parseInt(userId);
    // Try numeric ID first, then string fallback (Firestore is type-strict)
    let snapshot = await usersCol().where('id', '==', numId).limit(1).get();
    if (snapshot.empty) {
        snapshot = await usersCol().where('id', '==', String(userId)).limit(1).get();
    }
    if (snapshot.empty) return false;
    await snapshot.docs[0].ref.update({ faceData: null });
    return true;
}

/**
 * Get all users who have face data enrolled (for face login matching)
 * Returns minimal info: userId, username, role, faceData
 * NOTE: This is used pre-authentication, so no password is returned.
 */
async function getAllUserFaceData() {
    const snapshot = await usersCol().get();
    const results = [];
    snapshot.docs.forEach(doc => {
        const data = doc.data();
        if (data.faceData && Object.keys(data.faceData).length > 0) {
            results.push({
                userId: data.id,
                username: data.username,
                role: data.role,
                fullName: data.fullName || '',
                faceData: data.faceData,
            });
        }
    });
    return results;
}

/**
 * Get FCM tokens for superadmin users only.
 * Used for dispatch/transport document notifications.
 */
async function getSuperadminFcmTokens() {
    const tokens = [];
    const extractTokens = (fcmTokens) => {
        if (!Array.isArray(fcmTokens)) return [];
        return fcmTokens.flat().filter(t => typeof t === 'string' && t.length > 0);
    };

    const snap = await usersCol().where('role', '==', 'superadmin').get();
    snap.docs.forEach(doc => {
        tokens.push(...extractTokens(doc.data().fcmTokens));
    });

    console.log(`[Users-FB] getSuperadminFcmTokens: found ${tokens.length} token(s)`);
    return tokens;
}

module.exports = {
    getAllUsers,
    getUserById,
    getUserByUsername,
    addUser,
    updateUser,
    deleteUser,
    authenticateUser,
    changePassword,
    hashPassword,
    initializeFromJson,
    addFcmToken,
    removeFcmToken,
    getAdminFcmTokens,
    getSuperadminFcmTokens,
    removeStaleTokens,
    storeUserFaceData,
    getUserFaceData,
    clearUserFaceData,
    getAllUserFaceData,
};
