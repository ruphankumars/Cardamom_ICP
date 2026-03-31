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

const crypto = require('crypto');

// Lazy-resolve JWT_SECRET to support ICP canister env injection timing
let _jwtSecret;
function getJwtSecret() {
    if (!_jwtSecret) {
        _jwtSecret = process.env.JWT_SECRET;
        if (!_jwtSecret || _jwtSecret === 'CHANGE_IN_PRODUCTION_INSECURE_DEFAULT') {
            console.error('WARNING: JWT_SECRET not set. Using insecure default for development only.');
            _jwtSecret = 'icp_dev_jwt_secret_change_in_production_32chars';
        }
        if (_jwtSecret.length < 32) {
            console.warn('WARNING: JWT_SECRET is shorter than 32 characters.');
        }
    }
    return _jwtSecret;
}
const JWT_EXPIRY_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

// ---------------------------------------------------------------------------
// Lightweight JWT (no jsonwebtoken lib — avoids instanceof Buffer crash in ICP WASM)
// ---------------------------------------------------------------------------
function base64url(str) {
    return Buffer.from(str).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function base64urlDecode(str) {
    str = str.replace(/-/g, '+').replace(/_/g, '/');
    while (str.length % 4) str += '=';
    return Buffer.from(str, 'base64').toString('utf8');
}

function hmacSha256(data, secret) {
    // Use createHash with secret prefix — createHmac may crash in ICP WASM
    return crypto.createHash('sha256').update(secret + '.' + data).digest('base64')
        .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function sign(payload, secret) {
    const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
    const body = base64url(JSON.stringify(payload));
    const sig = hmacSha256(header + '.' + body, secret);
    return header + '.' + body + '.' + sig;
}

function verify(token, secret) {
    const parts = token.split('.');
    if (parts.length !== 3) throw new Error('Invalid token');
    const sig = hmacSha256(parts[0] + '.' + parts[1], secret);
    if (sig !== parts[2]) throw new Error('Invalid signature');
    const payload = JSON.parse(base64urlDecode(parts[1]));
    if (payload.exp && Date.now() > payload.exp) throw new Error('Token expired');
    return payload;
}

/**
 * Generate JWT token for authenticated user
 */
function generateToken(user) {
    return sign(
        {
            id: user.id,
            username: user.username,
            role: user.role,
            iat: Date.now(),
            exp: Date.now() + JWT_EXPIRY_MS
        },
        getJwtSecret()
    );
}

/**
 * Middleware: Verify JWT token and attach user to req
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

    try {
        const user = verify(token, getJwtSecret());
        req.user = user;
        next();
    } catch (err) {
        return res.status(401).json({
            success: false,
            error: 'Invalid or expired token'
        });
    }
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
    JWT_EXPIRY_MS
};
