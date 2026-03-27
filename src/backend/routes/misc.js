/**
 * Misc Routes — WhatsApp, Outstanding, Packed Boxes, WhatsApp Logs, Debug, Access Log
 *
 * Groups smaller feature areas that don't warrant their own route file.
 */
const router = require('express').Router();
const path = require('path');
const LOGO_URL = process.env.LOGO_URL || '';
const outstanding = require('../../../backend/firebase/outstanding_fb');
const packedBoxes = require('../../../backend/firebase/packed_boxes_fb');
const whatsappLogs = require('../../../backend/firebase/whatsapp_logs_fb');
const clientContactsFb = require('../../../backend/firebase/client_contacts_fb');
const { requireAdmin } = require('../../../backend/middleware/auth');
const { getCachedResponse, setCachedResponse, invalidateApiCache } = require('../middleware/apiCache');
const { getDb } = require('../database/sqliteClient');

// ========== WhatsApp ==========

// GET /api/whatsapp/verify/:phone
router.get('/whatsapp/verify/:phone', async (req, res) => {
    try {
        const phone = req.params.phone.replace(/\D/g, '');
        if (!phone || phone.length < 10) {
            return res.json({ success: true, valid: false, reason: 'Invalid phone number format' });
        }
        const fullPhone = phone.length === 10 ? `91${phone}` : phone;
        const https = require('https');
        const checkUrl = `https://api.whatsapp.com/send/?phone=${fullPhone}&text&type=phone_number&app_absent=0`;

        const result = await new Promise((resolve, reject) => {
            https.get(checkUrl, {
                headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' },
                timeout: 8000
            }, (response) => {
                let data = '';
                response.on('data', chunk => data += chunk);
                response.on('end', () => {
                    const isValid = response.statusCode === 200 && !data.includes('page_not_found') && !data.includes('invalid');
                    resolve({ valid: isValid, statusCode: response.statusCode });
                });
            }).on('error', reject).on('timeout', () => {
                resolve({ valid: true, statusCode: 0, timeout: true });
            });
        });

        res.json({ success: true, valid: result.valid, phone: fullPhone });
    } catch (err) {
        console.error('[GET /api/whatsapp/verify] Error:', err);
        res.json({ success: true, valid: true, error: err.message });
    }
});

