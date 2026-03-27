/**
 * Stable Memory Persistence Layer
 *
 * Handles persisting the sql.js in-memory database to ICP stable memory
 * so data survives canister upgrades. On non-ICP environments (local dev),
 * falls back to filesystem persistence.
 *
 * Strategy:
 * - On init: load Uint8Array from stable storage, pass to sql.js Database()
 * - After writes: export via db.export(), save to stable storage
 * - Debounced persistence to avoid excessive writes
 */

// Lazy-load fs/path — not available on ICP WASM, only needed for local dev fallback
let _fs, _path;
function getFs() { if (!_fs) _fs = require('fs'); return _fs; }
function getPath() { if (!_path) _path = require('path'); return _path; }
function getDefaultDbPath() { return getPath().join(__dirname, '../../../data/cardamom.db'); }

// Debounce timer for persistence
let persistTimer = null;
const PERSIST_DEBOUNCE_MS = 2000; // 2 seconds after last write

/**
 * Load database binary from persistent storage.
 * Returns Uint8Array or null if no saved database exists.
 *
 * On ICP: loads from StableBTreeMap (to be implemented with Azle stable storage)
 * On local: loads from filesystem
 */
function loadFromStorage() {
    if (isIcpEnvironment()) {
        return loadFromStableMemory();
    }
    return loadFromFilesystem();
}

/**
 * Save database binary to persistent storage.
 * Accepts Uint8Array from db.export().
 *
 * On ICP: saves to StableBTreeMap
 * On local: saves to filesystem
 */
function saveToStorage(data) {
    if (isIcpEnvironment()) {
        return saveToStableMemory(data);
    }
    return saveToFilesystem(data);
}

/**
 * Schedule a debounced persist operation.
 * Call this after every write operation to batch persistence.
 * @param {Function} exportFn - function that returns Uint8Array (db.export())
 */
function schedulePersist(exportFn) {
    if (persistTimer) {
        clearTimeout(persistTimer);
    }
    persistTimer = setTimeout(() => {
        try {
            const data = exportFn();
            if (data) {
                saveToStorage(data);
            }
        } catch (err) {
            console.error('[StableMemory] Persistence error:', err.message);
        }
    }, PERSIST_DEBOUNCE_MS);
}

/**
 * Force immediate persistence (e.g., before canister upgrade)
 * @param {Function} exportFn
 */
function persistNow(exportFn) {
    if (persistTimer) {
        clearTimeout(persistTimer);
        persistTimer = null;
    }
    try {
        const data = exportFn();
        if (data) {
            saveToStorage(data);
            console.log('[StableMemory] Database persisted immediately');
        }
    } catch (err) {
        console.error('[StableMemory] Immediate persistence error:', err.message);
    }
}

// ============================================================================
// ICP Stable Memory (Azle StableBTreeMap)
// ============================================================================

// Placeholder for Azle stable memory integration.
// When running on ICP, this will use Azle's StableBTreeMap to store the
// serialized database. For now, this is a no-op that will be wired up
// when the canister is deployed.

let stableStorage = null;

/**
 * Set the stable storage backend (called from Azle canister init)
 * @param {Object} storage - object with get(key) and set(key, value) methods
 */
function setStableStorage(storage) {
    stableStorage = storage;
    console.log('[StableMemory] Stable storage backend configured');
}

function loadFromStableMemory() {
    if (!stableStorage) {
        console.warn('[StableMemory] No stable storage configured, starting fresh');
        return null;
    }
    try {
        const data = stableStorage.get('sqlite_db');
        if (data) {
            console.log(`[StableMemory] Loaded database from stable memory (${data.length} bytes)`);
            return new Uint8Array(data);
        }
    } catch (err) {
        console.error('[StableMemory] Failed to load from stable memory:', err.message);
    }
    return null;
}

function saveToStableMemory(data) {
    if (!stableStorage) {
        console.warn('[StableMemory] No stable storage configured, skipping persist');
        return;
    }
    try {
        stableStorage.set('sqlite_db', Buffer.from(data));
        console.log(`[StableMemory] Saved database to stable memory (${data.length} bytes)`);
    } catch (err) {
        console.error('[StableMemory] Failed to save to stable memory:', err.message);
    }
}

// ============================================================================
// Filesystem persistence (local development fallback)
// ============================================================================

function loadFromFilesystem() {
    try {
        const fs = getFs();
        const dbPath = getDefaultDbPath();
        if (fs.existsSync(dbPath)) {
            const buffer = fs.readFileSync(dbPath);
            console.log(`[StableMemory] Loaded database from ${dbPath} (${buffer.length} bytes)`);
            return new Uint8Array(buffer);
        }
    } catch (err) {
        console.error('[StableMemory] Failed to load from filesystem:', err.message);
    }
    return null;
}

function saveToFilesystem(data) {
    try {
        const fs = getFs();
        const dbPath = getDefaultDbPath();
        const dir = getPath().dirname(dbPath);
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }
        fs.writeFileSync(dbPath, Buffer.from(data));
        console.log(`[StableMemory] Saved database to ${dbPath} (${data.length} bytes)`);
    } catch (err) {
        console.error('[StableMemory] Failed to save to filesystem:', err.message);
    }
}

// ============================================================================
// Environment detection
// ============================================================================

function isIcpEnvironment() {
    // Azle sets specific environment indicators when running on ICP
    return !!(process.env.CANISTER_ID || process.env.DFX_NETWORK || stableStorage);
}

module.exports = {
    loadFromStorage,
    saveToStorage,
    schedulePersist,
    persistNow,
    setStableStorage,
    isIcpEnvironment,
};
