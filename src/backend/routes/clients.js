const router = require('express').Router();
const clientContactsFb = require('../../../backend/firebase/client_contacts_fb');
const dropdownFb = require('../../../backend/firebase/dropdown_fb');
const { requireAdmin } = require('../../../backend/middleware/auth');
const { invalidateApiCache } = require('../middleware/apiCache');

// Find duplicate client names (potential merges) — admin only
router.get('/duplicates', requireAdmin, async (req, res) => {
    try {
        const result = await dropdownFb.findDuplicateClients();
        res.json(result);
    } catch (err) {
        console.error('[Clients] Duplicate detection error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Merge duplicate client names across all orders — admin only
router.post('/merge', requireAdmin, async (req, res) => {
    try {
        const { oldName, newName, dryRun = true } = req.body;
        if (!oldName || !newName) return res.status(400).json({ success: false, error: 'oldName and newName are required' });
        const result = await dropdownFb.mergeClients(oldName, newName, dryRun);
        const { dropdownCache } = require('../../../backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Clients] Merge error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Client Contact Details - for WhatsApp sharing (Firestore)
router.get('/contact/:clientName', requireAdmin, async (req, res) => {
    try {
        const { clientName } = req.params;
        if (!clientName) {
            return res.status(400).json({ success: false, error: 'clientName is required' });
        }

        const contact = await clientContactsFb.getClientContact(clientName);

        if (!contact) {
            return res.json({ success: false, error: 'Client not found', clientName });
        }

        // Clean phone number helper
        function cleanPhoneNum(raw) {
            let p = String(raw || '').replace(/[^\d+]/g, '');
            if (p && !p.startsWith('+') && !p.startsWith('91') && p.length === 10) {
                p = '91' + p;
            }
            p = p.replace(/^\+/, '');
            return p;
        }

        const rawPhones = contact.phones || (contact.phone ? [contact.phone] : []);
        const cleanedPhones = rawPhones.map(cleanPhoneNum).filter(Boolean);

        res.json({
            success: true,
            contact: {
                name: contact.name,
                phones: cleanedPhones,
                rawPhones: rawPhones,
                phone: cleanedPhones[0] || '',     // backward compat
                rawPhone: rawPhones[0] || '',       // backward compat
                address: contact.address,
                gstin: contact.gstin
            }
        });
    } catch (err) {
        console.error('[GET /api/clients/contact] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get all client contacts (for dropdown manager)
router.get('/contacts/all', requireAdmin, async (req, res) => {
    try {
        const contacts = await clientContactsFb.getAllClientContacts();

        // Clean phone numbers consistently (same logic as single-contact endpoint)
        function cleanPhoneNum(raw) {
            let p = String(raw || '').replace(/[^\d+]/g, '');
            if (p && !p.startsWith('+') && !p.startsWith('91') && p.length === 10) {
                p = '91' + p;
            }
            p = p.replace(/^\+/, '');
            return p;
        }

        const cleaned = contacts.map(c => {
            const rawPhones = c.phones || (c.phone ? [c.phone] : []);
            const cleanedPhones = rawPhones.map(cleanPhoneNum).filter(Boolean);
            return {
                ...c,
                phones: cleanedPhones,
                phone: cleanedPhones[0] || '',
            };
        });

        res.json({ success: true, contacts: cleaned });
    } catch (err) {
        console.error('[GET /api/clients/contacts/all] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Save/update client contact (phones, address, gstin)
router.put('/contact', requireAdmin, async (req, res) => {
    try {
        const { name, oldName, phone, phones, address, gstin } = req.body;
        console.log(`[PUT /api/clients/contact] name="${name}" oldName=${oldName} phones=${JSON.stringify(phones)} phone=${phone} address="${address}"`);
        if (!name) {
            return res.status(400).json({ success: false, error: 'Client name is required' });
        }
        const result = await clientContactsFb.upsertClientContact({ name, oldName, phone, phones, address, gstin });
        console.log(`[PUT /api/clients/contact] Result: ${JSON.stringify(result)}`);
        invalidateApiCache();
        res.json(result);
    } catch (err) {
        console.error('[PUT /api/clients/contact] Error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
