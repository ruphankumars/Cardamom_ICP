/**
 * Dispatch Documents Module — Firebase Firestore + Storage Backend
 * Handles LR + Bill photo capture, Firebase Storage upload, WhatsApp send via Meta Cloud API.
 * Server-side document enhancement with Jimp + PDF output.
 */
const { Router } = require('express');
const { getDb, getStorage } = require('../firebaseClient');
const axios = require('axios');
const { Jimp } = require('jimp');
const PDFDocument = require('pdfkit');
const pushNotifications = require('./push_notifications_fb');

const { getClientContact } = require('./client_contacts_fb');

const router = Router();
const COL = 'dispatch_documents';
function col() { return getDb().collection(COL); }

// ── Meta SYGT WABA templates for +916006560069 (DOCUMENT header) ──
const SYGT_DISPATCH_TEMPLATES = {
    espl: 'transport_document_pdf_v3_hxf9e4443a46fd05f9b2544a989e8ef9a0',
    sygt: 'transport_document_pdf_sygt_v1_hx145af8d7ec8c6c44116d3dc20cb023e1',
};

// ── Meta ESPL WABA templates for +919790005649 (DOCUMENT header) ──
const ESPL_DISPATCH_TEMPLATES = {
    espl: 'transport_document_espl_v1',
    sygt: 'transport_document_sygt_v1',
};

// ── Storage helper with automatic Firebase → Render disk fallback ──
const { uploadFile: uploadToFirebaseStorage } = require('../utils/storageHelper');

// ── Helper: pass-through raw camera bytes — zero re-encoding for lossless quality ──
async function enhanceImage(rawBuffer) {
    return rawBuffer;
}

// ── Helper: generate thumbnail from already-enhanced buffer (Jimp) ──
async function generateThumbnail(enhancedBuffer) {
    const image = await Jimp.read(enhancedBuffer);
    image.resize({ w: 400 });
    return Buffer.from(await image.getBuffer('image/jpeg', { quality: 60 }));
}

// ── Helper: wrap one or more images into a multi-page PDF ──
async function wrapImagesInPdf(jpegBuffers) {
    const buffers = Array.isArray(jpegBuffers) ? jpegBuffers : [jpegBuffers];
    const A4_W = 595, A4_H = 842;

    const doc = new PDFDocument({ size: [A4_W, A4_H], margin: 0, autoFirstPage: false });
    const chunks = [];
    doc.on('data', chunk => chunks.push(chunk));

    for (const buf of buffers) {
        const image = await Jimp.read(buf);
        const scale = Math.min(A4_W / image.width, A4_H / image.height);
        const pageW = Math.round(image.width * scale);
        const pageH = Math.round(image.height * scale);
        doc.addPage({ size: [pageW, pageH], margin: 0 });
        doc.image(buf, 0, 0, { width: pageW, height: pageH });
    }

    return new Promise((resolve, reject) => {
        doc.on('end', () => resolve(Buffer.concat(chunks)));
        doc.on('error', reject);
        doc.end();
    });
}


