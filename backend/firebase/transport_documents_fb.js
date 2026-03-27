/**
 * Transport Documents Module — Firebase Firestore + Storage Backend
 * Handles multi-image PDF upload to transports via WhatsApp (Meta Cloud API).
 */
const { Router } = require('express');
const { getDb, getStorage } = require('../firebaseClient');
const { Jimp } = require('jimp');
const PDFDocument = require('pdfkit');
const pushNotifications = require('./push_notifications_fb');

const router = Router();
const COL = 'transport_documents';
function col() { return getDb().collection(COL); }

// ── Meta SYGT WABA templates for +916006560069 (DOCUMENT header) ──
const SYGT_TRANSPORT_TEMPLATES = {
    espl: 'transport_document_pdf_v3_hxf9e4443a46fd05f9b2544a989e8ef9a0',
    sygt: 'transport_document_pdf_sygt_v1_hx145af8d7ec8c6c44116d3dc20cb023e1',
};

// ── Meta ESPL WABA templates for +919790005649 (DOCUMENT header) ──
const ESPL_TRANSPORT_TEMPLATES = {
    espl: 'transport_document_espl_v1',
    sygt: 'transport_document_sygt_v1',
};

// ── Storage helper with automatic Firebase → Render disk fallback ──
const { uploadFile: uploadToFirebaseStorage } = require('../utils/storageHelper');

// ── Helper: generate a JPEG preview from first page of PDF for WhatsApp template ──
// WhatsApp templates require image URLs — PDFs are rejected in media headers.
// We create a simple placeholder JPEG with transport name as text.
async function generatePreviewImage(transportName) {
    const image = new Jimp({ width: 600, height: 400, color: 0xFFFFFFFF });
    return Buffer.from(await image.getBuffer('image/jpeg', { quality: 80 }));
}

