/**
 * Storage Helper — Firebase Storage with automatic Render disk fallback.
 *
 * Tries Firebase Storage first (preferred). If the billing account is
 * disabled or any Firebase Storage error occurs, the file is saved to
 * the local Render disk and served via Express at /api/files/*.
 *
 * Once Firebase billing is restored the fallback stops activating
 * automatically — no code change or toggle needed.
 */

const path = require('path');
const fs = require('fs').promises;
const { getStorage } = require('../firebaseClient');

// Local upload directory (relative to project root)
const UPLOAD_DIR = path.join(__dirname, '..', '..', 'uploads');

/**
 * Upload a buffer and return a publicly accessible URL.
 *
 * @param {Buffer} buffer       File contents
 * @param {string} storagePath  Path inside the bucket / local dir (e.g. "dispatch-documents/client/file.pdf")
 * @param {string} contentType  MIME type (e.g. "application/pdf", "image/jpeg")
 * @returns {Promise<string>}   Public URL
 */
async function uploadFile(buffer, storagePath, contentType) {
    // ── 1. Try Firebase Storage ──────────────────────────────────────
    try {
        const bucket = getStorage();
        const file = bucket.file(storagePath);
        await file.save(buffer, { metadata: { contentType }, resumable: false });
        await file.makePublic();
        const url = `https://storage.googleapis.com/${bucket.name}/${storagePath}`;
        console.log(`[StorageHelper] Firebase upload OK → ${storagePath}`);
        return url;
    } catch (err) {
        console.warn(`[StorageHelper] Firebase Storage failed: ${err.message}`);
        console.warn('[StorageHelper] Falling back to Render disk storage...');
    }

    // ── 2. Fallback: Render disk ─────────────────────────────────────
    const localPath = path.join(UPLOAD_DIR, storagePath);
    await fs.mkdir(path.dirname(localPath), { recursive: true });
    await fs.writeFile(localPath, buffer);

    const baseUrl = process.env.RENDER_EXTERNAL_URL
        || process.env.BASE_URL
        || `http://localhost:${process.env.PORT || 3000}`;

    const url = `${baseUrl}/api/files/${storagePath}`;
    console.log(`[StorageHelper] Saved to disk → ${localPath}`);
    console.log(`[StorageHelper] Serving at    → ${url}`);
    return url;
}

module.exports = { uploadFile, UPLOAD_DIR };