// ── Helper: send WhatsApp via Meta Cloud API (SYGT + ESPL) with DOCUMENT template ──
// Uses approved template messages (not direct messages) so they work with coexistence mode
async function sendWhatsAppMeta(imageBuffer, phones, clientName, pdfBuffer, pdfFilename, companyName) {
    const META_WA_TOKEN = process.env.META_WHATSAPP_TOKEN;
    const META_ESPL_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;
    const META_ESPL_NUMBER = '919790005649';
    if (!META_WA_TOKEN || !META_ESPL_PHONE_ID) return { results: [] };

    const FormData = require('form-data');
    const cn = (companyName || '').toLowerCase();
    const isESPL = cn === 'espl' || cn.includes('emperor');
    // Use ESPL WABA for both — SYGT media upload is blocked by Meta
    const templateName = isESPL ? ESPL_DISPATCH_TEMPLATES.espl : ESPL_DISPATCH_TEMPLATES.sygt;

    // Upload PDF once to ESPL WABA
    const hasPdf = pdfBuffer && pdfBuffer.length > 0;
    let mediaId = null;
    try {
        const form = new FormData();
        form.append('messaging_product', 'whatsapp');
        form.append('type', 'application/pdf');
        form.append('file', hasPdf ? pdfBuffer : imageBuffer, {
            filename: pdfFilename || `dispatch_${Date.now()}.pdf`,
            contentType: hasPdf ? 'application/pdf' : 'image/jpeg',
        });
        const up = await axios.post(
            `https://graph.facebook.com/v22.0/${META_ESPL_PHONE_ID}/media`,
            form,
            { headers: { ...form.getHeaders(), Authorization: `Bearer ${META_WA_TOKEN}` }, timeout: 15000 }
        );
        mediaId = up.data.id;
        console.log(`[DispatchDocs][ESPL] PDF uploaded: ${mediaId}`);
    } catch (err) {
        console.error(`[DispatchDocs][ESPL] Media upload failed: ${err.response?.data ? JSON.stringify(err.response.data) : err.message}`);
        return { results: [] };
    }

    const sendToPhone = async (phone) => {
        let clean = String(phone).replace(/\D/g, '');
        if (clean.length === 10) clean = `91${clean}`;
        // Allow self-send — coexistence template messages work to own number

        try {
            const r = await axios.post(
                `https://graph.facebook.com/v22.0/${META_ESPL_PHONE_ID}/messages`,
                {
                    messaging_product: 'whatsapp', to: clean, type: 'template',
                    template: {
                        name: templateName, language: { code: 'en' },
                        components: [
                            { type: 'header', parameters: [{ type: 'document', document: { id: mediaId, filename: pdfFilename || 'dispatch.pdf' } }] },
                            { type: 'body', parameters: [{ type: 'text', text: clientName || 'Customer' }] },
                        ]
                    }
                },
                { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
            );
            const wamid = r.data?.messages?.[0]?.id || '';
            console.log(`[DispatchDocs][ESPL] ✓ +${clean} (${templateName}): ${wamid}`);
            return { phone: `+${clean}`, success: true, messageId: wamid, method: 'meta-espl' };
        } catch (err) {
            console.error(`[DispatchDocs][ESPL] ✗ +${clean}: ${err.response?.data ? JSON.stringify(err.response.data) : err.message}`);
            return { phone: `+${clean}`, success: false, error: err.message };
        }
    };

    const settled = await Promise.allSettled(phones.map(p => sendToPhone(p)));
    return { results: settled.map(s => s.status === 'fulfilled' ? s.value : { success: false, error: s.reason?.message }) };
}

// ══════════════════════════════════════════════════════════════════════════════
// ROUTES
// ══════════════════════════════════════════════════════════════════════════════

// POST / — Create dispatch document (enhance + PDF + upload + send WhatsApp + store)
router.post('/', async (req, res) => {
    const memBefore = process.memoryUsage();
    console.log(`[DispatchDocs] POST / — heap: ${Math.round(memBefore.heapUsed/1024/1024)}MB / ${Math.round(memBefore.heapTotal/1024/1024)}MB, rss: ${Math.round(memBefore.rss/1024/1024)}MB`);
    try {
        const { imageBase64, imagesBase64, clientName, date, companyName, notes, lrNumber, invoiceNumber, invoiceDate, linkedOrderIds, linkedOrders, phones, createdBy } = req.body;
        // Support both single imageBase64 (legacy) and imagesBase64 array (multi-image)
        const imagesList = Array.isArray(imagesBase64) && imagesBase64.length > 0
            ? imagesBase64
            : (imageBase64 ? [imageBase64] : []);
        if (imagesList.length === 0 || !clientName || !date) {
            return res.status(400).json({ success: false, error: 'imageBase64 or imagesBase64, clientName, and date are required' });
        }
        // Auto-fetch phones from client_contacts if app didn't provide them (race condition fix)
        let targetPhones = Array.isArray(phones) && phones.length > 0 ? phones : [];
        if (targetPhones.length === 0 && clientName) {
            try {
                const contact = await getClientContact(clientName);
                if (contact && contact.phones && contact.phones.length > 0) {
                    targetPhones = contact.phones;
                    console.log(`[DispatchDocs] Auto-fetched ${targetPhones.length} phone(s) for "${clientName}" from client_contacts`);
                } else {
                    console.log(`[DispatchDocs] No phones found in client_contacts for "${clientName}"`);
                }
            } catch (err) {
                console.error(`[DispatchDocs] Failed to fetch client phones: ${err.message}`);
            }
        }

        const id = `DD-${Date.now()}`;
        const now = new Date().toISOString();
        const rawBuffers = imagesList.map(b64 => Buffer.from(b64, 'base64'));
        console.log(`[DispatchDocs] ${id}: ${rawBuffers.length} images, sizes: ${rawBuffers.map(b => Math.round(b.length/1024)+'KB').join(', ')}, client: ${clientName}`);
        const safeClient = (clientName || 'unknown').replace(/[^a-zA-Z0-9_-]/g, '_');
        const ts = Date.now();
        const cn = (companyName || '').toLowerCase();
        const safeCompany = (cn === 'espl' || cn.includes('emperor')) ? 'ESPL' : 'SYGT';
        const safeInvoice = (invoiceNumber || '').replace(/[/]/g, '-').replace(/[^a-zA-Z0-9\-]/g, '');

        // Format date as DDMMMYYYY (e.g. "09MAR2026")
        const MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
        let dateTag = '';
        try {
            const d = new Date(date);
            if (!isNaN(d.getTime())) {
                const dd = String(d.getDate()).padStart(2, '0');
                const mmm = MONTHS[d.getMonth()];
                const yyyy = d.getFullYear();
                dateTag = `${dd}${mmm}${yyyy}`;
            }
        } catch (_) { }
        if (!dateTag) dateTag = (date || '').replace(/\s+/g, '').toUpperCase();

        // 1. Enhance all images (pass-through keeps original quality)
        console.log(`[DispatchDocs] Preparing ${rawBuffers.length} image(s)...`);
        const enhancedBuffers = await Promise.all(rawBuffers.map(b => enhanceImage(b)));
        const enhancedBuffer = enhancedBuffers[0]; // first image for thumbnail
        console.log(`[DispatchDocs] Prepared ${enhancedBuffers.length} images (first: ${Math.round(enhancedBuffer.length / 1024)}KB)`);

        // 2. Generate thumbnail from first image + multi-page PDF from all images
        const [thumbBuffer, pdfBuffer] = await Promise.all([
            generateThumbnail(enhancedBuffer),
            wrapImagesInPdf(enhancedBuffers),
        ]);
        console.log(`[DispatchDocs] PDF (${enhancedBuffers.length} pages): ${Math.round(pdfBuffer.length / 1024)}KB`);

        // 3. Upload all images + thumbnail + PDF to Firebase Storage
        const pdfFileName = safeInvoice ? `${safeCompany}-${dateTag}-${safeInvoice}.pdf` : `${safeCompany}-${dateTag}-${ts}.pdf`;
        const imageUploadPromises = enhancedBuffers.map((buf, i) =>
            uploadToFirebaseStorage(buf, `dispatch-documents/${safeClient}/${date}_${ts}_${i}.jpg`, 'image/jpeg')
        );
        const [thumbnailUrl, pdfUrl, ...imageUrls] = await Promise.all([
            uploadToFirebaseStorage(thumbBuffer, `dispatch-documents/${safeClient}/thumb_${date}_${ts}.jpg`, 'image/jpeg'),
            uploadToFirebaseStorage(pdfBuffer, `dispatch-documents/${safeClient}/${pdfFileName}`, 'application/pdf'),
            ...imageUploadPromises,
        ]);
        const imageUrl = imageUrls.length > 0 ? imageUrls[0] : (thumbnailUrl || ''); // backward compat — first image

        // 4. Send via Meta Cloud API (SYGT + ESPL) — non-fatal
        let sendResults = { results: [] };
        if (targetPhones.length > 0) {
            try {
                sendResults = await sendWhatsAppMeta(enhancedBuffer, targetPhones, clientName, pdfBuffer, pdfFileName, companyName);
            } catch (err) {
                console.error(`[DispatchDocs] WhatsApp send failed: ${err.message}`);
            }
        }

        const sentPhoneSet = new Set((sendResults.results || []).filter(r => r.success).map(r => r.phone));
        const sentPhones = [...sentPhoneSet];

        // 5. Build WhatsApp status
        const allResults = sendResults.results || [];
        const successResults = allResults.filter(r => r.success);
        const failedResults = allResults.filter(r => !r.success);
        const whatsappStatus = targetPhones.length === 0 ? 'no_phones'
            : successResults.length === targetPhones.length ? 'sent'
            : successResults.length > 0 ? 'partial'
            : 'failed';

        // 6. Store in Firestore
        const doc = {
            id,
            clientName: clientName || '',
            date: date || '',
            companyName: companyName || 'SYGT',
            imageUrl,
            imageUrls: imageUrls || [],
            imageCount: imageUrls.length,
            thumbnailUrl,
            pdfUrl,
            linkedOrderIds: Array.isArray(linkedOrderIds) ? linkedOrderIds : [],
            linkedOrders: Array.isArray(linkedOrders) ? linkedOrders : [],
            lrNumber: lrNumber || '',
            invoiceNumber: invoiceNumber || '',
            invoiceDate: invoiceDate || '',
            notes: notes || '',
            phones: targetPhones,
            sentToPhones: sentPhones,
            whatsappStatus,
            whatsappResults: allResults.map(r => ({
                phone: r.phone || '',
                success: !!r.success,
                messageId: r.messageId || '',
                error: r.error || '',
            })),
            sentAt: successResults.length > 0 ? now : '',
            createdAt: now,
            createdBy: createdBy || req.headers['x-user'] || '',
            isDeleted: false,
        };
        await col().doc(id).set(doc);

        console.log(`[DispatchDocs] Created ${id} for ${clientName}, WA status: ${whatsappStatus} (${sentPhones.length}/${targetPhones.length})`);

        // 7. Notify superadmin (non-fatal — fire and forget)
        pushNotifications.notifyDispatchDocSent({
            companyName, clientName, invoiceNumber,
            createdBy: createdBy || req.headers['x-user'] || '',
        }).catch(err => console.error('[DispatchDocs] Push notification error:', err.message));

        res.json({
            success: true,
            document: doc,
            whatsappStatus,
            whatsappResults: allResults,
            sentCount: sentPhones.length,
            totalCount: targetPhones.length,
        });
    } catch (err) {
        console.error('[DispatchDocs] Create error:', err.message, err.stack);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET / — List dispatch documents with filters
router.get('/', async (req, res) => {
    try {
        const { clientName, dateFrom, dateTo, companyName, limit: limitStr } = req.query;
        const limit = Math.max(1, Math.min(parseInt(limitStr) || 50, 200));

        let query = col().where('isDeleted', '==', false);
        if (clientName) query = query.where('clientName', '==', clientName);
        if (companyName) query = query.where('companyName', '==', companyName);
        query = query.orderBy('createdAt', 'desc').limit(limit);

        const snap = await query.get();
        let docs = snap.docs.map(d => ({ id: d.id, ...d.data() }));

        // Client-side date range filter (Firestore can't combine inequality on different fields)
        if (dateFrom) docs = docs.filter(d => d.date >= dateFrom);
        if (dateTo) docs = docs.filter(d => d.date <= dateTo);

        res.json({ success: true, documents: docs, count: docs.length });
    } catch (err) {
        console.error('[DispatchDocs] List error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /:id — Get single dispatch document
router.get('/:id', async (req, res) => {
    try {
        const snap = await col().doc(req.params.id).get();
        if (!snap.exists) return res.status(404).json({ success: false, error: 'Not found' });
        res.json({ success: true, document: { id: snap.id, ...snap.data() } });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// PUT /:id — Update notes and linkedOrderIds
router.put('/:id', async (req, res) => {
    try {
        const { notes, linkedOrderIds, lrNumber } = req.body;
        const updates = {};
        if (notes !== undefined) updates.notes = notes;
        if (lrNumber !== undefined) updates.lrNumber = lrNumber;
        if (linkedOrderIds !== undefined) updates.linkedOrderIds = Array.isArray(linkedOrderIds) ? linkedOrderIds : [];
        updates.updatedAt = new Date().toISOString();

        await col().doc(req.params.id).update(updates);
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// DELETE /:id — Soft delete
router.delete('/:id', async (req, res) => {
    try {
        await col().doc(req.params.id).update({ isDeleted: true, updatedAt: new Date().toISOString() });
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /:id/resend — Resend enhanced image to WhatsApp
router.post('/:id/resend', async (req, res) => {
    try {
        let { phones } = req.body;

        const snap = await col().doc(req.params.id).get();
        if (!snap.exists) return res.status(404).json({ success: false, error: 'Not found' });
        const doc = snap.data();

        // Auto-fetch phones from client_contacts if not provided
        if (!Array.isArray(phones) || phones.length === 0) {
            try {
                const contact = await getClientContact(doc.clientName);
                if (contact && contact.phones && contact.phones.length > 0) {
                    phones = contact.phones;
                    console.log(`[DispatchDocs] Resend: auto-fetched ${phones.length} phone(s) for "${doc.clientName}"`);
                }
            } catch (_) {}
        }
        if (!Array.isArray(phones) || phones.length === 0) {
            return res.status(400).json({ success: false, error: 'No phones found for this client' });
        }

        // Use Firebase Storage PDF URL directly (public). For legacy docs without pdfUrl,
        // download the JPEG, wrap in PDF, upload to Firebase Storage, then send.
        let mediaUrl = doc.pdfUrl;
        if (!mediaUrl) {
            try {
                const imageResp = await axios.get(doc.imageUrl, { responseType: 'arraybuffer', timeout: 15000 });
                const pdfBuffer = await wrapImageInPdf(Buffer.from(imageResp.data));
                const safeClient = (doc.clientName || 'unknown').replace(/[^a-zA-Z0-9_-]/g, '_');
                mediaUrl = await uploadToFirebaseStorage(pdfBuffer, `dispatch-documents/${safeClient}/resend_${Date.now()}.pdf`, 'application/pdf');
            } catch (pdfErr) {
                console.warn(`[DispatchDocs] Resend PDF generation failed, using image URL: ${pdfErr.message}`);
                mediaUrl = doc.imageUrl;
            }
        }

        // Send via Meta Cloud API (SYGT + ESPL) in parallel
        // Download image and PDF for resend
        let imgBuf = null;
        let resendPdfBuf = null;
        try {
            const imgResp = await axios.get(doc.imageUrl, { responseType: 'arraybuffer', timeout: 10000 });
            imgBuf = Buffer.from(imgResp.data);
        } catch (_) { /* send will be skipped if download fails */ }
        if (doc.pdfUrl) {
            try {
                const pdfResp = await axios.get(doc.pdfUrl, { responseType: 'arraybuffer', timeout: 15000 });
                resendPdfBuf = Buffer.from(pdfResp.data);
            } catch (_) { /* fallback to image if PDF download fails */ }
        }
        // Build PDF filename from stored doc metadata
        const cn = (doc.companyName || '').toLowerCase();
        const resendCompany = (cn === 'espl' || cn.includes('emperor')) ? 'ESPL' : 'SYGT';
        const resendInvoice = (doc.invoiceNumber || '').replace(/[/]/g, '-').replace(/[^a-zA-Z0-9\-]/g, '');
        const resendFilename = resendInvoice ? `${resendCompany}-${resendInvoice}.pdf` : `${resendCompany}-dispatch.pdf`;

        let resendResults = { results: [] };
        try {
            if (imgBuf) {
                resendResults = await sendWhatsAppMeta(imgBuf, phones, doc.clientName, resendPdfBuf, resendFilename, doc.companyName);
            }
        } catch (err) {
            console.error(`[DispatchDocs] Resend WhatsApp failed: ${err.message}`);
        }
        const allResendResults = resendResults.results || [];
        const sentSet = new Set(allResendResults.filter(r => r.success).map(r => r.phone));
        const newSentPhones = [...sentSet];

        // Update Firestore with resend results
        const admin = require('firebase-admin');
        const resendStatus = newSentPhones.length === phones.length ? 'sent'
            : newSentPhones.length > 0 ? 'partial' : 'failed';
        const updateData = {
            updatedAt: new Date().toISOString(),
            whatsappStatus: resendStatus,
            whatsappResults: allResendResults.map(r => ({
                phone: r.phone || '',
                success: !!r.success,
                messageId: r.messageId || '',
                error: r.error || '',
            })),
        };
        if (newSentPhones.length > 0) {
            updateData.sentAt = new Date().toISOString();
            updateData.sentToPhones = admin.firestore.FieldValue.arrayUnion(...newSentPhones);
        }
        await col().doc(req.params.id).update(updateData);

        console.log(`[DispatchDocs] Resent ${req.params.id}, WA status: ${resendStatus} (${newSentPhones.length}/${phones.length})`);
        res.json({ success: true, whatsappStatus: resendStatus, results: allResendResults, sentCount: newSentPhones.length });
    } catch (err) {
        console.error('[DispatchDocs] Resend error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /for-orders — Check which packed orders have linked dispatch documents
router.post('/for-orders', async (req, res) => {
    try {
        const { orderIds } = req.body;
        if (!Array.isArray(orderIds) || orderIds.length === 0) {
            return res.json({ success: true, orderDocumentMap: {} });
        }

        // Limit to recent 90 days to avoid scanning entire collection
        const ninetyDaysAgo = new Date(Date.now() - 90 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
        const snap = await col()
            .where('isDeleted', '==', false)
            .where('date', '>=', ninetyDaysAgo)
            .orderBy('date', 'desc')
            .limit(500)
            .get();
        const orderDocumentMap = {};
        const orderIdSet = new Set(orderIds); // O(1) lookup instead of Array.includes O(n)
        snap.docs.forEach(d => {
            const data = d.data();
            if (Array.isArray(data.linkedOrderIds)) {
                data.linkedOrderIds.forEach(orderId => {
                    if (orderIdSet.has(orderId)) {
                        orderDocumentMap[orderId] = data.id;
                    }
                });
            }
        });

        res.json({ success: true, orderDocumentMap });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// ══════════════════════════════════════════════════════════════════════════════
// SERVER-SIDE OCR — Multi-strategy: Cloud Vision → Tesseract.js
// Fallback when on-device ML Kit returns empty on iOS
// ══════════════════════════════════════════════════════════════════════════════

/**
 * POST /ocr — Run OCR on a base64 image.
 * Strategy: Try Google Cloud Vision first, fallback to Tesseract.js.
 *
 * Body: { imageBase64: string, clientNames?: string[] }
 * Response: { success, text, blocks[], lrNumber?, company?, client?, engine }
 */
router.post('/ocr', async (req, res) => {
    try {
        const { imageBase64, clientNames } = req.body;
        if (!imageBase64) {
            return res.status(400).json({ success: false, error: 'imageBase64 is required' });
        }

        const imageKB = Math.round(imageBase64.length * 3 / 4 / 1024);
        console.log(`[OCR-Server] Received image (${imageKB}KB)`);

        let fullText = '';
        let blocks = [];
        let engine = 'none';

        // ── Strategy 1: Google Cloud Vision API (best accuracy) ──
        try {
            const admin = require('firebase-admin');
            const app = admin.app();
            const credential = app.options.credential;
            const token = await credential.getAccessToken();

            const visionResp = await axios.post(
                'https://vision.googleapis.com/v1/images:annotate',
                {
                    requests: [{
                        image: { content: imageBase64 },
                        features: [{ type: 'DOCUMENT_TEXT_DETECTION', maxResults: 1 }],
                        imageContext: { languageHints: ['en', 'hi'] },
                    }],
                },
                {
                    headers: { 'Authorization': `Bearer ${token.access_token}`, 'Content-Type': 'application/json' },
                    timeout: 30000,
                }
            );

            const annotation = visionResp.data?.responses?.[0];
            if (!annotation?.error) {
                fullText = annotation?.fullTextAnnotation?.text || '';
                blocks = (annotation?.textAnnotations || []).slice(1).map(a => a.description);
                engine = 'cloud-vision';
                console.log(`[OCR-Server] Cloud Vision: ${fullText.length} chars`);
            } else {
                console.warn('[OCR-Server] Cloud Vision error:', annotation.error.message);
            }
        } catch (visionErr) {
            const status = visionErr.response?.status;
            const msg = visionErr.response?.data?.error?.message || visionErr.message;
            console.warn(`[OCR-Server] Cloud Vision failed (${status}): ${msg?.substring(0, 100)}`);
        }

        // ── Strategy 2: Tesseract.js with Sharp preprocessing ──
        if (!fullText) {
            try {
                console.log('[OCR-Server] Falling back to Tesseract.js with image preprocessing...');
                const sharp = require('sharp');
                const { createWorker } = require('tesseract.js');

                const rawBuffer = Buffer.from(imageBase64, 'base64');

                // Preprocess: grayscale → normalize contrast → sharpen → threshold for clean B&W
                let processedBuffer;
                try {
                    processedBuffer = await sharp(rawBuffer)
                        .rotate()          // Auto-rotate based on EXIF orientation
                        .grayscale()       // Convert to grayscale for better OCR
                        .normalize()       // Stretch contrast to full range
                        .sharpen({ sigma: 1.5 })  // Sharpen text edges
                        .threshold(140)    // Binarize: clean black text on white background
                        .png()             // Output as PNG for Tesseract
                        .toBuffer();
                    console.log(`[OCR-Server] Preprocessed image: ${rawBuffer.length} → ${processedBuffer.length} bytes`);
                } catch (sharpErr) {
                    console.warn('[OCR-Server] Sharp preprocessing failed, using raw image:', sharpErr.message);
                    processedBuffer = rawBuffer;
                }

                const worker = await createWorker('eng');
                const { data } = await worker.recognize(processedBuffer);
                fullText = data.text || '';
                blocks = (data.lines || []).map(l => l.text).filter(Boolean);
                engine = 'tesseract';
                await worker.terminate();
                console.log(`[OCR-Server] Tesseract: ${fullText.length} chars, ${blocks.length} lines`);
            } catch (tessErr) {
                console.error('[OCR-Server] Tesseract failed:', tessErr.message);
            }
        }

        if (fullText.length > 0) {
            console.log(`[OCR-Server] Preview (${engine}): ${fullText.substring(0, 200).replace(/\n/g, ' | ')}`);
        }

        // ── Auto-detect fields from OCR text ──
        const result = { success: true, text: fullText, blocks, engine };
        result.lrNumber = _extractLrNumber(fullText);
        result.company = _extractCompany(fullText);
        result.invoiceNumber = _extractInvoiceNumber(fullText);
        result.invoiceDate = _extractInvoiceDate(fullText);
        if (Array.isArray(clientNames) && clientNames.length > 0) {
            result.client = _extractClient(fullText, clientNames);
        }

        console.log(`[OCR-Server] Detected (${engine}): LR=${result.lrNumber || 'none'}, Company=${result.company || 'none'}, Invoice=${result.invoiceNumber || 'none'}, InvDate=${result.invoiceDate || 'none'}, Client=${result.client || 'none'}`);
        res.json(result);

    } catch (err) {
        console.error('[OCR-Server] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ── Server-side OCR text extraction helpers ──

function _extractLrNumber(text) {
    if (!text) return null;
    // Common words that appear after labels but are NOT LR numbers
    const blocklist = new Set([
        'date', 'name', 'address', 'phone', 'number', 'amount', 'weight',
        'value', 'type', 'mode', 'from', 'city', 'state', 'paid', 'topay',
        'freight', 'charges', 'total', 'party', 'goods', 'said', 'risk',
        'owner', 'carrier', 'consignor', 'consignee', 'booking', 'delivery',
        'destination', 'origin', 'service', 'received', 'private', 'limited',
    ]);

    // Pattern 1: Explicit labels
    const labelPatterns = [
        /(?:LR|L\.R\.|Consignment|CN|Docket|AWB|Tracking|GC\s*Note)\s*(?:No\.?|Number|#)\s*[:\-]?\s*([A-Z0-9][\w\-\/]{3,20})/i,
        /(?:Way\s*Bill|Air\s*Bill|Booking)\s*(?:No\.?|Number|#)\s*[:\-]?\s*([A-Z0-9][\w\-\/]{3,20})/i,
    ];
    for (const re of labelPatterns) {
        const m = text.match(re);
        if (m) {
            const val = m[1].trim();
            // Must contain at least one digit and not be a common word
            if (/\d/.test(val) && !blocklist.has(val.toLowerCase())) return val;
        }
    }
    // Pattern 2: Standalone alphanumeric near transport keywords
    const transportKeywords = /(?:DTDC|Express|Courier|Transport|Logistics|Cargo|Professional|Gati|Delhivery|BlueDart|Safe[\s]?Express)/i;
    if (transportKeywords.test(text)) {
        const codeMatch = text.match(/\b([A-Z]\d{8,14})\b/);
        if (codeMatch) return codeMatch[1];
        const numericMatch = text.match(/\b(\d{10,15})\b/);
        if (numericMatch) return numericMatch[1];
    }
    return null;
}

function _extractCompany(text) {
    if (!text) return null;
    const lower = text.toLowerCase();
    // ESPL patterns
    const esplPatterns = ['emperor spices', 'emperor spice', 'emperior spices', 'emp spices',
        'e.s.p.l', 'espl', 'e s p l', 'emperior', 'emporor', 'emperer', 'emp. spices'];
    for (const p of esplPatterns) {
        if (lower.includes(p)) return 'ESPL';
    }
    if (/emp[ei]r[oe]r[\s\S]{0,20}spice/i.test(text)) return 'ESPL';

    // SYGT patterns
    const sygtPatterns = ['yoga ganapathi', 'yogaganapath', 'sri yoga', 's.y.g.t', 'sygt',
        's y g t', 'yogagnapathi', 'yogaganapati', 'ganapathi traders'];
    for (const p of sygtPatterns) {
        if (lower.includes(p)) return 'SYGT';
    }
    if (/yoga[\s\S]{0,20}ganap/i.test(text)) return 'SYGT';

    return null;
}

function _extractInvoiceNumber(text) {
    if (!text) return null;
    // Pattern 1: "Invoice No." / "Inv No." followed by number (optionally with /year)
    const p1 = text.match(/(?:Invoice|Inv\.?)\s*(?:No\.?|Number|#)\s*[:\-]?\s*(\d+(?:\/\d{4}[-–]\d{2})?)/i);
    if (p1) return p1[1];
    // Pattern 2: "Bill No."
    const p2 = text.match(/Bill\s*(?:No\.?|Number)\s*[:\-]?\s*(\d+(?:\/\d{4}[-–]\d{2})?)/i);
    if (p2) return p2[1];
    // Pattern 3: "Voucher No."
    const p3 = text.match(/Voucher\s*(?:No\.?|Number)\s*[:\-]?\s*(\d+(?:\/\d{4}[-–]\d{2})?)/i);
    if (p3) return p3[1];
    return null;
}

function _extractInvoiceDate(text) {
    if (!text) return null;
    const months = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };
    // Pattern 1: "Dated DD-Mon-YY"
    const p1 = text.match(/Dated\s+(\d{1,2})\s*[-\s]\s*([A-Za-z]{3})\s*[-\s]\s*(\d{2,4})/i);
    if (p1) { const d = _parseOcrDate(p1[1], p1[2], p1[3], months); if (d) return d; }
    // Pattern 2: "dt. DD-Mon-YY"
    const p2 = text.match(/dt\.\s*(\d{1,2})\s*[-\s]\s*([A-Za-z]{3})\s*[-\s]\s*(\d{2,4})/i);
    if (p2) { const d = _parseOcrDate(p2[1], p2[2], p2[3], months); if (d) return d; }
    // Pattern 3: "Date: DD-Mon-YY" or "Date: DD/MM/YYYY"
    const p3 = text.match(/(?:Inv(?:oice)?\s*)?Date\s*[:\-]?\s*(\d{1,2})\s*[-/\s]\s*([A-Za-z]{3}|\d{1,2})\s*[-/\s]\s*(\d{2,4})/i);
    if (p3) { const d = _parseOcrDate(p3[1], p3[2], p3[3], months); if (d) return d; }
    return null;
}

function _parseOcrDate(dayStr, monthStr, yearStr, months) {
    try {
        const day = parseInt(dayStr, 10);
        let month;
        if (/^\d+$/.test(monthStr)) {
            month = parseInt(monthStr, 10);
        } else {
            month = months[monthStr.toLowerCase()] || 0;
        }
        let year = parseInt(yearStr, 10);
        if (year < 100) year += 2000;
        if (month < 1 || month > 12 || day < 1 || day > 31) return null;
        // Return ISO date string YYYY-MM-DD
        return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
    } catch (_) {
        return null;
    }
}

function _extractClient(text, clientNames) {
    if (!text || !clientNames || clientNames.length === 0) return null;

    const commonWords = new Set([
        'the', 'and', 'pvt', 'ltd', 'private', 'limited', 'traders', 'trading', 'trader',
        'enterprise', 'enterprises', 'industries', 'company', 'group', 'co',
        'inc', 'corp', 'llc', 'llp', 'sons', 'brothers', 'bros', 'associates',
        'international', 'india', 'spice', 'spices', 'foods', 'food',
        'exports', 'imports', 'general', 'new', 'sri', 'shri', 'sree', 'shree',
    ]);
    const cityWords = new Set([
        'delhi', 'mumbai', 'chennai', 'kolkata', 'bangalore', 'hyderabad',
        'pune', 'ahmedabad', 'jaipur', 'lucknow', 'kanpur', 'nagpur',
        'indore', 'thane', 'bhopal', 'patna', 'vadodara', 'ghaziabad',
        'ludhiana', 'agra', 'nashik', 'rajkot', 'varanasi', 'surat',
        'coimbatore', 'vijayawada', 'madurai', 'jalna', 'jodhpur', 'raipur',
        'kochi', 'chandigarh', 'guwahati', 'mangalore', 'dibrugarh',
    ]);
    const ownCompany = ['emperor spices', 'yogaganapathi', 'espl', 'sygt'];
    const logisticsNoise = [
        'delhivery', 'bluedart', 'blue dart', 'spoton', 'spot on',
        'gati', 'dtdc', 'professional couriers', 'safe express',
        'safexpress', 'vrl logistics', 'tci express', 'xpressbees',
        'ecom express', 'trackon', 'shree maruti', 'first flight',
    ];

    // ── Strategy 1: Extract "Bill To" / "Ship To" from Tally invoice ──
    // Tally uses formats like "Buyer (Bill to)" and "Consignee (Ship to)"
    // The (?:\([^)]*\))? skips the optional parenthetical qualifier
    const sectionPatterns = [
        /Buyer\s*(?:\([^)]*\))?\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|State|Code|Phone|Place|Shop|Ship|Deliver|Description|Sl\.?\s*No|S\.?\s*No|Particulars|HSN)|$)/is,
        /Consignee\s*(?:\([^)]*\))?\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|State|Code|Phone|Place|Shop|Bill|Description|Sl\.?\s*No|S\.?\s*No|Particulars|HSN)|$)/is,
        /Bill(?:ed)?\s*To\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|State|Code|Phone|Place|Shop|Ship|Deliver|Description|Sl\.?\s*No|S\.?\s*No|Particulars|HSN)|$)/is,
        /(?:Ship(?:ped)?\s*To|Deliver(?:y|ed)?\s*To)\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|State|Code|Phone|Place|Shop|Bill|Description|Sl\.?\s*No|S\.?\s*No|Particulars|HSN)|$)/is,
        /Receiver\s*[:\-]?\s*\n?\s*(.+?)(?:\n\s*(?:GSTIN|GST|Phone|Address|From|Consignor|Description)|$)/is,
        /To\s*[:\-]?\s*M\/s\.?\s*(.+?)(?:\n\s*(?:GSTIN|GST|Phone|Address)|$)/is,
    ];
    for (const re of sectionPatterns) {
        const m = text.match(re);
        if (!m) continue;
        const rawSection = m[1].trim();
        if (!rawSection || rawSection.length < 3) continue;
        // Use first line (client name) + city words from subsequent lines.
        // Don't include full address lines — street names like "SUBASH MARG"
        // cause false matches with clients like "Subash Trading Co".
        const allLines = rawSection.split('\n').map(l => l.trim()).filter(Boolean);
        let section = (allLines[0] || '').toLowerCase();
        // Append city-name words from lines 2-3 for tie-breaking only
        for (let li = 1; li < Math.min(allLines.length, 3); li++) {
            const lineWords = allLines[li].toLowerCase().split(/[\s,\-]+/).filter(w => w.length >= 3);
            for (const w of lineWords) {
                if (cityWords.has(w)) section += ' ' + w;
            }
        }
        // Skip own company
        if (ownCompany.some(c => section.includes(c))) continue;
        if (!/[a-zA-Z]/.test(section)) continue;

        console.log(`[OCR-Server] Bill To section: "${section}"`);
        // Match section against client names
        const sectionMatch = _matchClientAgainstSection(section, clientNames, ownCompany, commonWords, cityWords);
        if (sectionMatch) return sectionMatch;
    }

    // ── Strategy 2: Full-text matching with noise filtering ──
    let lower = text.toLowerCase();
    for (const noise of logisticsNoise) {
        lower = lower.replaceAll(noise, ' ');
    }

    // Direct substring match (longest match wins)
    let bestMatch = null;
    let bestLen = 0;
    for (const name of clientNames) {
        if (!name || name.length < 3) continue;
        const nameLower = name.toLowerCase();
        if (ownCompany.some(c => nameLower.includes(c) || c.includes(nameLower))) continue;
        if (lower.includes(nameLower) && name.length > bestLen) {
            bestMatch = name;
            bestLen = name.length;
        }
    }
    if (bestMatch) return bestMatch;

    // Word-level matching with word-boundary checks
    bestMatch = null;
    let bestScore = 0;
    for (const name of clientNames) {
        if (!name || name.length < 3) continue;
        const nameLower = name.toLowerCase();
        if (ownCompany.some(c => nameLower.includes(c) || c.includes(nameLower))) continue;
        const allWords = nameLower.split(/[\s&.,\-]+/).filter(w => w.length >= 3);
        const sigWords = allWords.filter(w => !commonWords.has(w) && !cityWords.has(w));
        const genWords = allWords.filter(w => commonWords.has(w));
        if (sigWords.length === 0 && genWords.length === 0) continue;

        if (sigWords.length > 0) {
            const matchedSig = sigWords.filter(w => _wordBoundaryMatch(lower, w)).length;
            if (matchedSig === sigWords.length) {
                // Absolute count bonus: more words = higher confidence
                const score = matchedSig * 50 + name.length;
                if (score > bestScore) { bestMatch = name; bestScore = score; }
            }
        } else if (genWords.length > 0) {
            // Generic-only client (e.g. "B.J Brothers")
            const matchedGen = genWords.filter(w => _wordBoundaryMatch(lower, w)).length;
            if (matchedGen > 0) {
                const prefix = nameLower.split(/\s+/)[0];
                // Use word boundary for prefix to avoid "om" matching inside "some"
                const prefixBoundary = prefix.length >= 2 && _wordBoundaryMatch(lower, prefix);
                const prefixSubstring = !prefixBoundary && prefix.length >= 3 && lower.includes(prefix);
                if (prefixBoundary || prefixSubstring) {
                    const score = matchedGen * 20 + (prefixBoundary ? 80 : 60) + name.length;
                    if (score > bestScore) { bestMatch = name; bestScore = score; }
                }
            }
        }
    }
    if (bestMatch) return bestMatch;

    return null;
}

/** Match client names against extracted Bill To / Ship To section text */
function _matchClientAgainstSection(section, clientNames, ownCompany, commonWords, cityWords) {
    const cleanedSection = section.toLowerCase().replace(/[|!@#$%^&*(){}\[\]<>~`]/g, '').replace(/\s+/g, ' ').trim();
    let bestMatch = null;
    let bestScore = 0;
    for (const name of clientNames) {
        if (!name || name.length < 3) continue;
        const nameLower = name.toLowerCase().trim();
        if (ownCompany.some(c => nameLower.includes(c) || c.includes(nameLower))) continue;

        // Strip city suffix: "Shree Vardhman Traders - Jalna" → "Shree Vardhman Traders"
        const dashIdx = nameLower.lastIndexOf(' - ');
        const clientCore = dashIdx > 0 ? nameLower.substring(0, dashIdx).trim() : nameLower;

        // Dot-stripped and compact versions for abbreviation matching
        const dotStrippedCore = clientCore.replace(/\./g, '');
        const dotStrippedName = nameLower.replace(/\./g, '');
        const dotStrippedSection = cleanedSection.replace(/\./g, '');
        const compactCore = clientCore.replace(/[.\s]/g, '');
        const compactSection = cleanedSection.replace(/[.\s]/g, '');

        // Exact substring match — with coverage-based scoring
        const fullMatch = cleanedSection.includes(nameLower) || dotStrippedSection.includes(dotStrippedName);
        // partMatch: check normal → dot-stripped → compact (for spaced abbreviations like "R N G")
        let partMatch = false;
        let viaCompact = false;
        if (!fullMatch && dashIdx > 0) {
            if (cleanedSection.includes(clientCore) || dotStrippedSection.includes(dotStrippedCore)) {
                partMatch = true;
            } else if (compactSection.includes(compactCore)) {
                partMatch = true;
                viaCompact = true;
            }
        }
        // Pick the right substring & denominator for coverage calculation
        let substringToCheck = null;
        let coverageDenom = cleanedSection.length;
        if (fullMatch) {
            substringToCheck = cleanedSection.includes(nameLower) ? nameLower : dotStrippedName;
        } else if (partMatch) {
            if (viaCompact) {
                substringToCheck = compactCore;
                coverageDenom = compactSection.length;
            } else {
                substringToCheck = cleanedSection.includes(clientCore) ? clientCore : dotStrippedCore;
            }
        }

        if (substringToCheck && coverageDenom > 0) {
            const coverage = substringToCheck.length / coverageDenom;
            if (coverage >= 0.25) {
                // Good coverage — meaningful substring match
                // Score: 200 base + coverage bonus + length bonus + city bonus
                let score = 200 + Math.round(coverage * 100) + name.length;
                // City tie-break
                const cityInClient = nameLower.split(/[\s&.,\-]+/).filter(w => cityWords.has(w));
                for (const cw of cityInClient) {
                    if (_wordBoundaryMatch(cleanedSection, cw)) score += 20;
                }
                if (score > bestScore) { bestMatch = name; bestScore = score; }
                continue;
            }
            // Low coverage — fall through to word-level matching
        }

        // Word-level matching
        const allWords = clientCore.split(/[\s&.,\-]+/).filter(w => w.length >= 3);
        const sigWords = allWords.filter(w => !commonWords.has(w) && !cityWords.has(w));
        const genWords = allWords.filter(w => commonWords.has(w));

        if (sigWords.length === 0 && genWords.length === 0) continue;

        let matchedExact = 0;
        let matchedFuzzy = 0;
        for (const w of sigWords) {
            if (_wordBoundaryMatch(cleanedSection, w)) {
                matchedExact++;
            } else if (w.length >= 4) {
                const sectionWords = cleanedSection.split(/\s+/);
                for (const sw of sectionWords) {
                    if (Math.abs(sw.length - w.length) <= 2 && _levenshtein(w, sw) <= 1) {
                        matchedFuzzy++; break;
                    }
                }
            }
        }

        let matchedGen = 0;
        for (const w of genWords) {
            if (_wordBoundaryMatch(cleanedSection, w)) matchedGen++;
        }

        if (sigWords.length > 0) {
            const totalMatched = matchedExact + matchedFuzzy;
            if (totalMatched === 0) continue;
            if (totalMatched < Math.ceil(sigWords.length / 2)) continue;
            // Score: absolute word count * 50 + exact bonus + generic bonus + length
            const score = totalMatched * 50 + matchedExact * 30 + (matchedGen > 0 ? 10 : 0) + name.length;
            if (score > bestScore) { bestMatch = name; bestScore = score; }
        } else if (genWords.length > 0 && matchedGen > 0) {
            // Generic-only client (e.g. "B.J Brothers")
            const prefix = clientCore.split(/\s+/)[0];
            // Use word boundary for prefix to avoid "om" matching inside "some"
            const prefixBoundary = prefix.length >= 2 && _wordBoundaryMatch(cleanedSection, prefix);
            const prefixSubstring = !prefixBoundary && prefix.length >= 3 && cleanedSection.includes(prefix);
            const score = matchedGen * 20 + (prefixBoundary ? 80 : prefixSubstring ? 60 : 0) + name.length;
            if (score > bestScore) { bestMatch = name; bestScore = score; }
        }
    }
    return bestMatch;
}

/** Check if word appears as whole word in text (not substring) */
function _wordBoundaryMatch(text, word) {
    if (!text.includes(word)) return false;
    const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return new RegExp(`(?:^|[\\s,;:\\-./])${escaped}(?:[\\s,;:\\-./]|$)`).test(text);
}

function _fuzzyMatch(text, target) {
    if (!text || !target) return false;
    if (text.includes(target) || target.includes(text)) return true;
    if (target.length >= 4 && target.length <= 30) {
        const dist = _levenshtein(text.substring(0, target.length + 5), target);
        if (dist <= Math.max(1, Math.floor(target.length / 5))) return true;
    }
    const targetWords = target.split(/\s+/).filter(w => w.length > 2);
    if (targetWords.length >= 2) {
        const matchCount = targetWords.filter(tw => _wordBoundaryMatch(text, tw)).length;
        if (matchCount >= targetWords.length - 1 && matchCount > 0) return true;
    }
    return false;
}

function _levenshtein(a, b) {
    const m = a.length, n = b.length;
    if (m === 0) return n;
    if (n === 0) return m;
    const dp = Array.from({ length: m + 1 }, () => Array(n + 1).fill(0));
    for (let i = 0; i <= m; i++) dp[i][0] = i;
    for (let j = 0; j <= n; j++) dp[0][j] = j;
    for (let i = 1; i <= m; i++) {
        for (let j = 1; j <= n; j++) {
            dp[i][j] = a[i - 1] === b[j - 1]
                ? dp[i - 1][j - 1]
                : 1 + Math.min(dp[i - 1][j - 1], dp[i - 1][j], dp[i][j - 1]);
        }
    }
    return dp[m][n];
}

// POST /migrate-wa-status — One-time backfill whatsappStatus for old documents
router.post('/migrate-wa-status', async (req, res) => {
    try {
        const snap = await col().where('isDeleted', '==', false).get();
        let updated = 0;
        const batch = getDb().batch();
        snap.docs.forEach(d => {
            const data = d.data();
            if (data.whatsappStatus) return; // already has status
            const sentTo = Array.isArray(data.sentToPhones) ? data.sentToPhones : [];
            const phones = Array.isArray(data.phones) ? data.phones : [];
            let status;
            if (sentTo.length > 0 && sentTo.length >= phones.length) status = 'sent';
            else if (sentTo.length > 0) status = 'partial';
            else if (phones.length > 0) status = 'failed';
            else status = 'no_phones';
            batch.update(d.ref, { whatsappStatus: status });
            updated++;
        });
        if (updated > 0) await batch.commit();
        res.json({ success: true, updated, total: snap.size });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = { router };
