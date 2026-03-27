/**
 * Offer Price Module — Firebase Firestore Backend
 *
 * Collection: offer_prices
 * Stores price offers created by staff for sharing with clients.
 */

const { Router } = require('express');
const { getDb } = require('../firebaseClient');

const router = Router();
const OFFERS_COL = 'offer_prices';

function offersCol() { return getDb().collection(OFFERS_COL); }

// --- Exchange rate cache (1-hour TTL) ---
const RATE_TTL = 60 * 60 * 1000; // 1 hour
let rateCache = { usdToInr: null, fetchedAt: 0 };

async function getUsdToInrRate() {
    const now = Date.now();
    if (rateCache.usdToInr && now < rateCache.fetchedAt + RATE_TTL) {
        return rateCache.usdToInr;
    }
    try {
        const resp = await fetch('https://api.exchangerate-api.com/v4/latest/USD');
        const data = await resp.json();
        const rate = data.rates?.INR;
        if (rate) {
            rateCache = { usdToInr: rate, fetchedAt: now };
            console.log(`[OfferPrice] USD/INR rate refreshed: ${rate}`);
            return rate;
        }
    } catch (err) {
        console.error('[OfferPrice] Exchange rate fetch error:', err.message);
    }
    // Fallback: return cached (even if stale) or a sensible default
    return rateCache.usdToInr || 83.5;
}

