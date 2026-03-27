/**
 * Pricing Intelligence Module - Phase 4.2
 * Calculates suggested prices based on:
 * - Historical sales prices (most recent actual sale per grade)
 * - Current stock levels (low stock = higher price)
 * - Demand momentum (rising demand = higher price)
 */

const analytics = require('./firebase/analytics_fb');
const predictive = require('./firebase/predictive_analytics_fb');
const dashboard = require('./firebase/dashboard_fb');
const { getDb } = require('./firebaseClient');
const { parseSheetDate } = require('./utils/date');

/**
 * Fetches the most recent sale price per grade from packed_orders.
 * Returns { 'GRADE': price, ... }
 */
async function getRecentPricesPerGrade() {
    const priceMap = {};
    try {
        const packedSnap = await getDb().collection('packed_orders').get();
        if (packedSnap.empty) return priceMap;

        // Track latest date + price per grade
        const gradeLatest = {}; // { grade: { date: Date, price: Number } }
        packedSnap.docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted === true) return;
            const grade = String(d.grade || '').trim();
            const price = Number(d.price) || 0;
            if (!grade || price <= 0) return;

            const date = parseSheetDate(d.packedDate);
            if (!date) return;

            if (!gradeLatest[grade] || date > gradeLatest[grade].date) {
                gradeLatest[grade] = { date, price };
            }
        });

        for (const [grade, info] of Object.entries(gradeLatest)) {
            priceMap[grade] = info.price;
        }
    } catch (err) {
        console.error('[Pricing] getRecentPricesPerGrade error:', err.message);
    }
    return priceMap;
}

/**
 * Get suggested prices for all grades
 */
async function getSuggestedPrices() {
    try {
        const [forecastResult, trends, currentStock, recentPrices] = await Promise.all([
            analytics.getStockForecast(),
            predictive.getDemandTrends(),
            dashboard.getStockTotals(),
            getRecentPricesPerGrade()
        ]);

        const forecasts = forecastResult.forecasts || [];
        const suggestions = [];

        for (const grade of Object.keys(currentStock)) {
            const forecast = forecasts.find(f => f.grade === grade);
            const trend = (trends.trends || []).find(t => t.grade === grade);

            // Base price: most recent actual sale price, fallback 0 (skip if no history)
            const basePrice = recentPrices[grade];
            if (!basePrice || basePrice <= 0) continue;

            // Adjustments:
            // 1. Critical stock (< 3 days): +10%
            // 2. Warning stock: +5%
            // 3. Rising demand: +5%
            // 4. Slow moving inventory: -5%
            let adjustment = 0;
            const reasons = [];

            if (forecast && forecast.urgency === 'critical') {
                adjustment += 0.10;
                reasons.push('Limited stock availability');
            } else if (forecast && forecast.urgency === 'warning') {
                adjustment += 0.05;
                reasons.push('Stock depleting fast');
            }

            if (trend && trend.momentum === 'rising') {
                adjustment += 0.05;
                reasons.push('High market demand');
            }

            if (forecast && forecast.urgency === 'slow') {
                adjustment -= 0.05;
                reasons.push('Slow moving inventory');
            }

            if (reasons.length === 0) {
                reasons.push('Stable market conditions');
            }

            const suggestedPrice = Math.round(basePrice * (1 + adjustment));

            suggestions.push({
                grade,
                currentPrice: basePrice,
                suggestedPrice,
                adjustmentPercent: Math.round(adjustment * 100),
                reasons,
                momentum: trend ? trend.momentum : 'stable',
                stockLevel: currentStock[grade] || 0
            });
        }

        return {
            success: true,
            suggestions: suggestions.sort((a, b) => b.adjustmentPercent - a.adjustmentPercent)
        };

    } catch (err) {
        console.error('[Pricing] getSuggestedPrices error:', err);
        return { success: false, error: err.message };
    }
}

module.exports = {
    getSuggestedPrices
};
