/**
 * Predictive Analytics Module — Firebase Firestore Backend
 * Drop-in replacement for ../predictive_analytics.js
 *
 * Features:
 * - Demand pattern recognition
 * - Weekly/Seasonal trend analysis
 * - Projected stock needs
 *
 * Collections used:
 *   packed_orders  — archived dispatched orders (last 90 days)
 *   cart_orders    — today's / recent dispatched orders
 */

const { getDb } = require('../../src/backend/database/sqliteClient');
const { parseSheetDate } = require('../utils/date');

// ---------------------------------------------------------------------------
// Collection helpers
// ---------------------------------------------------------------------------

function packedCol() { return getDb().collection('packed_orders'); }
function cartCol()   { return getDb().collection('cart_orders'); }

// ---------------------------------------------------------------------------
// 4.1 Predictive Analytics Engine
// ---------------------------------------------------------------------------

/**
 * Analyzes historical dispatch data to identify trends and patterns
 */
async function getDemandTrends() {
    try {
        const cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - 90);

        // Fetch packed_orders and cart_orders from Firestore
        const [packedSnap, cartSnap] = await Promise.all([
            packedCol().get(),
            cartCol().get()
        ]);

        const dispatchHistory = [];

        const processSnapshot = (snap) => {
            if (snap.empty) return;
            snap.docs.forEach(doc => {
                const d = doc.data();
                if (d.isDeleted === true) return;
                const date = parseSheetDate(d.packedDate);
                if (!date || date < cutoff) return;

                dispatchHistory.push({
                    date,
                    grade: String(d.grade || '').trim(),
                    kgs: Number(d.kgs) || 0
                });
            });
        };

        processSnapshot(packedSnap);
        processSnapshot(cartSnap);

        if (dispatchHistory.length === 0) {
            return { success: true, trends: [], message: 'Insufficient historical data' };
        }

        // 2. Aggregate by Week and Grade
        const gradeWeeklyData = {}; // { grade: { weekIdx: totalKgs } }
        const startOf90Days = new Date(cutoff);

        dispatchHistory.forEach(item => {
            const weekIdx = Math.floor((item.date - startOf90Days) / (7 * 24 * 60 * 60 * 1000));
            if (!gradeWeeklyData[item.grade]) {
                gradeWeeklyData[item.grade] = {};
            }
            gradeWeeklyData[item.grade][weekIdx] = (gradeWeeklyData[item.grade][weekIdx] || 0) + item.kgs;
        });

        // 3. Calculate Trends (Simple Linear Regression / Slope)
        const trends = [];

        for (const [grade, weeks] of Object.entries(gradeWeeklyData)) {
            const dataPoints = Object.keys(weeks).map(w => Number(w)).sort((a, b) => a - b);
            if (dataPoints.length < 2) continue;

            const lastWeekIdx = dataPoints[dataPoints.length - 1];
            const firstWeekIdx = dataPoints[0];
            const totalWeeks = lastWeekIdx - firstWeekIdx + 1;

            const totalVolume = Object.values(weeks).reduce((a, b) => a + b, 0);
            const avgWeeklyVolume = totalVolume / totalWeeks;

            const recentVolume = weeks[lastWeekIdx] || 0;
            const prevVolume = weeks[lastWeekIdx - 1] || avgWeeklyVolume;
            const percentageChange = prevVolume > 0 ? ((recentVolume - prevVolume) / prevVolume) * 100 : 0;

            let momentum = 'stable';
            if (percentageChange > 15) momentum = 'rising';
            if (percentageChange < -15) momentum = 'falling';

            const projectedNextWeek = Math.max(0, recentVolume * (1 + (percentageChange / 100)));

            trends.push({
                grade,
                avgWeeklyVolume: Math.round(avgWeeklyVolume),
                recentVolume: Math.round(recentVolume),
                percentageChange: Math.round(percentageChange),
                momentum,
                projectedNextWeek: Math.round(projectedNextWeek)
            });
        }

        return {
            success: true,
            trends: trends.sort((a, b) => b.avgWeeklyVolume - a.avgWeeklyVolume),
            periodDays: 90
        };

    } catch (err) {
        console.error('[Predictive-FB] getDemandTrends error:', err.message);
        return { success: false, error: err.message };
    }
}

/**
 * Seasonal Trend Analysis
 * Compares current volume with historical month-over-month averages
 */
async function getSeasonalAnalysis() {
    try {
        // Cap to last 2 years to prevent unbounded memory usage
        const twoYearsAgo = new Date();
        twoYearsAgo.setFullYear(twoYearsAgo.getFullYear() - 2);

        const [packedSnap, cartSnap] = await Promise.all([
            packedCol().get(),
            cartCol().get()
        ]);

        const monthlyVolume = {}; // { 'Jan': totalKgs, ... }
        const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

        const processSnapshot = (snap) => {
            if (snap.empty) return;
            snap.docs.forEach(doc => {
                const d = doc.data();
                if (d.isDeleted === true) return;
                const date = parseSheetDate(d.packedDate);
                if (!date || date < twoYearsAgo) return;
                const monthKey = monthNames[date.getMonth()];
                monthlyVolume[monthKey] = (monthlyVolume[monthKey] || 0) + (Number(d.kgs) || 0);
            });
        };

        processSnapshot(packedSnap);
        processSnapshot(cartSnap);

        if (Object.keys(monthlyVolume).length === 0) {
            return { success: true, seasonalFactor: 1.0, peakMonth: 'N/A', message: 'Insufficient data for seasonal analysis.' };
        }

        // Find peak month and calculate seasonal factor
        const totalKgs = Object.values(monthlyVolume).reduce((a, b) => a + b, 0);
        const avgMonthly = totalKgs / Object.keys(monthlyVolume).length;
        let peakMonth = 'N/A';
        let peakVolume = 0;
        for (const [month, kgs] of Object.entries(monthlyVolume)) {
            if (kgs > peakVolume) { peakVolume = kgs; peakMonth = month; }
        }

        const currentMonth = monthNames[new Date().getMonth()];
        const currentVolume = monthlyVolume[currentMonth] || 0;
        const seasonalFactor = avgMonthly > 0 ? Math.round((currentVolume / avgMonthly) * 100) / 100 : 1.0;

        const trend = seasonalFactor > 1.1 ? 'peak' : (seasonalFactor < 0.9 ? 'off-peak' : 'average');
        const message = `Current month (${currentMonth}) is ${trend} season. Peak month: ${peakMonth}.`;

        return { success: true, seasonalFactor, peakMonth, currentMonth, monthlyVolume, message };
    } catch (err) {
        console.error('[Predictive-FB] getSeasonalAnalysis error:', err.message);
        return { success: false, error: err.message };
    }
}

module.exports = {
    getDemandTrends,
    getSeasonalAnalysis
};
