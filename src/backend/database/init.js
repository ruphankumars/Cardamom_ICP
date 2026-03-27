/**
 * Database Initialization Module
 *
 * Initializes the SQLite database on server startup:
 * 1. Attempts to load existing database from stable memory / filesystem
 * 2. If no existing database, creates a new one and runs schema.sql
 * 3. Seeds default admin user if users table is empty
 * 4. Hooks up debounced persistence for write operations
 *
 * Usage:
 *   const { initializeDatabase } = require('./init');
 *   await initializeDatabase();
 */

const { initDatabase, getDatabase, exportDatabase } = require('./sqliteClient');
const { loadFromStorage, schedulePersist } = require('./stableMemory');
const bcrypt = require('bcryptjs');

/**
 * Initialize the complete database stack.
 * Call once at server startup.
 */
async function initializeDatabase() {
    console.log('[DB Init] Starting database initialization...');

    // 1. Try to load existing database from persistent storage
    const existingData = loadFromStorage();

    // 2. Initialize sql.js with existing data or fresh database
    await initDatabase(existingData);

    // 3. Seed defaults if this is a fresh database
    await seedDefaults();

    // 4. Set up auto-persistence hook
    setupPersistenceHook();

    console.log('[DB Init] Database initialization complete');
}

/**
 * Seed default data into a fresh database.
 * Idempotent — only inserts if tables are empty.
 */
async function seedDefaults() {
    const db = getDatabase();
    if (!db) return;

    // Check if admin user exists
    const stmt = db.prepare('SELECT COUNT(*) as count FROM users');
    stmt.step();
    const result = stmt.getAsObject();
    stmt.free();

    if (result.count === 0) {
        console.log('[DB Init] Seeding default admin user...');

        // Create default superadmin
        const tempPassword = 'CardamomAdmin@2024';
        const salt = bcrypt.genSaltSync(10);
        const hashedPassword = bcrypt.hashSync(tempPassword, salt);

        const adminData = {
            username: 'admin',
            password: hashedPassword,
            role: 'superadmin',
            fullName: 'System Administrator',
            email: '',
            clientName: '',
            pageAccess: {
                dashboard: true,
                orders: true,
                stock: true,
                dispatch: true,
                tasks: true,
                attendance: true,
                expenses: true,
                gatepasses: true,
                analytics: true,
                settings: true,
                users: true,
                approvals: true,
            },
            faceData: null,
            fcmTokens: [],
            isActive: true,
            _createdAt: new Date().toISOString(),
            _updatedAt: new Date().toISOString(),
        };

        const id = 'admin-001';
        db.run(
            'INSERT INTO users (id, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?)',
            [id, JSON.stringify(adminData), adminData._createdAt, adminData._updatedAt]
        );

        console.log('[DB Init] Default admin user created (username: admin)');
        console.log('[DB Init] IMPORTANT: Change the default password immediately!');
    }

    // Seed default settings if empty
    const settingsStmt = db.prepare('SELECT COUNT(*) as count FROM settings');
    settingsStmt.step();
    const settingsCount = settingsStmt.getAsObject();
    settingsStmt.free();

    if (settingsCount.count === 0) {
        console.log('[DB Init] Seeding default settings...');

        const notifData = {
            phones: [],
            updatedAt: null,
            updatedBy: null,
        };

        db.run(
            'INSERT INTO settings (id, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?)',
            ['notification_numbers', JSON.stringify(notifData), new Date().toISOString(), new Date().toISOString()]
        );

        console.log('[DB Init] Default settings created');
    }

    // Initialize counter for user IDs
    const counterStmt = db.prepare("SELECT COUNT(*) as count FROM counters WHERE id = 'user_id_sequence'");
    counterStmt.step();
    const counterCount = counterStmt.getAsObject();
    counterStmt.free();

    if (counterCount.count === 0) {
        const counterData = { current: 1 };
        db.run(
            'INSERT INTO counters (id, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?)',
            ['user_id_sequence', JSON.stringify(counterData), new Date().toISOString(), new Date().toISOString()]
        );
        console.log('[DB Init] User ID counter initialized');
    }
}

/**
 * Set up automatic persistence after database writes.
 * Uses debounced saving to avoid excessive I/O.
 */
function setupPersistenceHook() {
    // Schedule persistence every time the module is used
    // The actual hook into write operations is done via schedulePersist
    // called from sqliteClient after mutations
    console.log('[DB Init] Persistence hook configured (debounce: 2s)');
}

/**
 * Get database statistics for health checks
 */
function getDatabaseStats() {
    const db = getDatabase();
    if (!db) return { status: 'not initialized' };

    const tables = [];
    const stmt = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
    while (stmt.step()) {
        const row = stmt.getAsObject();
        const countStmt = db.prepare(`SELECT COUNT(*) as count FROM "${row.name}"`);
        countStmt.step();
        const count = countStmt.getAsObject();
        countStmt.free();
        tables.push({ name: row.name, rows: count.count });
    }
    stmt.free();

    const exported = exportDatabase();
    const sizeBytes = exported ? exported.length : 0;

    return {
        status: 'connected',
        tables: tables.length,
        tableDetails: tables,
        sizeBytes,
        sizeMB: (sizeBytes / 1024 / 1024).toFixed(2),
    };
}

// Run directly if called as a script (npm run db:init)
if (require.main === module) {
    initializeDatabase()
        .then(() => {
            console.log('\n[DB Init] Database stats:');
            console.log(JSON.stringify(getDatabaseStats(), null, 2));
            process.exit(0);
        })
        .catch(err => {
            console.error('[DB Init] Failed:', err);
            process.exit(1);
        });
}

module.exports = {
    initializeDatabase,
    seedDefaults,
    getDatabaseStats,
};