// GET /exchange-rate — Current USD→INR rate (cached, 1-hour TTL)
router.get('/exchange-rate', async (req, res) => {
    try {
        const rate = await getUsdToInrRate();
        res.json({ success: true, usdToInr: rate, cachedAt: rateCache.fetchedAt });
    } catch (err) {
        console.error('[OfferPrice] Error fetching exchange rate:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /suggestions — Last 7 days' most recent price per grade per currency
router.get('/suggestions', async (req, res) => {
    try {
        const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
        const snap = await offersCol()
            .where('createdAt', '>=', sevenDaysAgo)
            .orderBy('createdAt', 'desc')
            .limit(100)
            .get();

        const gradeMap = {};
        snap.docs.forEach(doc => {
            const offer = doc.data();
            const currency = offer.currency || 'INR';
            (offer.items || []).forEach(item => {
                const key = `${item.grade}|${currency}`;
                if (item.grade && item.price && !gradeMap[key]) {
                    gradeMap[key] = {
                        grade: item.grade,
                        price: item.price,
                        qty: item.qty || '',
                        date: offer.date,
                        client: offer.client,
                        mode: offer.mode || 'india',
                        currency: currency,
                    };
                }
            });
        });

        const suggestions = Object.values(gradeMap);
        res.json({ success: true, suggestions });
    } catch (err) {
        console.error('[OfferPrice] Error fetching suggestions:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET /analytics — Aggregated offer statistics (separated by currency)
router.get('/analytics', async (req, res) => {
    try {
        const { dateFrom, dateTo } = req.query;
        let query = offersCol().orderBy('createdAt', 'desc');

        if (dateFrom) query = query.where('createdAt', '>=', dateFrom);
        if (dateTo) query = query.where('createdAt', '<=', dateTo);

        const snap = await query.limit(500).get();
        const offers = snap.docs.map(doc => doc.data());

        const uniqueClients = new Set(offers.map(o => o.client));
        const gradeCounts = {};
        const gradePriceSums = { INR: {}, USD: {} };
        const gradePriceCounts = { INR: {}, USD: {} };

        offers.forEach(o => {
            const currency = o.currency || 'INR';
            const bucket = (currency === 'USD') ? 'USD' : 'INR';
            (o.items || []).forEach(item => {
                if (!item.grade) return;
                gradeCounts[item.grade] = (gradeCounts[item.grade] || 0) + 1;
                const price = parseFloat(item.price);
                if (!isNaN(price)) {
                    gradePriceSums[bucket][item.grade] = (gradePriceSums[bucket][item.grade] || 0) + price;
                    gradePriceCounts[bucket][item.grade] = (gradePriceCounts[bucket][item.grade] || 0) + 1;
                }
            });
        });

        let mostOfferedGrade = null;
        let maxCount = 0;
        for (const [grade, count] of Object.entries(gradeCounts)) {
            if (count > maxCount) { maxCount = count; mostOfferedGrade = grade; }
        }

        const avgPriceByGrade = { INR: {}, USD: {} };
        for (const curr of ['INR', 'USD']) {
            for (const [grade, sum] of Object.entries(gradePriceSums[curr])) {
                avgPriceByGrade[curr][grade] = Math.round((sum / gradePriceCounts[curr][grade]) * 100) / 100;
            }
        }

        res.json({
            success: true,
            analytics: {
                totalOffers: offers.length,
                uniqueClients: uniqueClients.size,
                mostOfferedGrade,
                mostOfferedGradeCount: maxCount,
                avgPriceByGrade,
                gradeCounts,
            }
        });
    } catch (err) {
        console.error('[OfferPrice] Error computing analytics:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// GET / — List offer history with optional filters
router.get('/', async (req, res) => {
    try {
        const { client, grade, dateFrom, dateTo, limit: limitParam } = req.query;
        const fetchLimit = parseInt(limitParam) || 50;

        let query = offersCol().orderBy('createdAt', 'desc');

        // Firestore compound filter: client + createdAt range
        if (client) {
            query = offersCol().where('client', '==', client).orderBy('createdAt', 'desc');
            if (dateFrom) query = query.where('createdAt', '>=', dateFrom);
            if (dateTo) query = query.where('createdAt', '<=', dateTo);
        } else {
            if (dateFrom) query = query.where('createdAt', '>=', dateFrom);
            if (dateTo) query = query.where('createdAt', '<=', dateTo);
        }

        // Fetch extra if grade filter needed (post-filter in JS)
        const snap = await query.limit(grade ? 200 : fetchLimit).get();
        let offers = snap.docs.map(doc => doc.data());

        // Post-filter by grade (Firestore can't query nested array objects)
        if (grade) {
            offers = offers.filter(o =>
                o.items && o.items.some(item => item.grade === grade)
            );
            offers = offers.slice(0, fetchLimit);
        }

        res.json(offers);
    } catch (err) {
        console.error('[OfferPrice] Error fetching offers:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// POST / — Create a new offer
router.post('/', async (req, res) => {
    try {
        const { billingFrom, date, client, items, createdBy, mode, currency, paymentTerm } = req.body;
        if (!date || !client || !items || !items.length) {
            return res.status(400).json({ success: false, error: 'date, client, and items are required' });
        }
        const id = `OFR-${Date.now()}`;
        const doc = {
            id,
            billingFrom: billingFrom || 'SYGT',
            date,
            client,
            mode: mode || 'india',           // 'india' | 'worldwide'
            currency: currency || 'INR',      // 'INR' | 'USD'
            paymentTerm: paymentTerm || null,  // 'FOB' | 'CNF' | 'CIF' (worldwide only)
            items, // [{grade, qty, price}]
            createdBy: createdBy || '',
            createdAt: new Date().toISOString(),
        };
        await offersCol().doc(id).set(doc);
        res.json({ success: true, offer: doc });
    } catch (err) {
        console.error('[OfferPrice] Error creating offer:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// DELETE /:id — Hard-delete an offer (admin only)
router.delete('/:id', async (req, res) => {
    try {
        const userRole = (req.user?.role || req.headers['x-role'] || '').toLowerCase();
        if (!['admin', 'superadmin', 'ops'].includes(userRole)) {
            return res.status(403).json({ success: false, error: 'Only admin can delete offers' });
        }
        const { id } = req.params;
        if (!id) return res.status(400).json({ success: false, error: 'Offer ID required' });
        const docRef = offersCol().doc(id);
        const doc = await docRef.get();
        if (!doc.exists) return res.status(404).json({ success: false, error: 'Offer not found' });
        await docRef.delete();
        res.json({ success: true, deletedId: id });
    } catch (err) {
        console.error('[OfferPrice] Error deleting offer:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// DELETE /bulk — Hard-delete multiple offers (admin only)
router.post('/bulk-delete', async (req, res) => {
    try {
        const userRole = (req.user?.role || req.headers['x-role'] || '').toLowerCase();
        if (!['admin', 'superadmin', 'ops'].includes(userRole)) {
            return res.status(403).json({ success: false, error: 'Only admin can delete offers' });
        }
        const { ids } = req.body;
        if (!Array.isArray(ids) || ids.length === 0) {
            return res.status(400).json({ success: false, error: 'Array of offer IDs required' });
        }
        // #68: Firestore batch limit is 500 operations — chunk if needed
        const BATCH_LIMIT = 500;
        let deletedCount = 0;
        for (let i = 0; i < ids.length; i += BATCH_LIMIT) {
            const chunk = ids.slice(i, i + BATCH_LIMIT);
            const batch = getDb().batch();
            for (const id of chunk) {
                batch.delete(offersCol().doc(id));
            }
            await batch.commit();
            deletedCount += chunk.length;
        }
        res.json({ success: true, deletedCount });
    } catch (err) {
        console.error('[OfferPrice] Error bulk-deleting offers:', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

module.exports = { router };
