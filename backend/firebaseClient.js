/**
 * Firebase Client — ICP Compatibility Shim
 *
 * Redirects all Firestore operations to the SQLite-based database layer.
 * This shim exists so that modules still importing from `./firebaseClient`
 * (reports, integrityCheck, audit_log, pricing_intelligence, migration scripts)
 * continue to work without changing their import paths.
 *
 * The real database layer lives at: src/backend/database/sqliteClient.js
 */

const { getDb } = require('../src/backend/database/sqliteClient');

// Re-export getDb as the primary interface — callers use getDb().collection(...)
// which is the same Firestore-compatible API provided by sqliteClient.js

function initializeFirebase() {
    // No-op on ICP — database is initialized via sqliteClient.initDatabase()
    console.log('[firebaseClient shim] initializeFirebase() called — no-op on ICP');
}

function collection(name) {
    return getDb().collection(name);
}

async function getDoc(collectionName, docId) {
    const snap = await getDb().collection(collectionName).doc(docId).get();
    if (!snap.exists) return null;
    return { id: snap.id, ...snap.data() };
}

async function getDocs(collectionName, filters = [], options = {}) {
    let query = getDb().collection(collectionName);
    for (const { field, op, value } of filters) {
        query = query.where(field, op, value);
    }
    if (options.orderBy) {
        const [field, direction] = Array.isArray(options.orderBy)
            ? options.orderBy : [options.orderBy, 'asc'];
        query = query.orderBy(field, direction);
    }
    if (options.limit) {
        query = query.limit(options.limit);
    }
    const snapshot = await query.get();
    return snapshot.docs.map(doc => ({ id: doc.id, ...doc.data() }));
}

async function addDoc(collectionName, data) {
    const ref = getDb().collection(collectionName).doc();
    await ref.set({
        ...data,
        _createdAt: new Date().toISOString(),
        _updatedAt: new Date().toISOString(),
    });
    return { id: ref.id };
}

async function setDoc(collectionName, docId, data, merge = false) {
    await getDb().collection(collectionName).doc(docId).set({
        ...data,
        _updatedAt: new Date().toISOString(),
    }, { merge });
}

async function updateDoc(collectionName, docId, updates) {
    await getDb().collection(collectionName).doc(docId).update({
        ...updates,
        _updatedAt: new Date().toISOString(),
    });
}

async function deleteDoc(collectionName, docId) {
    await getDb().collection(collectionName).doc(docId).delete();
}

async function runTransaction(updateFn) {
    // SQLite transactions are handled at the sql.js level
    // For compatibility, just run the function with a mock transaction
    return updateFn({
        get: async (ref) => ref.get(),
        set: (ref, data) => ref.set(data),
        update: (ref, data) => ref.update(data),
        delete: (ref) => ref.delete(),
    });
}

function createBatch() {
    // Return a simple batch that collects operations
    const ops = [];
    return {
        set: (ref, data, options) => ops.push(() => ref.set(data, options)),
        update: (ref, data) => ops.push(() => ref.update(data)),
        delete: (ref) => ops.push(() => ref.delete()),
        commit: async () => {
            for (const op of ops) await op();
        },
    };
}

function serverTimestamp() {
    return new Date().toISOString();
}

// Stub FieldValue for compatibility
const FieldValue = {
    serverTimestamp: () => new Date().toISOString(),
    delete: () => null,
    increment: (n) => n,
    arrayUnion: (...elements) => elements,
    arrayRemove: (...elements) => elements,
};

module.exports = {
    getDb,
    getAuth: () => { throw new Error('Firebase Auth not available on ICP'); },
    getStorage: () => { throw new Error('Firebase Storage not available on ICP'); },
    collection,
    initializeFirebase,
    getDoc,
    getDocs,
    addDoc,
    setDoc,
    updateDoc,
    deleteDoc,
    runTransaction,
    createBatch,
    serverTimestamp,
    FieldValue,
    admin: null, // No firebase-admin on ICP
};
