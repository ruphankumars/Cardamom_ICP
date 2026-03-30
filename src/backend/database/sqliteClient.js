/**
 * SQLite Client — Drop-in replacement for firebaseClient.js
 *
 * Uses sql.js (WASM-based SQLite) to provide the same API surface as the
 * Firebase Admin SDK client. All Firestore collection/document operations
 * are translated to equivalent SQLite queries.
 *
 * Collections map to tables. Documents map to rows with JSON blob storage.
 * Firestore query operators (where, orderBy, limit) are translated to SQL.
 */

const { v4: uuidv4 } = require('uuid');
// Use asm.js build — WASM-in-WASM doesn't work on ICP, and asm.js doesn't need a separate .wasm file
const initSqlJs = require('sql.js/dist/sql-asm.js');

let db = null;
let SQL = null;

// ============================================================================
// Initialization
// ============================================================================

// Inline schema — fs.readFileSync not available in ICP WASM
const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS orders (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS cart_orders (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS packed_orders (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS client_requests (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS client_request_messages (id TEXT PRIMARY KEY, parentId TEXT NOT NULL, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS rejected_offers (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS approval_requests (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS live_stock_entries (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS stock_adjustments (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS net_stock_cache (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS sale_order_summary (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS dispatch_documents (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS transport_documents (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS daily_transport_assignments (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS workers (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS attendance (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS expenses (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS expense_items (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS gate_passes (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS settings (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS dropdown_data (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS client_contacts (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS offer_prices (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS client_name_mappings (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS packedBoxes (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS notifications (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS whatsapp_send_logs (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS counters (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS lot_counters (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS order_edit_history (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS unarchive_requests (id TEXT PRIMARY KEY, data TEXT NOT NULL DEFAULT '{}', _createdAt TEXT DEFAULT (datetime('now')), _updatedAt TEXT DEFAULT (datetime('now')));
CREATE INDEX IF NOT EXISTS idx_users_username ON users(json_extract(data, '$.username'));
CREATE INDEX IF NOT EXISTS idx_users_role ON users(json_extract(data, '$.role'));
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_orders_client ON orders(json_extract(data, '$.clientName'));
CREATE INDEX IF NOT EXISTS idx_orders_date ON orders(json_extract(data, '$.date'));
CREATE INDEX IF NOT EXISTS idx_cart_orders_client ON cart_orders(json_extract(data, '$.clientName'));
CREATE INDEX IF NOT EXISTS idx_packed_orders_client ON packed_orders(json_extract(data, '$.clientName'));
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_tasks_assigned ON tasks(json_extract(data, '$.assignedTo'));
CREATE INDEX IF NOT EXISTS idx_attendance_worker ON attendance(json_extract(data, '$.workerId'));
CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance(json_extract(data, '$.date'));
CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(json_extract(data, '$.date'));
CREATE INDEX IF NOT EXISTS idx_gate_passes_status ON gate_passes(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_dispatch_docs_status ON dispatch_documents(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_dispatch_docs_date ON dispatch_documents(json_extract(data, '$.date'));
CREATE INDEX IF NOT EXISTS idx_approval_status ON approval_requests(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(json_extract(data, '$.userId'));
CREATE INDEX IF NOT EXISTS idx_notifications_read ON notifications(json_extract(data, '$.read'));
CREATE INDEX IF NOT EXISTS idx_client_requests_status ON client_requests(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_client_request_messages_parent ON client_request_messages(parentId);
`;

/**
 * Initialize the SQLite database using sql.js
 */
async function initDatabase(existingData) {
    if (db) return db;

    SQL = await initSqlJs();

    if (existingData) {
        db = new SQL.Database(existingData);
        console.log('[SQLite] Database restored from existing data');
    } else {
        db = new SQL.Database();
        console.log('[SQLite] New database created');
    }

    // Apply inline schema (fs not available on ICP WASM)
    const statements = SCHEMA_SQL.split(';').map(s => s.trim()).filter(s => s.length > 0);
    for (const stmt of statements) {
        db.run(stmt + ';');
    }
    console.log('[SQLite] Schema applied successfully (' + statements.length + ' statements)');

    return db;
}

/**
 * Get the raw sql.js database instance
 */
function getDatabase() {
    return db;
}

/**
 * Export database as Uint8Array (for stable memory persistence)
 */
function exportDatabase() {
    if (!db) return null;
    return db.export();
}

/**
 * Replace the in-memory database with new binary data (for DB upload/import)
 */
function replaceDatabase(data) {
    if (!SQL) throw new Error('SQL not initialized');
    if (db) db.close();
    db = new SQL.Database(new Uint8Array(data));
    // Re-apply schema to ensure any missing tables/indexes exist
    const statements = SCHEMA_SQL.split(';').map(s => s.trim()).filter(s => s.length > 0);
    for (const stmt of statements) {
        try { db.run(stmt); } catch (_) {}
    }
    console.log('[SQLite] Database replaced from uploaded binary');
    _afterWrite(); // persist to stable memory
    return true;
}

/**
 * Debounced write hook — schedules persistence to stable memory after DB mutations.
 * Called automatically after addDoc, setDoc, updateDoc, deleteDoc, batch commit, transaction commit.
 */
let _schedulePersist = null;
function _afterWrite() {
    if (!_schedulePersist) {
        try {
            _schedulePersist = require('./stableMemory').schedulePersist;
        } catch { _schedulePersist = () => {}; }
    }
    _schedulePersist(exportDatabase);
}

// ============================================================================
// Firestore-compatible CRUD Helpers
// ============================================================================

/**
 * Get the Firestore-style "db" object with collection() method
 * Compatible with: getDb().collection('name').doc('id').get()
 */
function getDb() {
    return {
        collection: (name) => collectionRef(name),
        runTransaction: (fn) => runTransaction(fn),
        batch: () => createBatch(),
    };
}

/**
 * Get a single document by ID
 * @param {string} collectionName
 * @param {string} docId
 * @returns {Object|null} — { id, ...data } or null
 */
async function getDoc(collectionName, docId) {
    ensureDb();
    const stmt = db.prepare(`SELECT id, data, _createdAt, _updatedAt FROM "${collectionName}" WHERE id = ?`);
    stmt.bind([docId]);
    if (stmt.step()) {
        const row = stmt.getAsObject();
        stmt.free();
        const data = JSON.parse(row.data || '{}');
        return { id: row.id, ...data, _createdAt: row._createdAt, _updatedAt: row._updatedAt };
    }
    stmt.free();
    return null;
}

/**
 * Get documents with optional filters and options
 * @param {string} collectionName
 * @param {Array<{field, op, value}>} filters — Firestore-style where clauses
 * @param {Object} options — { orderBy, limit, direction }
 * @returns {Array<Object>}
 */
async function getDocs(collectionName, filters = [], options = {}) {
    ensureDb();

    let sql = `SELECT id, data, _createdAt, _updatedAt FROM "${collectionName}"`;
    const params = [];
    const whereClauses = [];

    for (const filter of filters) {
        const { field, op, value } = filter;
        const sqlOp = translateOp(op);

        if (op === 'array-contains') {
            whereClauses.push(`EXISTS (SELECT 1 FROM json_each(json_extract(data, '$.${escapeJsonPath(field)}')) WHERE value = ?)`);
            params.push(value);
        } else if (op === 'in') {
            const placeholders = value.map(() => '?').join(',');
            whereClauses.push(`json_extract(data, '$.${escapeJsonPath(field)}') IN (${placeholders})`);
            params.push(...value);
        } else if (op === 'not-in') {
            const placeholders = value.map(() => '?').join(',');
            whereClauses.push(`json_extract(data, '$.${escapeJsonPath(field)}') NOT IN (${placeholders})`);
            params.push(...value);
        } else if (op === 'array-contains-any') {
            const conditions = value.map(() =>
                `EXISTS (SELECT 1 FROM json_each(json_extract(data, '$.${escapeJsonPath(field)}')) WHERE value = ?)`
            ).join(' OR ');
            whereClauses.push(`(${conditions})`);
            params.push(...value);
        } else {
            whereClauses.push(`json_extract(data, '$.${escapeJsonPath(field)}') ${sqlOp} ?`);
            params.push(value);
        }
    }

    if (whereClauses.length > 0) {
        sql += ' WHERE ' + whereClauses.join(' AND ');
    }

    if (options.orderBy) {
        const [field, direction] = Array.isArray(options.orderBy)
            ? options.orderBy
            : [options.orderBy, 'asc'];
        sql += ` ORDER BY json_extract(data, '$.${escapeJsonPath(field)}') ${direction === 'desc' ? 'DESC' : 'ASC'}`;
    }

    if (options.limit) {
        sql += ` LIMIT ?`;
        params.push(options.limit);
    }

    const results = [];
    const stmt = db.prepare(sql);
    stmt.bind(params);
    while (stmt.step()) {
        const row = stmt.getAsObject();
        const data = JSON.parse(row.data || '{}');
        results.push({ id: row.id, ...data, _createdAt: row._createdAt, _updatedAt: row._updatedAt });
    }
    stmt.free();
    return results;
}

/**
 * Add a document with auto-generated ID
 * @param {string} collectionName
 * @param {Object} data
 * @returns {{ id: string }}
 */
async function addDoc(collectionName, data) {
    ensureDb();
    const id = uuidv4();
    const now = new Date().toISOString();
    const docData = { ...data, _createdAt: now, _updatedAt: now };

    db.run(
        `INSERT INTO "${collectionName}" (id, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?)`,
        [id, JSON.stringify(docData), now, now]
    );

    _afterWrite();
    return { id };
}

/**
 * Set a document with explicit ID (create or overwrite)
 * @param {string} collectionName
 * @param {string} docId
 * @param {Object} data
 * @param {boolean} merge — if true, merge with existing data
 */
async function setDoc(collectionName, docId, data, merge = false) {
    ensureDb();
    const now = new Date().toISOString();

    if (merge) {
        // Try to get existing data first
        const existing = await getDoc(collectionName, docId);
        if (existing) {
            const { id, _createdAt, _updatedAt, ...existingData } = existing;
            const merged = { ...existingData, ...data, _updatedAt: now };
            db.run(
                `UPDATE "${collectionName}" SET data = ?, _updatedAt = ? WHERE id = ?`,
                [JSON.stringify(merged), now, docId]
            );
            _afterWrite();
            return;
        }
    }

    const docData = { ...data, _updatedAt: now };
    db.run(
        `INSERT OR REPLACE INTO "${collectionName}" (id, data, _createdAt, _updatedAt) VALUES (?, ?, COALESCE((SELECT _createdAt FROM "${collectionName}" WHERE id = ?), ?), ?)`,
        [docId, JSON.stringify(docData), docId, now, now]
    );
    _afterWrite();
}

/**
 * Update specific fields on a document
 * @param {string} collectionName
 * @param {string} docId
 * @param {Object} updates
 */
async function updateDoc(collectionName, docId, updates) {
    ensureDb();
    const now = new Date().toISOString();

    const existing = await getDoc(collectionName, docId);
    if (!existing) {
        throw new Error(`Document ${collectionName}/${docId} does not exist`);
    }

    const { id, _createdAt, _updatedAt, ...existingData } = existing;

    // Process FieldValue operations
    const merged = { ...existingData };
    for (const [key, value] of Object.entries(updates)) {
        if (value && value._type === 'FieldValue') {
            if (value._op === 'delete') {
                delete merged[key];
            } else if (value._op === 'arrayUnion') {
                const arr = Array.isArray(merged[key]) ? [...merged[key]] : [];
                for (const item of value._elements) {
                    if (!arr.includes(item)) arr.push(item);
                }
                merged[key] = arr;
            } else if (value._op === 'arrayRemove') {
                if (Array.isArray(merged[key])) {
                    merged[key] = merged[key].filter(item => !value._elements.includes(item));
                }
            } else if (value._op === 'increment') {
                merged[key] = (typeof merged[key] === 'number' ? merged[key] : 0) + value._value;
            }
        } else if (key.includes('.')) {
            // Handle dot-notation for nested fields (e.g., 'address.city')
            setNestedValue(merged, key, value);
        } else {
            merged[key] = value;
        }
    }

    merged._updatedAt = now;

    db.run(
        `UPDATE "${collectionName}" SET data = ?, _updatedAt = ? WHERE id = ?`,
        [JSON.stringify(merged), now, docId]
    );
    _afterWrite();
}

/**
 * Delete a document
 * @param {string} collectionName
 * @param {string} docId
 */
async function deleteDoc(collectionName, docId) {
    ensureDb();
    db.run(`DELETE FROM "${collectionName}" WHERE id = ?`, [docId]);
    _afterWrite();
}

// ============================================================================
// Firestore-compatible collection() reference builder
// ============================================================================

/**
 * Returns a Firestore-style collection reference with chainable query methods.
 * Supports: .doc(), .where(), .orderBy(), .limit(), .get(), .add()
 */
function collectionRef(name) {
    return new CollectionRef(name);
}

class CollectionRef {
    constructor(name) {
        this._name = name;
        this._filters = [];
        this._orderByField = null;
        this._orderByDir = 'asc';
        this._limitVal = null;
        this._startAfterDoc = null;
    }

    doc(docId) {
        return new DocRef(this._name, docId);
    }

    where(field, op, value) {
        const clone = this._clone();
        clone._filters.push({ field, op, value });
        return clone;
    }

    orderBy(field, direction = 'asc') {
        const clone = this._clone();
        clone._orderByField = field;
        clone._orderByDir = direction;
        return clone;
    }

    limit(n) {
        const clone = this._clone();
        clone._limitVal = n;
        return clone;
    }

    startAfter(doc) {
        const clone = this._clone();
        clone._startAfterDoc = doc;
        return clone;
    }

    async get() {
        ensureDb();
        let sql = `SELECT id, data, _createdAt, _updatedAt FROM "${this._name}"`;
        const params = [];
        const whereClauses = [];

        for (const filter of this._filters) {
            const { field, op, value } = filter;
            if (op === 'array-contains') {
                whereClauses.push(`EXISTS (SELECT 1 FROM json_each(json_extract(data, '$.${escapeJsonPath(field)}')) WHERE value = ?)`);
                params.push(value);
            } else if (op === 'in') {
                const placeholders = value.map(() => '?').join(',');
                whereClauses.push(`json_extract(data, '$.${escapeJsonPath(field)}') IN (${placeholders})`);
                params.push(...value);
            } else if (op === 'not-in') {
                const placeholders = value.map(() => '?').join(',');
                whereClauses.push(`json_extract(data, '$.${escapeJsonPath(field)}') NOT IN (${placeholders})`);
                params.push(...value);
            } else if (op === 'array-contains-any') {
                const conditions = value.map(() =>
                    `EXISTS (SELECT 1 FROM json_each(json_extract(data, '$.${escapeJsonPath(field)}')) WHERE value = ?)`
                ).join(' OR ');
                whereClauses.push(`(${conditions})`);
                params.push(...value);
            } else {
                const sqlOp = translateOp(op);
                whereClauses.push(`json_extract(data, '$.${escapeJsonPath(field)}') ${sqlOp} ?`);
                params.push(value);
            }
        }

        if (whereClauses.length > 0) {
            sql += ' WHERE ' + whereClauses.join(' AND ');
        }

        if (this._orderByField) {
            sql += ` ORDER BY json_extract(data, '$.${escapeJsonPath(this._orderByField)}') ${this._orderByDir === 'desc' ? 'DESC' : 'ASC'}`;
        }

        if (this._limitVal) {
            sql += ` LIMIT ?`;
            params.push(this._limitVal);
        }

        const docs = [];
        const stmt = db.prepare(sql);
        stmt.bind(params);
        while (stmt.step()) {
            const row = stmt.getAsObject();
            const data = JSON.parse(row.data || '{}');
            docs.push(new DocSnapshot(row.id, { ...data, _createdAt: row._createdAt, _updatedAt: row._updatedAt }, true, this._name));
        }
        stmt.free();

        return new QuerySnapshot(docs);
    }

    async add(data) {
        return addDoc(this._name, data);
    }

    count() {
        return {
            get: async () => {
                ensureDb();
                let sql = `SELECT COUNT(*) as count FROM "${this._name}"`;
                const params = [];
                const whereClauses = [];

                for (const filter of this._filters) {
                    const { field, op, value } = filter;
                    if (op === 'in') {
                        const placeholders = value.map(() => '?').join(',');
                        whereClauses.push(`json_extract(data, '$.${escapeJsonPath(field)}') IN (${placeholders})`);
                        params.push(...value);
                    } else {
                        const sqlOp = translateOp(op);
                        whereClauses.push(`json_extract(data, '$.${escapeJsonPath(field)}') ${sqlOp} ?`);
                        params.push(value);
                    }
                }

                if (whereClauses.length > 0) {
                    sql += ' WHERE ' + whereClauses.join(' AND ');
                }

                const stmt = db.prepare(sql);
                stmt.bind(params);
                stmt.step();
                const result = stmt.getAsObject();
                stmt.free();
                return { data: () => ({ count: result.count }) };
            }
        };
    }

    _clone() {
        const c = new CollectionRef(this._name);
        c._filters = [...this._filters];
        c._orderByField = this._orderByField;
        c._orderByDir = this._orderByDir;
        c._limitVal = this._limitVal;
        c._startAfterDoc = this._startAfterDoc;
        return c;
    }
}

// ============================================================================
// Document Reference — .doc('id').get() / .set() / .update() / .delete()
// ============================================================================

class DocRef {
    constructor(collectionName, docId) {
        this._collection = collectionName;
        this._id = docId;
    }

    get id() {
        return this._id;
    }

    get path() {
        return `${this._collection}/${this._id}`;
    }

    collection(subcollectionName) {
        // For subcollections like client_requests/{id}/messages
        // Map to flattened table: client_request_messages with parentId
        return new SubcollectionRef(this._collection, this._id, subcollectionName);
    }

    async get() {
        ensureDb();
        const stmt = db.prepare(`SELECT id, data, _createdAt, _updatedAt FROM "${this._collection}" WHERE id = ?`);
        stmt.bind([this._id]);
        if (stmt.step()) {
            const row = stmt.getAsObject();
            stmt.free();
            const data = JSON.parse(row.data || '{}');
            return new DocSnapshot(row.id, { ...data, _createdAt: row._createdAt, _updatedAt: row._updatedAt }, true, this._collection);
        }
        stmt.free();
        return new DocSnapshot(this._id, null, false, this._collection);
    }

    async set(data, options = {}) {
        return setDoc(this._collection, this._id, data, options.merge || false);
    }

    async update(updates) {
        return updateDoc(this._collection, this._id, updates);
    }

    async delete() {
        return deleteDoc(this._collection, this._id);
    }
}

// ============================================================================
// Subcollection Reference — for nested collections like messages
// ============================================================================

class SubcollectionRef {
    constructor(parentCollection, parentId, subcollectionName) {
        // Flatten subcollection name: client_requests + messages -> client_request_messages
        this._tableName = `${parentCollection.replace(/s$/, '')}_${subcollectionName}`;
        this._parentId = parentId;
        this._filters = [];
        this._orderByField = null;
        this._orderByDir = 'asc';
        this._limitVal = null;
    }

    doc(docId) {
        return new DocRef(this._tableName, docId || uuidv4());
    }

    where(field, op, value) {
        const clone = this._clone();
        clone._filters.push({ field, op, value });
        return clone;
    }

    orderBy(field, direction = 'asc') {
        const clone = this._clone();
        clone._orderByField = field;
        clone._orderByDir = direction;
        return clone;
    }

    limit(n) {
        const clone = this._clone();
        clone._limitVal = n;
        return clone;
    }

    async get() {
        ensureDb();
        let sql = `SELECT id, data, parentId, _createdAt, _updatedAt FROM "${this._tableName}" WHERE parentId = ?`;
        const params = [this._parentId];

        for (const filter of this._filters) {
            const { field, op, value } = filter;
            const sqlOp = translateOp(op);
            sql += ` AND json_extract(data, '$.${escapeJsonPath(field)}') ${sqlOp} ?`;
            params.push(value);
        }

        if (this._orderByField) {
            sql += ` ORDER BY json_extract(data, '$.${escapeJsonPath(this._orderByField)}') ${this._orderByDir === 'desc' ? 'DESC' : 'ASC'}`;
        }

        if (this._limitVal) {
            sql += ` LIMIT ?`;
            params.push(this._limitVal);
        }

        const docs = [];
        const stmt = db.prepare(sql);
        stmt.bind(params);
        while (stmt.step()) {
            const row = stmt.getAsObject();
            const data = JSON.parse(row.data || '{}');
            docs.push(new DocSnapshot(row.id, { ...data, _createdAt: row._createdAt, _updatedAt: row._updatedAt }, true, this._tableName));
        }
        stmt.free();

        return new QuerySnapshot(docs);
    }

    async add(data) {
        ensureDb();
        const id = uuidv4();
        const now = new Date().toISOString();
        const docData = { ...data, _createdAt: now, _updatedAt: now };

        db.run(
            `INSERT INTO "${this._tableName}" (id, parentId, data, _createdAt, _updatedAt) VALUES (?, ?, ?, ?, ?)`,
            [id, this._parentId, JSON.stringify(docData), now, now]
        );

        _afterWrite();
        return { id };
    }

    _clone() {
        const c = new SubcollectionRef('', '', '');
        c._tableName = this._tableName;
        c._parentId = this._parentId;
        c._filters = [...this._filters];
        c._orderByField = this._orderByField;
        c._orderByDir = this._orderByDir;
        c._limitVal = this._limitVal;
        return c;
    }
}

// ============================================================================
// Snapshot classes — mimic Firestore QuerySnapshot and DocumentSnapshot
// ============================================================================

class QuerySnapshot {
    constructor(docs) {
        this.docs = docs;
        this.empty = docs.length === 0;
        this.size = docs.length;
    }

    forEach(callback) {
        this.docs.forEach(callback);
    }
}

class DocSnapshot {
    constructor(id, data, exists, collectionName) {
        this.id = id;
        this._data = data;
        this.exists = exists;
        this.ref = new DocRef(collectionName, id);
    }

    data() {
        return this._data;
    }

    get(field) {
        if (!this._data) return undefined;
        return this._data[field];
    }
}

// ============================================================================
// Transaction support
// ============================================================================

/**
 * Run a transaction. The callback receives a transaction object with
 * get(), set(), update(), delete() methods.
 */
async function runTransaction(updateFn) {
    ensureDb();
    db.run('BEGIN TRANSACTION');
    try {
        const transaction = new Transaction();
        const result = await updateFn(transaction);
        db.run('COMMIT');
        _afterWrite();
        return result;
    } catch (err) {
        db.run('ROLLBACK');
        throw err;
    }
}

class Transaction {
    async get(docRef) {
        return docRef.get();
    }

    async set(docRef, data, options = {}) {
        return docRef.set(data, options);
    }

    async update(docRef, updates) {
        return docRef.update(updates);
    }

    async delete(docRef) {
        return docRef.delete();
    }
}

// ============================================================================
// Batch write support
// ============================================================================

function createBatch() {
    return new WriteBatch();
}

class WriteBatch {
    constructor() {
        this._operations = [];
    }

    set(docRef, data, options = {}) {
        this._operations.push({ type: 'set', ref: docRef, data, options });
        return this;
    }

    update(docRef, updates) {
        this._operations.push({ type: 'update', ref: docRef, data: updates });
        return this;
    }

    delete(docRef) {
        this._operations.push({ type: 'delete', ref: docRef });
        return this;
    }

    async commit() {
        ensureDb();
        db.run('BEGIN TRANSACTION');
        try {
            for (const op of this._operations) {
                if (op.type === 'set') {
                    await op.ref.set(op.data, op.options);
                } else if (op.type === 'update') {
                    await op.ref.update(op.data);
                } else if (op.type === 'delete') {
                    await op.ref.delete();
                }
            }
            db.run('COMMIT');
            _afterWrite();
        } catch (err) {
            db.run('ROLLBACK');
            throw err;
        }
    }
}

// ============================================================================
// FieldValue helpers — mimic Firestore FieldValue operations
// ============================================================================

const FieldValue = {
    serverTimestamp() {
        return new Date().toISOString();
    },

    arrayUnion(...elements) {
        return { _type: 'FieldValue', _op: 'arrayUnion', _elements: elements.flat() };
    },

    arrayRemove(...elements) {
        return { _type: 'FieldValue', _op: 'arrayRemove', _elements: elements.flat() };
    },

    delete() {
        return { _type: 'FieldValue', _op: 'delete' };
    },

    increment(value) {
        return { _type: 'FieldValue', _op: 'increment', _value: value };
    },
};

/**
 * Server timestamp — returns ISO string
 */
function serverTimestamp() {
    return new Date().toISOString();
}

// ============================================================================
// collection() function — matches firebaseClient.js API
// ============================================================================

function collection(name) {
    return collectionRef(name);
}

// ============================================================================
// Utility functions
// ============================================================================

function ensureDb() {
    if (!db) {
        throw new Error('[SQLite] Database not initialized. Call initDatabase() first.');
    }
}

function translateOp(firestoreOp) {
    const ops = {
        '==': '=',
        '!=': '!=',
        '<': '<',
        '<=': '<=',
        '>': '>',
        '>=': '>=',
    };
    return ops[firestoreOp] || '=';
}

function escapeJsonPath(field) {
    // Handle nested field paths like 'address.city' -> 'address'.'city' won't work
    // sql.js json_extract uses '$.address.city' which works directly
    return field.replace(/'/g, "''");
}

function setNestedValue(obj, path, value) {
    const keys = path.split('.');
    let current = obj;
    for (let i = 0; i < keys.length - 1; i++) {
        if (!current[keys[i]] || typeof current[keys[i]] !== 'object') {
            current[keys[i]] = {};
        }
        current = current[keys[i]];
    }
    current[keys[keys.length - 1]] = value;
}

// ============================================================================
// Stub functions for Firebase-specific APIs that don't apply to SQLite
// ============================================================================

function getAuth() {
    console.warn('[SQLite] getAuth() called — Firebase Auth is not available on ICP');
    return null;
}

function getStorage() {
    console.warn('[SQLite] getStorage() called — Firebase Storage is not available on ICP');
    return null;
}

function initializeFirebase() {
    // No-op for backward compatibility
    console.log('[SQLite] initializeFirebase() called — using SQLite instead');
}

// ============================================================================
// Exports — match firebaseClient.js API surface exactly
// ============================================================================

module.exports = {
    // Core access
    getDb,
    getAuth,
    getStorage,
    collection,
    initializeFirebase,

    // CRUD helpers
    getDoc,
    getDocs,
    addDoc,
    setDoc,
    updateDoc,
    deleteDoc,

    // Advanced
    runTransaction,
    createBatch,
    serverTimestamp,
    FieldValue,

    // Database lifecycle
    initDatabase,
    getDatabase,
    exportDatabase,
    replaceDatabase,

    // Re-export for compatibility (admin is no longer needed but some modules reference it)
    admin: {
        firestore: {
            FieldValue,
        },
    },
};
