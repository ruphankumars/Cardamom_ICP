/**
 * JWT Authentication Middleware
 *
 * Provides secure token-based authentication to replace header spoofing vulnerability.
 *
 * Security fixes:
 * - Replaces unsafe x-role/x-user header authentication
 * - Implements JWT token generation and verification
 * - Provides role-based access control (admin, ops, client)
 * - Tokens expire after 7 days
 */

const jwt = require('jsonwebtoken');

const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || JWT_SECRET === 'CHANGE_IN_PRODUCTION_INSECURE_DEFAULT') {
    console.error('FATAL: JWT_SECRET environment variable must be set to a secure value.');
    // On ICP, process.exit is not available — throw instead
    throw new Error('JWT_SECRET must be set');
}
if (JWT_SECRET.length < 32) {
    console.warn('WARNING: JWT_SECRET is shorter than 32 characters. Consider using a longer secret.');
}
const JWT_EXPIRY = '7d';

/**
 * Generate JWT token for authenticated user
 * @param {Object} user - User object with id, username, role
 * @returns {string} JWT token
 */
function generateToken(user) {
    return jwt.sign(
        {
            id: user.id,
            username: user.username,
            role: user.role
        },
        JWT_SECRET,
        { expiresIn: JWT_EXPIRY }
    );
}

/**
 * Middleware: Verify JWT token and attach user to req
 *
 * Expects Authorization header: "Bearer <token>"
 * On success: attaches req.user = { id, username, role }
 * On failure: returns 401 (no token) or 403 (invalid token)
 */
function authenticateToken(req, res, next) {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1]; // Bearer TOKEN

    if (!token) {
        return res.status(401).json({
            success: false,
            error: 'Authentication required'
        });
    }

    jwt.verify(token, JWT_SECRET, (err, user) => {
        if (err) {
            return res.status(401).json({
                success: false,
                error: 'Invalid or expired token'
            });
        }
        req.user = user; // Attach verified user to request
        next();
    });
}

/**
 * Middleware: Require admin or ops role
 *
 * Must be used AFTER authenticateToken
 * Checks req.user.role is 'admin' or 'ops'
 */
function requireAdmin(req, res, next) {
    if (!req.user) {
        return res.status(401).json({
            success: false,
            error: 'Authentication required'
        });
    }

    const role = req.user.role?.toLowerCase();
    if (role !== 'superadmin' && role !== 'admin' && role !== 'ops') {
        return res.status(403).json({
            success: false,
            error: 'Admin access required'
        });
    }

    next();
}

/**
 * Middleware: Require superadmin role only
 *
 * Must be used AFTER authenticateToken
 * Checks req.user.role is strictly 'superadmin'
 */
function requireSuperAdmin(req, res, next) {
    if (!req.user) {
        return res.status(401).json({
            success: false,
            error: 'Authentication required'
        });
    }

    const role = req.user.role?.toLowerCase();
    if (role !== 'superadmin') {
        return res.status(403).json({
            success: false,
            error: 'Superadmin access required'
        });
    }

    next();
}

/**
 * Middleware: Require client role
 *
 * Must be used AFTER authenticateToken
 * Checks req.user.role is 'client'
 */
function requireClient(req, res, next) {
    if (!req.user) {
        return res.status(401).json({
            success: false,
            error: 'Authentication required'
        });
    }

    const role = req.user.role?.toLowerCase();
    if (role !== 'client') {
        return res.status(403).json({
            success: false,
            error: 'Client access required'
        });
    }

    next();
}

/**
 * Middleware: Require authenticated user (any role)
 *
 * Alias for authenticateToken for clarity in route definitions
 */
function requireAuth(req, res, next) {
    return authenticateToken(req, res, next);
}

/**
 * Middleware factory: Require specific pageAccess permission
 *
 * Must be used AFTER authenticateToken
 * Fetches user's pageAccess from DB and checks the given key.
 * This enforces granular permissions even for admin/ops users.
 */
function requirePageAccess(pageKey) {
    return async (req, res, next) => {
        if (!req.user) {
            return res.status(401).json({ success: false, error: 'Authentication required' });
        }

        try {
            // Superadmin bypasses all pageAccess checks
            const role = req.user.role?.toLowerCase();
            if (role === 'superadmin') {
                return next();
            }

            // Lazy-require to avoid circular dependency at module load time
            const users = require('../firebase/users_fb');
            const user = await users.getUserByUsername(req.user.username);
            if (!user) {
                return res.status(403).json({ success: false, error: 'User not found' });
            }

            const pageAccess = user.pageAccess;
            const userRole = (user.role || '').toLowerCase();
            // Superadmin and admin bypass page-level access checks
            if (userRole !== 'superadmin' && userRole !== 'admin') {
                // Default-deny: if pageAccess map exists, the key must be explicitly true
                if (!pageAccess || pageAccess[pageKey] !== true) {
                    return res.status(403).json({ success: false, error: `No access to ${pageKey}` });
                }
            }

            next();
        } catch (err) {
            console.error(`[Auth] Error checking pageAccess for ${pageKey}:`, err);
            return res.status(500).json({ success: false, error: 'Permission check failed' });
        }
    };
}

module.exports = {
    generateToken,
    authenticateToken,
    requireAuth,
    requireAdmin,
    requireSuperAdmin,
    requireClient,
    requirePageAccess,
    JWT_EXPIRY
};
