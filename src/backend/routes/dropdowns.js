const router = require('express').Router();
const dropdownFb = require('../../../backend/firebase/dropdown_fb');
const { requireAdmin } = require('../../../backend/middleware/auth');

// Search dropdown items (fuzzy match for inline add)
router.get('/:category/search', async (req, res) => {
    try {
        const { category } = req.params;
        const { q } = req.query;
        if (!q) return res.status(400).json({ success: false, error: 'Query parameter q is required' });
        const result = await dropdownFb.searchDropdownItems(category, q);
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Search error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Get single category items
router.get('/:category', async (req, res) => {
    try {
        const result = await dropdownFb.getDropdownCategory(req.params.category);
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Get category error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Add dropdown item (with duplicate check)
router.post('/:category/add', requireAdmin, async (req, res) => {
    try {
        const { value } = req.body;
        if (!value) return res.status(400).json({ success: false, error: 'value is required' });
        const result = await dropdownFb.addDropdownItem(req.params.category, value);
        // Invalidate dropdown cache on write
        const { dropdownCache } = require('../../../backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Add error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Force add (skip duplicate check — user confirmed)
router.post('/:category/force-add', requireAdmin, async (req, res) => {
    try {
        const { value } = req.body;
        if (!value) return res.status(400).json({ success: false, error: 'value is required' });
        const result = await dropdownFb.forceAddDropdownItem(req.params.category, value);
        const { dropdownCache } = require('../../../backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Force-add error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Update (rename) dropdown item — admin only
router.put('/:category/item', requireAdmin, async (req, res) => {
    try {
        const { oldValue, newValue } = req.body;
        if (!oldValue || !newValue) return res.status(400).json({ success: false, error: 'oldValue and newValue are required' });
        const result = await dropdownFb.updateDropdownItem(req.params.category, oldValue, newValue);
        const { dropdownCache } = require('../../../backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Update error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Delete dropdown item — admin only
router.delete('/:category/item', requireAdmin, async (req, res) => {
    try {
        const { value } = req.body;
        if (!value) return res.status(400).json({ success: false, error: 'value is required' });
        const result = await dropdownFb.deleteDropdownItem(req.params.category, value);
        const { dropdownCache } = require('../../../backend/utils/cache');
        dropdownCache.invalidateByPrefix('dropdown:');
        res.json(result);
    } catch (err) {
        console.error('[Dropdown] Delete error:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = router;