// POST /api/whatsapp/send-image
router.post('/whatsapp/send-image', requireAdmin, async (req, res) => {
    const startTime = Date.now();
    const requestId = `wa_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;

    try {
        const { imageBase64, phone, phones, caption, clientName, operationType, companyName } = req.body;
        const targetPhones = Array.isArray(phones) && phones.length > 0
            ? phones : (phone ? [phone] : []);

        if (!imageBase64 || targetPhones.length === 0) {
            return res.status(400).json({ success: false, error: 'imageBase64 and at least one phone are required', requestId });
        }

        const META_WA_TOKEN = process.env.META_WHATSAPP_TOKEN;
        const META_ESPL_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;
        const META_ESPL_NUMBER = '919790005649';
        const META_SYGT_PHONE_ID = process.env.META_WHATSAPP_SYGT_PHONE_ID;
        const META_SYGT_NUMBER = '916006560069';
        const metaEnabled = !!(META_WA_TOKEN && META_ESPL_PHONE_ID);
        const sygtEnabled = !!(META_WA_TOKEN && META_SYGT_PHONE_ID);

        const META_ESPL_TEMPLATES = {
            order_confirmation_espl: { name: 'order_details_espl_v1', hasImageHeader: true },
            order_confirmation_sygt: { name: 'order_details_sygt_v1', hasImageHeader: true },
            share_orders_espl: { name: 'order_details_espl_v1', hasImageHeader: true },
            share_orders_sygt: { name: 'order_details_sygt_v1', hasImageHeader: true },
            invoice_document: { name: 'invoice_document_v1', hasImageHeader: true },
            payment_reminder_espl: { name: 'payment_reminder_espl_v3', hasImageHeader: true },
            payment_reminder_sygt: { name: 'payment_reminder_sygt_v3', hasImageHeader: true },
        };
        const META_SYGT_TEMPLATES = {
            order_confirmation_espl: { name: 'order_details_espl_hx7df95ed3a1bf3e209a41c3ba920a16c1', hasImageHeader: true },
            order_confirmation_sygt: { name: 'order_details_sygt_hxb338f8ebd49e1f6eacccd992d77372eb', hasImageHeader: true },
            share_orders_espl: { name: 'order_details_espl_hx7df95ed3a1bf3e209a41c3ba920a16c1', hasImageHeader: true },
            share_orders_sygt: { name: 'order_details_sygt_hxb338f8ebd49e1f6eacccd992d77372eb', hasImageHeader: true },
            invoice_document: { name: 'invoice_document_hx96d51d825956ebc66f7be26efb466c1c', hasImageHeader: true },
            payment_reminder_espl: { name: 'payment_remind_espl_hx4923be67303fb2dfcff7f9894c232faf', hasImageHeader: true },
            payment_reminder_sygt: { name: 'payment_remind_sygt_hx7e453c04aef926fea01ead62354f3833', hasImageHeader: true },
            price_offer_espl: { name: 'price_offer_espl_hxa2f5a9808bda54528039c6b644759f95', hasImageHeader: true },
            price_offer_sygt: { name: 'price_offer_sygt_hx0bf2d2f0bc3aabe6f73d4ca17578624b', hasImageHeader: true },
        };

        if (!sygtEnabled && !metaEnabled) {
            return res.status(500).json({ success: false, error: 'WhatsApp not configured', requestId });
        }

        const imageBuffer = Buffer.from(imageBase64, 'base64');
        const FormData = require('form-data');
        const axios = require('axios');

        // Upload to CDN (no local filesystem fallback on ICP)
        let imageUrl;
        try {
            const form = new FormData();
            form.append('reqtype', 'fileupload');
            form.append('time', '24h');
            form.append('fileToUpload', imageBuffer, { filename: `wa_${Date.now()}.png`, contentType: 'image/png' });
            const uploadRes = await axios.post('https://litterbox.catbox.moe/resources/internals/api.php', form, { headers: form.getHeaders(), timeout: 15000 });
            imageUrl = uploadRes.data.trim();
        } catch (uploadErr) {
            return res.status(500).json({ success: false, error: 'CDN upload failed: ' + uploadErr.message, requestId });
        }

        const companySuffix = (companyName || '').toLowerCase().includes('emperor') ? 'espl' : 'sygt';
        const opKey = operationType ? `${operationType}_${companySuffix}` : `order_confirmation_${companySuffix}`;
        const sygtTemplate = META_SYGT_TEMPLATES[opKey] || META_SYGT_TEMPLATES[operationType];
        const shouldSendSygt = sygtEnabled && sygtTemplate;
        const esplTemplate = META_ESPL_TEMPLATES[opKey] || META_ESPL_TEMPLATES[operationType];
        const shouldSendEspl = metaEnabled && esplTemplate;

        // Upload media to WABAs
        let sygtMediaId = null, esplMediaId = null;
        const uploadMedia = async (phoneId) => {
            const mForm = new FormData();
            mForm.append('messaging_product', 'whatsapp');
            mForm.append('type', 'image/png');
            mForm.append('file', imageBuffer, { filename: `wa_${Date.now()}.png`, contentType: 'image/png' });
            const up = await axios.post(`https://graph.facebook.com/v22.0/${phoneId}/media`, mForm, {
                headers: { ...mForm.getHeaders(), Authorization: `Bearer ${META_WA_TOKEN}` }, timeout: 15000
            });
            return up.data.id;
        };
        if (shouldSendSygt && sygtTemplate.hasImageHeader) {
            try { sygtMediaId = await uploadMedia(META_SYGT_PHONE_ID); } catch (e) { console.error(`[${requestId}] SYGT media upload failed`); }
        }
        if (shouldSendEspl && esplTemplate.hasImageHeader) {
            try { esplMediaId = await uploadMedia(META_ESPL_PHONE_ID); } catch (e) { console.error(`[${requestId}] ESPL media upload failed`); }
        }

        const sendViaMeta = async (cleanPhone, phoneId, template, mediaId) => {
            const components = [{ type: 'body', parameters: [{ type: 'text', text: clientName || 'Customer' }] }];
            if (template.hasImageHeader && (mediaId || imageUrl)) {
                const imgParam = mediaId ? { id: mediaId } : { link: imageUrl };
                components.unshift({ type: 'header', parameters: [{ type: 'image', image: imgParam }] });
            }
            const r = await axios.post(`https://graph.facebook.com/v22.0/${phoneId}/messages`, {
                messaging_product: 'whatsapp', to: cleanPhone, type: 'template',
                template: { name: template.name, language: { code: 'en' }, components }
            }, { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 });
            return r.data?.messages?.[0]?.id || '';
        };

        const sendToPhone = async (targetPhone) => {
            let cleanPhone = String(targetPhone).replace(/\D/g, '');
            if (cleanPhone.length === 10) cleanPhone = `91${cleanPhone}`;
            let sygtOk = false, esplOk = false, messageId = null;
            if (shouldSendSygt && cleanPhone !== META_SYGT_NUMBER) {
                try { messageId = await sendViaMeta(cleanPhone, META_SYGT_PHONE_ID, sygtTemplate, sygtMediaId); sygtOk = true; } catch (e) { }
            }
            if (shouldSendEspl && cleanPhone !== META_ESPL_NUMBER) {
                try { const wamid = await sendViaMeta(cleanPhone, META_ESPL_PHONE_ID, esplTemplate, esplMediaId); esplOk = true; if (!messageId) messageId = wamid; } catch (e) { }
            }
            return { phone: `+${cleanPhone}`, success: sygtOk || esplOk, messageId, method: `sygt:${sygtOk},espl:${esplOk}` };
        };

        const settled = await Promise.allSettled(targetPhones.map(p => sendToPhone(p)));
        const results = settled.map(s => s.status === 'fulfilled' ? s.value : { success: false, error: s.reason?.message || 'Unknown error' });
        const sentCount = results.filter(r => r.success).length;
        const duration = Date.now() - startTime;

        res.json({ success: sentCount > 0, sentCount, totalCount: targetPhones.length, results, requestId, imageUrl, duration: `${duration}ms` });
    } catch (err) {
        const duration = Date.now() - startTime;
        res.status(500).json({ success: false, error: err.message, requestId, duration: `${duration}ms` });
    }
});

