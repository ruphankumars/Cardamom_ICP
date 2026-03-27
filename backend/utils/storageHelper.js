/**
 * Storage Helper — ICP Stub
 *
 * On ICP, there is no Firebase Storage or local filesystem.
 * Files must be handled in-memory (buffers) or uploaded to external CDN.
 * This stub returns null to signal that file storage is not available,
 * allowing callers to handle gracefully (e.g., return buffer directly).
 */

/**
 * Upload a buffer — stub for ICP.
 * Returns null since filesystem/Firebase Storage is not available on ICP.
 *
 * @param {Buffer} buffer       File contents
 * @param {string} storagePath  Path (unused on ICP)
 * @param {string} contentType  MIME type (unused on ICP)
 * @returns {Promise<string|null>} Always null on ICP
 */
async function uploadFile(buffer, storagePath, contentType) {
    console.warn(`[StorageHelper] File storage not available on ICP. Path: ${storagePath}`);
    return null;
}

module.exports = { uploadFile, UPLOAD_DIR: '/tmp' };
