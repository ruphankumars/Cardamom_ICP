/**
 * Firebase Admin SDK Client
 * 
 * Drop-in replacement for sheetsClient.js during phased migration.
 * Initializes Firebase Admin from environment variables or service account file.
 * 
 * Required env vars (set in Render dashboard):
 *   FIREBASE_PROJECT_ID
 *   FIREBASE_CLIENT_EMAIL
 *   FIREBASE_PRIVATE_KEY
 *   FIREBASE_STORAGE_BUCKET (optional, for Firebase Storage)
 * 
 * OR provide a serviceAccountKey.json file at project root.
 */

const admin = require('firebase-admin');
const path = require('path');
const fs = require('fs');

const SERVICE_ACCOUNT_PATH = path.join(__dirname, '../serviceAccountKey.json');

// Initialize Firebase Admin - support both env vars and JSON file
let initialized = false;

function initializeFirebase() {
    if (initialized) return;

    try {
        if (process.env.FIREBASE_PROJECT_ID && process.env.FIREBASE_CLIENT_EMAIL && process.env.FIREBASE_PRIVATE_KEY) {
            // Cloud deployment: use environment variables
            admin.initializeApp({
                credential: admin.credential.cert({
                    projectId: process.env.FIREBASE_PROJECT_ID,
                    clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
                    privateKey: process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n'),
                }),
                storageBucket: process.env.FIREBASE_STORAGE_BUCKET || `${process.env.FIREBASE_PROJECT_ID}.firebasestorage.app`,
            });
            console.log('[Firebase] Initialized from environment variables');
        } else if (fs.existsSync(SERVICE_ACCOUNT_PATH)) {
            // Local development: use service account JSON file
            const serviceAccount = require(SERVICE_ACCOUNT_PATH);
            admin.initializeApp({
                credential: admin.credential.cert(serviceAccount),
                storageBucket: process.env.FIREBASE_STORAGE_BUCKET || `${serviceAccount.project_id}.firebasestorage.app`,
            });
            console.log('[Firebase] Initialized from serviceAccountKey.json');
        } else {
            console.error('[Firebase] No credentials found!');
            console.error('[Firebase] Set FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY');
            console.error('[Firebase] OR provide serviceAccountKey.json at project root');
            throw new Error('Firebase credentials not configured');
        }

        initialized = true;
    } catch (err) {
        // If already initialized (e.g., during hot reload), ignore
        if (err.code === 'app/duplicate-app') {
            initialized = true;
            console.log('[Firebase] Already initialized (reuse)');
        } else {
            throw err;
        }
    }
}

// Lazy-init: initialize on first use
function getDb() {
    initializeFirebase();
    return admin.firestore();
}

function getAuth() {
    initializeFirebase();
    return admin.auth();
}

function getStorage() {
    initializeFirebase();
    return admin.storage().bucket();
}

// ============================================================================
// GENERIC CRUD HELPERS (match the sheetsClient.js patterns your code uses)
// ============================================================================

/**
 * Get a Firestore collection reference
 * @param {string} collectionName
 * @returns {FirebaseFirestore.CollectionReference}
 */
function collection(collectionName) {
    return getDb().collection(collectionName);
}

/**
 * Get a single document by ID
 * @param {string} collectionName
 * @param {string} docId
 * @returns {Promise<Object|null>}
 */
async function getDoc(collectionName, docId) {
    const snap = await getDb().collection(collectionName).doc(docId).get();
    if (!snap.exists) return null;
    return { id: snap.id, ...snap.data() };
}

/**
 * Get all documents in a collection (with optional query filters)
 * @param {string} collectionName
 * @param {Array<{field, op, value}>} filters - Optional Firestore where clauses
 * @param {Object} options - { orderBy, limit }
 * @returns {Promise<Array<Object>>}
 */
async function getDocs(collectionName, filters = [], options = {}) {
    let query = getDb().collection(collectionName);

    for (const { field, op, value } of filters) {
        query = query.where(field, op, value);
    }

    if (options.orderBy) {
        const [field, direction] = Array.isArray(options.orderBy)
            ? options.orderBy
            : [options.orderBy, 'asc'];
        query = query.orderBy(field, direction);
    }

    if (options.limit) {
        query = query.limit(options.limit);
    }

    const snapshot = await query.get();
    return snapshot.docs.map(doc => ({ id: doc.id, ...doc.data() }));
}

/**
 * Add a document (auto-generate ID)
 * @param {string} collectionName
 * @param {Object} data
 * @returns {Promise<{id: string}>}
 */
async function addDoc(collectionName, data) {
    const ref = await getDb().collection(collectionName).add({
        ...data,
        _createdAt: admin.firestore.FieldValue.serverTimestamp(),
        _updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { id: ref.id };
}

/**
 * Set a document with explicit ID (create or overwrite)
 * @param {string} collectionName
 * @param {string} docId
 * @param {Object} data
 * @param {boolean} merge - If true, merge with existing data
 */
async function setDoc(collectionName, docId, data, merge = false) {
    await getDb().collection(collectionName).doc(docId).set({
        ...data,
        _updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge });
}

/**
 * Update specific fields on a document
 * @param {string} collectionName
 * @param {string} docId
 * @param {Object} updates
 */
async function updateDoc(collectionName, docId, updates) {
    await getDb().collection(collectionName).doc(docId).update({
        ...updates,
        _updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
}

/**
 * Delete a document
 * @param {string} collectionName
 * @param {string} docId
 */
async function deleteDoc(collectionName, docId) {
    await getDb().collection(collectionName).doc(docId).delete();
}

/**
 * Run a Firestore transaction (for atomic read-modify-write)
 * @param {Function} updateFn - Receives transaction object
 */
async function runTransaction(updateFn) {
    return getDb().runTransaction(updateFn);
}

/**
 * Batch write (up to 500 operations)
 * @returns {FirebaseFirestore.WriteBatch}
 */
function createBatch() {
    return getDb().batch();
}

/**
 * Server timestamp value (for use in write operations)
 */
function serverTimestamp() {
    return admin.firestore.FieldValue.serverTimestamp();
}

/**
 * Firestore FieldValue helpers
 */
const FieldValue = admin.firestore.FieldValue;

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

    // Re-export admin for advanced use cases
    admin,
};