// POST /api/whatsapp/send-text
router.post('/whatsapp/send-text', requireAdmin, async (req, res) => {
    try {
        const { phone, phones, clientName } = req.body;
        const targetPhones = Array.isArray(phones) && phones.length > 0 ? phones : (phone ? [phone] : []);
        if (targetPhones.length === 0) {
            return res.status(400).json({ success: false, error: 'At least one phone is required' });
        }

        const META_TOKEN = process.env.META_WHATSAPP_TOKEN;
        const META_SYGT_PHONE_ID = process.env.META_WHATSAPP_SYGT_PHONE_ID;
        const META_ESPL_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;
        if (!META_TOKEN || (!META_SYGT_PHONE_ID && !META_ESPL_PHONE_ID)) {
            return res.status(500).json({ success: false, error: 'Meta WhatsApp not configured' });
        }

        const axios = require('axios');
        const sygtTemplate = 'order_confirm_sygt_hxdbec4c73106f98d84aa16d0832993784';
        const esplTemplate = 'order_confirm_espl_hxa353a5933129970bac3b6ccc7d59d1fa';
        const logoUrl = LOGO_URL;

        const sendToPhone = async (targetPhone) => {
            let cleanPhone = String(targetPhone).replace(/\D/g, '');
            if (cleanPhone.length === 10) cleanPhone = `91${cleanPhone}`;
            let messageId = null, sygtOk = false, esplOk = false;

            if (META_SYGT_PHONE_ID && cleanPhone !== '916006560069') {
                try {
                    const r = await axios.post(`https://graph.facebook.com/v22.0/${META_SYGT_PHONE_ID}/messages`, {
                        messaging_product: 'whatsapp', to: cleanPhone, type: 'template',
                        template: { name: sygtTemplate, language: { code: 'en' }, components: [
                            { type: 'header', parameters: [{ type: 'image', image: { link: logoUrl } }] },
                            { type: 'body', parameters: [{ type: 'text', text: clientName || 'Customer' }] },
                        ] },
                    }, { headers: { Authorization: `Bearer ${META_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 });
                    messageId = r.data?.messages?.[0]?.id || '';
                    sygtOk = true;
                } catch (err) { }
            }
            if (META_ESPL_PHONE_ID && cleanPhone !== '919790005649') {
                try {
                    const r = await axios.post(`https://graph.facebook.com/v22.0/${META_ESPL_PHONE_ID}/messages`, {
                        messaging_product: 'whatsapp', to: cleanPhone, type: 'template',
                        template: { name: esplTemplate, language: { code: 'en' }, components: [
                            { type: 'header', parameters: [{ type: 'image', image: { link: logoUrl } }] },
                            { type: 'body', parameters: [{ type: 'text', text: clientName || 'Customer' }] },
                        ] },
                    }, { headers: { Authorization: `Bearer ${META_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 });
                    if (!messageId) messageId = r.data?.messages?.[0]?.id || '';
                    esplOk = true;
                } catch (err) { }
            }
            return { phone: `+${cleanPhone}`, success: sygtOk || esplOk, messageId, method: `sygt:${sygtOk},espl:${esplOk}` };
        };

        const settled = await Promise.allSettled(targetPhones.map(p => sendToPhone(p)));
        const results = settled.map(s => s.status === 'fulfilled' ? s.value : { phone: 'unknown', success: false, error: s.reason?.message });
        const sentCount = results.filter(r => r.success).length;
        res.json({ success: sentCount > 0, sentCount, totalCount: targetPhones.length, results });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// ========== Outstanding Payments ==========

// GET /api/outstanding
router.get('/outstanding', async (req, res) => {
    try {
        const company = req.query.company || 'all';
        const cacheKey = `/api/outstanding?company=${company}`;
        const cached = getCachedResponse(cacheKey);
        if (cached) return res.json(cached);
        const data = await outstanding.getOutstandingData(company);
        const result = { success: true, data };
        setCachedResponse(cacheKey, result);
        res.json(result);
    } catch (err) {
        console.error('[Outstanding] GET error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /api/outstanding/check-date
router.get('/outstanding/check-date', async (req, res) => {
    try {
        const dates = await outstanding.getOutstandingDates();
        res.json({ success: true, dates });
    } catch (err) {
        console.error('[Outstanding] check-date error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST /api/outstanding/send-reminders
router.post('/outstanding/send-reminders', async (req, res) => {
    const { clients } = req.body;
    if (!Array.isArray(clients) || clients.length === 0) {
        return res.status(400).json({ success: false, error: 'clients array is required' });
    }
    const requestId = `pr_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
    // Respond immediately — processing continues in background
    res.json({ success: true, queued: clients.length, requestId });

    // Background processing
    const FormData = require('form-data');
    const axios = require('axios');
    let generatePaymentImage;
    try { generatePaymentImage = require('../../../backend/services/payment_image_generator').generatePaymentImage; } catch (e) {
        console.error(`[${requestId}] payment_image_generator not available: ${e.message}`);
        return;
    }

    const META_WA_TOKEN = process.env.META_WHATSAPP_TOKEN;
    const META_ESPL_PHONE_ID = process.env.META_WHATSAPP_PHONE_ID;
    const META_SYGT_PHONE_ID = process.env.META_WHATSAPP_SYGT_PHONE_ID;
    const esplEnabled = !!(META_WA_TOKEN && META_ESPL_PHONE_ID);
    const sygtEnabled = !!(META_WA_TOKEN && META_SYGT_PHONE_ID);
    if (!sygtEnabled && !esplEnabled) return;

    const SYGT_TEMPLATES = {
        payment_reminder_espl: 'payment_remind_espl_hx4923be67303fb2dfcff7f9894c232faf',
        payment_reminder_sygt: 'payment_remind_sygt_hx7e453c04aef926fea01ead62354f3833',
    };
    const ESPL_TEMPLATES = {
        payment_reminder_espl: 'payment_reminder_espl_v3',
        payment_reminder_sygt: 'payment_reminder_sygt_v3',
    };

    let successCount = 0, failCount = 0;
    for (const client of clients) {
        const clientPhones = Array.isArray(client.phones) ? client.phones.filter(Boolean) : [];
        if (clientPhones.length === 0) { failCount++; continue; }
        try {
            const pngBuffer = await generatePaymentImage(client);
            // Upload to CDN (no filesystem fallback on ICP)
            let imageUrl;
            try {
                const form = new FormData();
                form.append('reqtype', 'fileupload');
                form.append('time', '24h');
                form.append('fileToUpload', pngBuffer, { filename: `pr_${Date.now()}.png`, contentType: 'image/png' });
                const uploadRes = await axios.post('https://litterbox.catbox.moe/resources/internals/api.php', form, { headers: form.getHeaders(), timeout: 15000 });
                imageUrl = uploadRes.data.trim();
            } catch (cdnErr) {
                console.error(`[${requestId}] CDN upload failed for ${client.sheetName}: ${cdnErr.message}`);
                failCount++;
                continue;
            }

            const uploadMedia = async (phoneId) => {
                const mForm = new FormData();
                mForm.append('messaging_product', 'whatsapp');
                mForm.append('type', 'image/png');
                mForm.append('file', pngBuffer, { filename: `pr_${Date.now()}.png`, contentType: 'image/png' });
                const up = await axios.post(`https://graph.facebook.com/v22.0/${phoneId}/media`, mForm, {
                    headers: { ...mForm.getHeaders(), Authorization: `Bearer ${META_WA_TOKEN}` }, timeout: 15000
                });
                return up.data.id;
            };
            let sygtMediaId = null, esplMediaId = null;
            if (sygtEnabled) try { sygtMediaId = await uploadMedia(META_SYGT_PHONE_ID); } catch (e) { }
            if (esplEnabled) try { esplMediaId = await uploadMedia(META_ESPL_PHONE_ID); } catch (e) { }

            const isESPL = (client.companyFull || client.company || '').toLowerCase().includes('emperor');
            const templateKey = isESPL ? 'payment_reminder_espl' : 'payment_reminder_sygt';
            const sygtTemplateName = SYGT_TEMPLATES[templateKey];
            const esplTemplateName = ESPL_TEMPLATES[templateKey];
            const logBase = { clientName: client.sheetName || 'Customer', company: isESPL ? 'Emperor Spices Pvt Ltd' : 'Sri Yogaganapathi Traders', type: 'payment_reminder', requestId };

            const sendToPhone = async (ph) => {
                let clean = String(ph).replace(/\D/g, '');
                if (clean.length === 10) clean = `91${clean}`;
                let ok = false;
                if (sygtEnabled && clean !== '916006560069') {
                    try {
                        const components = [{ type: 'body', parameters: [{ type: 'text', text: client.sheetName || 'Customer' }] }];
                        const imgParam = sygtMediaId ? { id: sygtMediaId } : (imageUrl ? { link: imageUrl } : null);
                        if (imgParam) components.unshift({ type: 'header', parameters: [{ type: 'image', image: imgParam }] });
                        await axios.post(`https://graph.facebook.com/v22.0/${META_SYGT_PHONE_ID}/messages`, {
                            messaging_product: 'whatsapp', to: clean, type: 'template',
                            template: { name: sygtTemplateName, language: { code: 'en' }, components }
                        }, { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 });
                        whatsappLogs.logSend({ ...logBase, recipient: clean, channel: 'meta-sygt', sender: '916006560069', templateName: sygtTemplateName, status: 'accepted' });
                        ok = true;
                    } catch (e) { whatsappLogs.logSend({ ...logBase, recipient: clean, channel: 'meta-sygt', sender: '916006560069', templateName: sygtTemplateName, status: 'failed', error: e.message }); }
                }
                if (esplEnabled && clean !== '919790005649') {
                    try {
                        const components = [{ type: 'body', parameters: [{ type: 'text', text: client.sheetName || 'Customer' }] }];
                        const imgParam = esplMediaId ? { id: esplMediaId } : (imageUrl ? { link: imageUrl } : null);
                        if (imgParam) components.unshift({ type: 'header', parameters: [{ type: 'image', image: imgParam }] });
                        await axios.post(`https://graph.facebook.com/v22.0/${META_ESPL_PHONE_ID}/messages`, {
                            messaging_product: 'whatsapp', to: clean, type: 'template',
                            template: { name: esplTemplateName, language: { code: 'en' }, components }
                        }, { headers: { Authorization: `Bearer ${META_WA_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 15000 });
                        whatsappLogs.logSend({ ...logBase, recipient: clean, channel: 'meta-espl', sender: '919790005649', templateName: esplTemplateName, status: 'accepted' });
                        ok = true;
                    } catch (e) { whatsappLogs.logSend({ ...logBase, recipient: clean, channel: 'meta-espl', sender: '919790005649', templateName: esplTemplateName, status: 'failed', error: e.message }); }
                }
                return ok;
            };

            const results = await Promise.allSettled(clientPhones.map(sendToPhone));
            const sent = results.filter(r => r.status === 'fulfilled' && r.value === true).length;
            if (sent > 0) successCount++; else failCount++;
        } catch (err) {
            failCount++;
            console.error(`[${requestId}] ${client.sheetName}: error — ${err.message}`);
        }
    }
    console.log(`[${requestId}] Done: ${successCount} success, ${failCount} failed out of ${clients.length}`);
});

// GET /api/outstanding/name-mappings
router.get('/outstanding/name-mappings', async (req, res) => {
    try {
        const cached = getCachedResponse('/api/outstanding/name-mappings');
        if (cached) return res.json(cached);
        const mappings = await outstanding.getNameMappings();
        const result = { success: true, mappings };
        setCachedResponse('/api/outstanding/name-mappings', result);
        res.json(result);
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// PUT /api/outstanding/name-mapping
router.put('/outstanding/name-mapping', requireAdmin, async (req, res) => {
    try {
        const { sheetName, company, firebaseClientName } = req.body;
        const result = await outstanding.saveNameMapping({ sheetName, company, firebaseClientName });
        invalidateApiCache();
        res.json(result);
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// ========== Packed Boxes ==========

router.get('/packed-boxes/today', requireAdmin, async (req, res) => {
    try {
        const { date } = req.query;
        if (!date) return res.status(400).json({ success: false, error: 'date query param required' });
        res.json(await packedBoxes.getTodayEntries(date));
    } catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

router.post('/packed-boxes/add', requireAdmin, async (req, res) => {
    try {
        const { date, grade, brand, boxesAdded } = req.body;
        if (!date || !grade || !brand || boxesAdded == null) {
            return res.status(400).json({ success: false, error: 'Missing required fields' });
        }
        const addedBy = req.user?.username || '';
        res.json(await packedBoxes.addPackedBoxes(date, grade, brand, Number(boxesAdded), addedBy));
    } catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

router.put('/packed-boxes/bill', requireAdmin, async (req, res) => {
    try {
        const updatedBy = req.user?.username || '';
        if (req.body.entries && Array.isArray(req.body.entries)) {
            const results = [];
            for (const entry of req.body.entries) {
                const { date, grade, brand, billed } = entry;
                if (!date || !grade || !brand || billed == null) continue;
                results.push(await packedBoxes.updateBilledBoxes(date, grade, brand, Number(billed), updatedBy));
            }
            return res.json({ success: true, results });
        }
        const { date, grade, brand, boxesBilled } = req.body;
        if (!date || !grade || !brand || boxesBilled == null) {
            return res.status(400).json({ success: false, error: 'Missing required fields' });
        }
        res.json(await packedBoxes.updateBilledBoxes(date, grade, brand, Number(boxesBilled), updatedBy));
    } catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

router.get('/packed-boxes/remaining', requireAdmin, async (req, res) => {
    try { res.json(await packedBoxes.getRemainingBoxes()); }
    catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

router.get('/packed-boxes/history', requireAdmin, async (req, res) => {
    try {
        const { date } = req.query;
        if (!date) return res.status(400).json({ success: false, error: 'date query param required' });
        res.json(await packedBoxes.getHistoryForDate(date));
    } catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

router.delete('/packed-boxes/:id', requireAdmin, async (req, res) => {
    try { res.json(await packedBoxes.deletePackedBoxEntry(req.params.id)); }
    catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

// ========== WhatsApp Logs ==========

router.get('/whatsapp-logs', async (req, res) => {
    try {
        const filters = {};
        if (req.query.channel) filters.channel = req.query.channel;
        if (req.query.type) filters.type = req.query.type;
        if (req.query.status) filters.status = req.query.status;
        if (req.query.recipient) filters.recipient = req.query.recipient;
        if (req.query.limit) filters.limit = parseInt(req.query.limit);
        res.json(await whatsappLogs.getLogs(filters));
    } catch (err) { res.status(500).json({ error: err.message }); }
});

router.get('/whatsapp-logs/stats', async (req, res) => {
    try { res.json(await whatsappLogs.getStats()); }
    catch (err) { res.status(500).json({ error: err.message }); }
});

// ========== Debug ==========

router.get('/debug/orderbook-headers', requireAdmin, (req, res) => {
    res.json({
        headers: ['Order Date', 'Billing From', 'Client', 'Lot', 'Grade', 'Bag / Box', 'No', 'Kgs', 'Price', 'Brand', 'Status', 'Notes'],
        source: 'SQLite (fixed schema)',
        billingFromIndex: 1,
    });
});

router.get('/debug/cart-headers', requireAdmin, (req, res) => {
    const headers = ['Order Date', 'Billing From', 'Client', 'Lot', 'Grade', 'Bag / Box', 'No', 'Kgs', 'Price', 'Brand', 'Status', 'Notes', 'Packed Date'];
    res.json({ headers, headerCount: headers.length, source: 'SQLite (fixed schema)', bagboxColumnIndex: 5, bagboxColumnName: 'Bag / Box' });
});

// ========== Access Restriction Log ==========

router.post('/access-restriction-log', async (req, res) => {
    try {
        const userId = req.user.userId || req.body.userId;
        const userName = req.user.username || req.body.userName;
        const userRole = req.user.role || req.body.userRole;
        const { pageKey, timestamp } = req.body;
        const db = getDb();
        const notifDoc = db.collection('notifications').doc();
        await notifDoc.set({
            id: notifDoc.id,
            userId: 'all_admins',
            title: 'Access Restriction Hit',
            body: `${userName || 'Unknown'} (${userRole || 'unknown'}) tried to access "${pageKey}" but was blocked.`,
            type: 'access_restriction',
            metadata: { blockedUserId: userId, pageKey, userRole, timestamp: timestamp || new Date().toISOString() },
            read: false,
            createdAt: new Date().toISOString(),
        });
        res.json({ success: true });
    } catch (err) {
        console.error('[Access Restriction Log] Error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