// ── Helper: send WhatsApp via Meta SYGT WABA (+916006560069) with DOCUMENT header ──
async function sendWhatsApp(pdfUrl, previewImageUrl, phones, transportName, caption, companyName) {
    const META_WA_TOKEN = process.env.META_WHATSAPP_TOKEN;
    const META_SYGT_PHONE_ID = process.env.META_WHATSAPP_SYGT_PHONE_ID;
    const META_SYGT_NUMBER = '916006560069';
    if (!META_WA_TOKEN || !META_SYGT_PHONE_ID) {
        console.error('[TransportDocs] Meta SYGT WABA not configured');
        return { results: [], error: 'Meta SYGT not configured' };
    }

    const axios = require('axios');
    const cn = (companyName || '').toLowerCase();
    const isESPL = cn === 'espl' || cn.includes('emperor');
    const templateName = isESPL ? SYGT_TRANSPORT_TEMPLATES.espl : SYGT_TRANSPORT_TEMPLATES.sygt;

    const sendToPhone = async (targetPhone) => {
        let cleanPhone = String(targetPhone).replace(/\D/g, '');
        if (cleanPhone.length === 10) cleanPhone = `91${cleanPhone}`;
        if (cleanPhone.length < 10 || cleanPhone.length > 15) {
            return { phone: targetPhone, success: false, error: 'Invalid phone number length' };
        }
        if (cleanPhone === META_SYGT_NUMBER) return { phone: `+${cleanPhone}`, success: false, error: 'Skip self-send' };

        try {
            // DOCUMENT header uses link directly (no media upload needed for URLs)
            const components = [
                { type: 'header', parameters: [{ type: 'document', document: { link: pdfUrl, filename: `transport_${Date.now()}.pdf` } }] },
                { type: 'body', parameters: [{ type: 'text', text: transportName || 'Transport' }] },
            ];
            const res = await axios.post(
                `https://graph.facebook.com/v22.0/${META_SYGT_PHONE_ID}/messages`,
                { messaging_product: 'whatsapp', to: cleanPhone, type: 'template', template: { name: templateName, language: { code: 'en' }, components } },
                { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
            );
            const wamid = res.data?.messages?.[0]?.id || '';
            console.log(`[TransportDocs][SYGT] Sent to +${cleanPhone}: ${wamid}`);
            return { phone: `+${cleanPhone}`, success: true, messageId: wamid, method: 'meta-sygt-document' };
        } catch (err) {
            console.error(`[TransportDocs][SYGT] Failed for +${cleanPhone}: ${err.response?.data ? JSON.stringify(err.response.data) : err.message}`);
            return { phone: `+${cleanPhone}`, success: false, error: err.message };
        }
    };

    const settled = await Promise.allSettled(phones.map(p => sendToPhone(p)));
    const results = settled.map(s =>
        s.status === 'fulfilled' ? s.value : { success: false, error: s.reason?.message || 'Send failed' }
    );
    return { results };
}

// ── Helper: send WhatsApp via Meta Cloud API (+919790005649) with DOCUMENT header ──
async function sendWhatsAppMeta(pdfBuffer, phones, transportName, companyName) {
    const META_WA_TOKEN = process.env.META_WHATSAPP_TOKEN;
    const META_WA_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;
    const META_SENDER = '919790005649';
    if (!META_WA_TOKEN || !META_WA_PHONE_ID) return { results: [] };

    const axios = require('axios');
    const FormData = require('form-data');
    const cn = (companyName || '').toLowerCase();
    const isESPL = cn === 'espl' || cn.includes('emperor');
    const templateName = isESPL ? ESPL_TRANSPORT_TEMPLATES.espl : ESPL_TRANSPORT_TEMPLATES.sygt;

    // Upload PDF to Meta media
    let mediaId = null;
    try {
        const form = new FormData();
        form.append('messaging_product', 'whatsapp');
        form.append('type', 'application/pdf');
        form.append('file', pdfBuffer, { filename: `transport_${Date.now()}.pdf`, contentType: 'application/pdf' });
        const uploadRes = await axios.post(
            `https://graph.facebook.com/v22.0/${META_WA_PHONE_ID}/media`,
            form,
            { headers: { ...form.getHeaders(), Authorization: `Bearer ${META_WA_TOKEN}` }, timeout: 15000 }
        );
        mediaId = uploadRes.data.id;
        console.log(`[TransportDocs][Meta] PDF uploaded: ${mediaId}`);
    } catch (err) {
        console.error(`[TransportDocs][Meta] PDF upload failed: ${err.response?.data ? JSON.stringify(err.response.data) : err.message}`);
        return { results: [] };
    }

    const sendToPhone = async (phone) => {
        let clean = String(phone).replace(/\D/g, '');
        if (clean.length === 10) clean = `91${clean}`;
        if (clean === META_SENDER) return { phone: `+${clean}`, success: false, error: 'Skip self-send' };
        try {
            const res = await axios.post(
                `https://graph.facebook.com/v22.0/${META_WA_PHONE_ID}/messages`,
                {
                    messaging_product: 'whatsapp', to: clean, type: 'template',
                    template: {
                        name: templateName, language: { code: 'en' },
                        components: [
                            { type: 'header', parameters: [{ type: 'document', document: { id: mediaId } }] },
                            { type: 'body', parameters: [{ type: 'text', text: transportName || 'Transport' }] }
                        ]
                    }
                },
                { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 }
            );
            const wamid = res.data?.messages?.[0]?.id || '';
            console.log(`[TransportDocs][Meta] ✓ +${clean} (${templateName}): ${wamid}`);
            return { phone: `+${clean}`, success: true, messageId: wamid, method: 'meta' };
        } catch (err) {
            console.error(`[TransportDocs][Meta] ✗ +${clean}: ${err.response?.data ? JSON.stringify(err.response.data) : err.message}`);
            return { phone: `+${clean}`, success: false, error: err.message };
        }
    };

    const settled = await Promise.allSettled(phones.map(p => sendToPhone(p)));
    return { results: settled.map(s => s.status === 'fulfilled' ? s.value : { success: false, error: s.reason?.message }) };
}

// ══════════════════════════════════════════════════════════════════════════════
// ROUTES
// ══════════════════════════════════════════════════════════════════════════════

// POST / — Create transport document (upload PDF + send WhatsApp + store)
// Increase body limit for large PDF uploads (images → PDF can be 15MB+)
const express = require('express');
router.post('/', express.json({ limit: '25mb' }), async (req, res) => {
    try {
        const { pdfBase64, transportName, phones, caption, imageCount, date, createdBy, companyName } = req.body;
        if (!pdfBase64 || !transportName || !date) {
            return res.status(400).json({ success: false, error: 'pdfBase64, transportName, and date are required' });
        }

        // Server-side phone lookup: if client didn't send phones, fetch from client_contacts
        let targetPhones = Array.isArray(phones) && phones.length > 0 ? phones : [];
        if (targetPhones.length === 0 && transportName) {
            try {
                const clientContacts = require('./client_contacts_fb');
                const allContacts = await clientContacts.getAllClientContacts();
                const match = allContacts.find(c =>
                    (c.name || '').toLowerCase().trim() === transportName.toLowerCase().trim()
                );
                if (match) {
                    const rawPhones = Array.isArray(match.phones) ? match.phones : (match.phone ? [match.phone] : []);
                    targetPhones = rawPhones
                        .map(p => String(p).replace(/[^\d+]/g, ''))
                        .filter(p => p.length >= 10);
                    console.log(`[TransportDocs] Server-side phone lookup for "${transportName}": found ${targetPhones.length} phones`);
                }
            } catch (e) {
                console.error(`[TransportDocs] Server-side phone lookup failed (non-fatal): ${e.message}`);
            }
        }

        const id = `TD-${Date.now()}`;
        const now = new Date().toISOString();
        const pdfBuffer = Buffer.from(pdfBase64, 'base64');

        // 1. Upload PDF to Firebase Storage (public URL used for WhatsApp too)
        const safeName = (transportName || 'unknown').replace(/[^a-zA-Z0-9_-]/g, '_');
        const storagePath = `transport-documents/${safeName}/${date}_${Date.now()}.pdf`;
        const pdfUrl = await uploadToFirebaseStorage(pdfBuffer, storagePath, 'application/pdf');

        // 2. Generate JPEG preview for WhatsApp template (templates reject PDF URLs)
        let previewImageUrl = null;
        if (targetPhones.length > 0) {
            try {
                const previewBuffer = await generatePreviewImage(transportName);
                const previewPath = `transport-documents/${safeName}/${date}_${Date.now()}_preview.jpg`;
                previewImageUrl = await uploadToFirebaseStorage(previewBuffer, previewPath, 'image/jpeg');
            } catch (prevErr) {
                console.error(`[TransportDocs] Preview image generation failed (non-fatal): ${prevErr.message}`);
            }
        }

        // 3. Send WhatsApp via Meta Cloud API (SYGT + ESPL) in parallel — non-fatal
        let sygtResults = { results: [] };
        let esplResults = { results: [] };
        if (targetPhones.length > 0 && pdfUrl) {
            const [sygtRes, esplRes] = await Promise.allSettled([
                sendWhatsApp(pdfUrl, previewImageUrl, targetPhones, transportName, caption || '', companyName || 'SYGT')
                    .catch(err => { console.error(`[TransportDocs] SYGT send failed: ${err.message}`); return { results: [] }; }),
                sendWhatsAppMeta(pdfBuffer, targetPhones, transportName, companyName || 'SYGT')
                    .catch(err => { console.error(`[TransportDocs] ESPL send failed: ${err.message}`); return { results: [] }; }),
            ]);
            sygtResults = sygtRes.status === 'fulfilled' ? sygtRes.value : { results: [] };
            esplResults = esplRes.status === 'fulfilled' ? esplRes.value : { results: [] };
        }

        // Merge results: a phone is "sent" if either channel succeeded
        const allResults = [...sygtResults.results, ...esplResults.results];
        const sentPhoneSet = new Set(allResults.filter(r => r.success).map(r => r.phone));
        const sentPhones = [...sentPhoneSet];

        // 4. Store in Firestore
        const doc = {
            id,
            transportName: transportName || '',
            companyName: companyName || 'SYGT',
            date: date || '',
            pdfUrl,
            caption: caption || '',
            imageCount: imageCount || 0,
            phones: targetPhones,
            sentToPhones: sentPhones,
            sentAt: targetPhones.length > 0 ? now : '',
            createdAt: now,
            createdBy: createdBy || req.headers['x-user'] || '',
            isDeleted: false,
        };
        await col().doc(id).set(doc);

        console.log(`[TransportDocs] Created ${id} for ${transportName}, sent to ${sentPhones.length}/${targetPhones.length} phones`);

        // 5. Notify superadmin (non-fatal — fire and forget)
        pushNotifications.notifyTransportDocSent({
            transportName,
            pageCount: imageCount || 0,
            date,
            createdBy: createdBy || req.headers['x-user'] || '',
        }).catch(err => console.error('[TransportDocs] Push notification error:', err.message));

        res.json({
            success: true,
            document: doc,
            whatsappResults: allResults,
            sentCount: sentPhones.length,
            totalCount: targetPhones.length,
        });
    } catch (err) {
        console.error('[TransportDocs] Create error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET / — List transport documents with filters
router.get('/', async (req, res) => {
    try {
        const { transportName, dateFrom, dateTo, limit: limitStr } = req.query;
        const limit = Math.max(1, Math.min(parseInt(limitStr) || 50, 200));

        let query = col().where('isDeleted', '==', false);
        if (transportName) query = query.where('transportName', '==', transportName);
        query = query.orderBy('createdAt', 'desc').limit(limit);

        const snap = await query.get();
        let docs = snap.docs.map(d => ({ id: d.id, ...d.data() }));

        // Client-side date range filter
        if (dateFrom) docs = docs.filter(d => d.date >= dateFrom);
        if (dateTo) docs = docs.filter(d => d.date <= dateTo);

        res.json({ success: true, documents: docs, count: docs.length });
    } catch (err) {
        console.error('[TransportDocs] List error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /:id — Get single transport document
router.get('/:id', async (req, res) => {
    try {
        const snap = await col().doc(req.params.id).get();
        if (!snap.exists) return res.status(404).json({ success: false, error: 'Not found' });
        res.json({ success: true, document: { id: snap.id, ...snap.data() } });
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

// POST /:id/resend — Resend to WhatsApp
router.post('/:id/resend', async (req, res) => {
    try {
        const { phones } = req.body;
        if (!Array.isArray(phones) || phones.length === 0) {
            return res.status(400).json({ success: false, error: 'phones array required' });
        }

        const snap = await col().doc(req.params.id).get();
        if (!snap.exists) return res.status(404).json({ success: false, error: 'Not found' });
        const doc = snap.data();

        if (doc.isDeleted) {
            return res.status(410).json({ success: false, error: 'Document has been deleted' });
        }

        // Generate JPEG preview for WhatsApp template
        let previewImageUrl = null;
        try {
            const previewBuffer = await generatePreviewImage(doc.transportName);
            const safeName = (doc.transportName || 'unknown').replace(/[^a-zA-Z0-9_-]/g, '_');
            const previewPath = `transport-documents/${safeName}/resend_${Date.now()}_preview.jpg`;
            previewImageUrl = await uploadToFirebaseStorage(previewBuffer, previewPath, 'image/jpeg');
        } catch (prevErr) {
            console.error(`[TransportDocs] Resend preview generation failed (non-fatal): ${prevErr.message}`);
        }

        // Send via Meta Cloud API (SYGT + ESPL) in parallel
        let pdfBuf = null;
        try {
            const axios = require('axios');
            const dlRes = await axios.get(doc.pdfUrl, { responseType: 'arraybuffer', timeout: 10000 });
            pdfBuf = Buffer.from(dlRes.data);
        } catch (_) { /* ESPL send will be skipped if download fails */ }

        const [sygtRes, esplRes] = await Promise.allSettled([
            sendWhatsApp(doc.pdfUrl, previewImageUrl, phones, doc.transportName, doc.caption, doc.companyName || 'SYGT'),
            pdfBuf ? sendWhatsAppMeta(pdfBuf, phones, doc.transportName, doc.companyName || 'SYGT') : Promise.resolve({ results: [] }),
        ]);
        const sygtResults = sygtRes.status === 'fulfilled' ? sygtRes.value : { results: [] };
        const esplResults = esplRes.status === 'fulfilled' ? esplRes.value : { results: [] };
        const allResendResults = [...sygtResults.results, ...esplResults.results];
        const sentSet = new Set(allResendResults.filter(r => r.success).map(r => r.phone));
        const newSentPhones = [...sentSet];

        // Append to existing sent records
        const admin = require('firebase-admin');
        const updateData = {
            sentAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
        };
        if (newSentPhones.length > 0) {
            updateData.sentToPhones = admin.firestore.FieldValue.arrayUnion(...newSentPhones);
        }
        await col().doc(req.params.id).update(updateData);

        console.log(`[TransportDocs] Resent ${req.params.id} to ${newSentPhones.length}/${phones.length} phones`);
        res.json({ success: true, results: sygtResults.results, sentCount: newSentPhones.length });
    } catch (err) {
        console.error('[TransportDocs] Resend error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = { router };
