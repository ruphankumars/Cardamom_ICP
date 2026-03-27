/**
 * Analytics Module — Firebase Firestore Backend
 * Drop-in replacement for ../analytics.js (Phase 8, Wave 7)
 *
 * Features:
 * - 3.1 Stock Depletion Forecast
 * - 3.2 Client Behavior Scoring
 * - 3.3 Proactive Insights
 *
 * Optimization: All functions accept optional `prefetchedData` to avoid
 * redundant Firestore reads when multiple analytics are computed together.
 *
 * Collections used:
 *   net_stock_cache  — 3 docs: 'Colour Bold', 'Fruit Bold', 'Rejection'
 *   orders           — pending order book
 *   cart_orders       — today's dispatched orders
 *   packed_orders     — archived dispatched orders
 */

const { getDb } = require('../../src/backend/database/sqliteClient');
const CFG = require('../config');
const { parseSheetDate, formatSheetDate } = require('../utils/date');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const NET_STOCK_CACHE_COL = 'net_stock_cache';
const ORDERS_COL = 'orders';
const CART_COL = 'cart_orders';
const PACKED_COL = 'packed_orders';

/** Grade substitution mapping (similar grades that can fill demand) */
const GRADE_SUBSTITUTIONS = {
    '6.5-8MM': ['7-8MM', '7.5-8MM'],
    '7-8MM': ['6.5-8MM', '7.5-8MM'],
    '7.5-8MM': ['7-8MM', '8MM'],
    '8MM': ['7.5-8MM', '8-9MM'],
    'AGEB': ['AGEB1', 'AGB'],
    'AGEB1': ['AGEB', 'AGB'],
    'AGB': ['AGEB', 'AGEB1'],
};

// ---------------------------------------------------------------------------
// Collection helpers
// ---------------------------------------------------------------------------

function netStockCacheCol() { return getDb().collection(NET_STOCK_CACHE_COL); }
function ordersCol()        { return getDb().collection(ORDERS_COL); }
function cartCol()          { return getDb().collection(CART_COL); }
function packedCol()        { return getDb().collection(PACKED_COL); }

// ---------------------------------------------------------------------------
// Shared prefetch — fetch all 4 collections once
// ---------------------------------------------------------------------------

async function _prefetchAll() {
    const [cacheDocs, ordSnap, cartSnap, packedSnap] = await Promise.all([
        netStockCacheCol().get(),
        ordersCol().get(),
        cartCol().get(),
        packedCol().get(),
    ]);
    return { cacheDocs, ordSnap, cartSnap, packedSnap };
}

// ---------------------------------------------------------------------------
// Internal helpers (accept optional prefetched snapshots)
// ---------------------------------------------------------------------------

/**
 * Build a { [grade]: { total, types } } map from the net_stock_cache collection.
 */
function _buildStockByGrade(cacheDocs) {
    const stockByGrade = {};

    cacheDocs.docs.forEach(doc => {
        const typeName = doc.id; // e.g. 'Colour Bold'
        const data = doc.data();

        const mergeValues = (obj) => {
            if (!obj || typeof obj !== 'object') return;
            for (const [gradeName, rawVal] of Object.entries(obj)) {
                const val = Number(rawVal) || 0;
                if (val <= 0) continue;

                if (!stockByGrade[gradeName]) {
                    stockByGrade[gradeName] = { total: 0, types: {} };
                }
                stockByGrade[gradeName].total += val;
                stockByGrade[gradeName].types[typeName] =
                    (stockByGrade[gradeName].types[typeName] || 0) + val;
            }
        };

        mergeValues(data.netAbsolute);
        mergeValues(data.netVirtual);
    });

    return stockByGrade;
}

/**
 * Build a { [grade]: totalKgs } dispatch map from packed + cart docs
 * for the last `days` days.
 */
function _buildDispatchByGrade(packedSnap, cartSnap, days = 7) {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - days);
    const dispatchByGrade = {};

    const processDocs = (docs) => {
        docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted === true) return;
            const dateField = d.packedDate || d.createdAt || '';
            const parsedDate = parseSheetDate(dateField);
            if (!parsedDate || parsedDate < cutoff) return;

            const grade = String(d.grade || '').trim();
            const kgs = Number(d.kgs) || 0;
            if (grade && kgs > 0) {
                dispatchByGrade[grade] = (dispatchByGrade[grade] || 0) + kgs;
            }
        });
    };

    processDocs(packedSnap.docs);
    processDocs(cartSnap.docs);

    return dispatchByGrade;
}

// ---------------------------------------------------------------------------
// 3.1 Stock Depletion Forecast
// ---------------------------------------------------------------------------

/**
 * Calculates days until each grade depletes based on a 7-day moving average
 * dispatch rate.
 *
 * @param {Object} [prefetchedData] - Optional pre-fetched Firestore snapshots
 */
async function getStockForecast(prefetchedData) {
    try {
        // Use prefetched data or fetch fresh
        const pf = prefetchedData || await _prefetchAll();

        // 1. Current net stock by grade
        const stockByGrade = _buildStockByGrade(pf.cacheDocs);

        if (Object.keys(stockByGrade).length === 0) {
            return { forecasts: [], error: 'No stock data available' };
        }

        // 2. 7-day dispatch rate
        const dispatchByGrade = _buildDispatchByGrade(pf.packedSnap, pf.cartSnap, 7);

        // 3. Build forecasts
        const forecasts = [];

        for (const [grade, stockInfo] of Object.entries(stockByGrade)) {
            const weeklyDispatch = dispatchByGrade[grade] || 0;
            const dailyRate = weeklyDispatch / 7;

            let daysUntilDepletion = null;
            let urgency = 'healthy'; // healthy | warning | critical | slow

            if (dailyRate > 0) {
                daysUntilDepletion = Math.max(0, Math.round(stockInfo.total / dailyRate));

                if (daysUntilDepletion <= 3) {
                    urgency = 'critical';
                } else if (daysUntilDepletion <= 7) {
                    urgency = 'warning';
                }
            } else {
                // No dispatch in 7 days — mark as slow moving
                daysUntilDepletion = 999;
                urgency = 'slow';
            }

            // Substitution suggestions for critically low grades
            let substitutions = [];
            if (urgency === 'critical' && GRADE_SUBSTITUTIONS[grade]) {
                substitutions = GRADE_SUBSTITUTIONS[grade].filter(alt =>
                    stockByGrade[alt] && stockByGrade[alt].total > stockInfo.total * 2
                );
            }

            forecasts.push({
                grade,
                currentStock: Math.round(stockInfo.total),
                dailyRate: Math.round(dailyRate * 10) / 10,
                weeklyDispatch: Math.round(weeklyDispatch),
                daysUntilDepletion,
                urgency,
                substitutions,
            });
        }

        // Sort by urgency (critical first)
        const urgencyOrder = { critical: 0, warning: 1, healthy: 2, slow: 3 };
        forecasts.sort((a, b) => {
            const diff = urgencyOrder[a.urgency] - urgencyOrder[b.urgency];
            if (diff !== 0) return diff;
            return a.daysUntilDepletion - b.daysUntilDepletion;
        });

        return {
            success: true,
            forecasts,
            summary: {
                criticalCount: forecasts.filter(f => f.urgency === 'critical').length,
                warningCount:  forecasts.filter(f => f.urgency === 'warning').length,
                healthyCount:  forecasts.filter(f => f.urgency === 'healthy').length,
                slowCount:     forecasts.filter(f => f.urgency === 'slow').length,
            },
        };
    } catch (err) {
        console.error('[Analytics-FB] getStockForecast error:', err);
        return { success: false, error: err.message, forecasts: [] };
    }
}

// ---------------------------------------------------------------------------
// 3.2 Client Behavior Scoring
// ---------------------------------------------------------------------------

/**
 * Calculates per-client metrics: velocity, activity, churn risk.
 *
 * @param {Object} [prefetchedData] - Optional pre-fetched Firestore snapshots
 */
async function getClientScores(prefetchedData) {
    try {
        // Use prefetched data or fetch fresh
        const pf = prefetchedData || await _prefetchAll();

        const clientMap = {};
        const today = new Date();
        const MS_PER_DAY = 24 * 60 * 60 * 1000;

        // Helper: ingest a Firestore doc into the client map
        const ingestDoc = (doc) => {
            const d = doc.data();
            if (d.isDeleted === true) return;
            const client = String(d.client || '').trim().replace(/\s+/g, ' ');
            if (!client) return;

            if (!clientMap[client]) {
                clientMap[client] = {
                    name: client,
                    orderCount: 0,
                    totalValue: 0,
                    lastOrderDate: null,
                    grades: {},
                };
            }

            const kgs   = Number(d.kgs) || 0;
            const price = Number(d.price) || 0;
            const grade = String(d.grade || '').trim();

            // Use the most relevant date field available
            const dateField = d.packedDate || d.orderDate || d.createdAt || '';
            const orderDate = parseSheetDate(dateField);

            clientMap[client].orderCount++;
            clientMap[client].totalValue += kgs * price;

            if (grade) {
                clientMap[client].grades[grade] =
                    (clientMap[client].grades[grade] || 0) + kgs;
            }

            if (orderDate && (!clientMap[client].lastOrderDate || orderDate > clientMap[client].lastOrderDate)) {
                clientMap[client].lastOrderDate = orderDate;
            }
        };

        // Ingest from all 3 collections (using prefetched snapshots)
        pf.ordSnap.docs.forEach(ingestDoc);
        pf.cartSnap.docs.forEach(ingestDoc);
        pf.packedSnap.docs.forEach(ingestDoc);

        // 3. Calculate scores
        const scores = Object.values(clientMap).map(client => {
            const avgOrderValue = client.orderCount > 0
                ? client.totalValue / client.orderCount
                : 0;

            // Velocity Score (orders * avg order value / 10000, capped at 100)
            const velocityScore = Math.min(
                100,
                Math.round((client.orderCount * avgOrderValue) / 10000)
            );

            // Days since last order
            const daysSinceLastOrder = client.lastOrderDate
                ? Math.floor((today - client.lastOrderDate) / MS_PER_DAY)
                : 999;

            // Churn Risk
            let churnRisk = 'low';
            if (daysSinceLastOrder > 60) {
                churnRisk = 'high';
            } else if (daysSinceLastOrder > 30) {
                churnRisk = 'medium';
            }

            // Top 3 grades by kgs
            const topGrades = Object.entries(client.grades)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 3)
                .map(([grade, kgs]) => ({ grade, kgs }));

            return {
                name: client.name,
                velocityScore,
                orderCount: client.orderCount,
                totalValue: Math.round(client.totalValue),
                avgOrderValue: Math.round(avgOrderValue),
                daysSinceLastOrder,
                churnRisk,
                topGrades,
            };
        });

        // Sort by velocity score descending
        scores.sort((a, b) => b.velocityScore - a.velocityScore);

        return {
            success: true,
            clients: scores,
            summary: {
                totalClients:    scores.length,
                highChurnRisk:   scores.filter(c => c.churnRisk === 'high').length,
                mediumChurnRisk: scores.filter(c => c.churnRisk === 'medium').length,
            },
        };
    } catch (err) {
        console.error('[Analytics-FB] getClientScores error:', err);
        return { success: false, error: err.message, clients: [] };
    }
}

// ---------------------------------------------------------------------------
// 3.3 Proactive Insights
// ---------------------------------------------------------------------------

/**
 * Generates actionable insights based on current stock, pending orders,
 * and dispatch trends.
 *
 * Optimization: Prefetches all data ONCE, then shares with getStockForecast.
 * Previously this function triggered ~8 separate Firestore reads; now it's 4.
 *
 * @param {Object} [prefetchedData] - Optional pre-fetched Firestore snapshots
 */
async function getProactiveInsights(prefetchedData) {
    try {
        // Prefetch all data once (4 reads instead of ~8)
        const pf = prefetchedData || await _prefetchAll();

        const insights = [];

        // Stock forecast data — pass prefetched data to avoid re-reading
        const forecastResult = await getStockForecast(pf);
        const forecasts = forecastResult.forecasts || [];

        // Pending orders (from prefetched orders snapshot)
        const pendingByGrade = {};
        const pendingByClient = {};
        let totalPendingValue = 0;

        pf.ordSnap.docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted === true) return;
            const status = String(d.status || '').toLowerCase();
            if (status !== 'pending') return;

            const grade  = String(d.grade || '').trim();
            const kgs    = Number(d.kgs) || 0;
            const price  = Number(d.price) || 0;
            const client = String(d.client || '').trim();
            const value  = kgs * price;

            if (grade) {
                if (!pendingByGrade[grade]) {
                    pendingByGrade[grade] = { kgs: 0, value: 0, orders: 0 };
                }
                pendingByGrade[grade].kgs += kgs;
                pendingByGrade[grade].value += value;
                pendingByGrade[grade].orders++;
            }

            if (client) {
                if (!pendingByClient[client]) {
                    pendingByClient[client] = { value: 0, orders: 0 };
                }
                pendingByClient[client].value += value;
                pendingByClient[client].orders++;
            }

            totalPendingValue += value;
        });

        // Current stock by grade (from prefetched net_stock_cache)
        const stockByGradeMap = {};
        pf.cacheDocs.docs.forEach(doc => {
            const data = doc.data();

            const sumInto = (obj) => {
                if (!obj || typeof obj !== 'object') return;
                for (const [gradeName, rawVal] of Object.entries(obj)) {
                    const val = Number(rawVal) || 0;
                    stockByGradeMap[gradeName] = (stockByGradeMap[gradeName] || 0) + val;
                }
            };

            sumInto(data.netAbsolute);
            sumInto(data.netVirtual);
        });

        // Insight 1: Dispatch Opportunities (stock available >= pending demand)
        for (const [grade, pending] of Object.entries(pendingByGrade)) {
            const stock = stockByGradeMap[grade] || 0;
            if (stock >= pending.kgs && pending.orders > 0) {
                insights.push({
                    type: 'dispatch_opportunity',
                    priority: 'high',
                    icon: '\u{1F4E6}', // package emoji
                    title: 'Ready to Dispatch',
                    description: `${Math.round(stock)}kg of ${grade} available - ${pending.orders} pending order(s) match!`,
                    grade,
                    action: 'add_to_cart',
                    value: pending.value,
                });
            }
        }

        // Insight 2: Low Stock Alerts
        forecasts.filter(f => f.urgency === 'critical').forEach(forecast => {
            const pendingKgs = pendingByGrade[forecast.grade]?.kgs || 0;

            insights.push({
                type: 'low_stock',
                priority: 'critical',
                icon: '\u26A0\uFE0F', // warning emoji
                title: `Low Stock: ${forecast.grade}`,
                description: `Only ${forecast.currentStock}kg left, depletes in ~${forecast.daysUntilDepletion} days.${pendingKgs > 0 ? ` ${Math.round(pendingKgs)}kg pending orders at risk!` : ''}`,
                grade: forecast.grade,
                action: 'stock_calculator',
                substitutions: forecast.substitutions,
            });
        });

        // Insight 3: High Performer Client
        const topClient = Object.entries(pendingByClient)
            .sort((a, b) => b[1].value - a[1].value)[0];

        if (topClient && topClient[1].value > 100000) {
            insights.push({
                type: 'high_performer',
                priority: 'medium',
                icon: '\u2B50', // star emoji
                title: 'Priority Client',
                description: `${topClient[0]} has \u20B9${(topClient[1].value / 100000).toFixed(1)}L pending - prioritize!`,
                client: topClient[0],
                action: 'view_orders',
                value: topClient[1].value,
            });
        }

        // Insight 4: Unused Inventory (slow-moving grades with > 500 kg)
        forecasts.filter(f => f.urgency === 'slow' && f.currentStock > 500).forEach(forecast => {
            insights.push({
                type: 'unused_inventory',
                priority: 'low',
                icon: '\u{1F4A4}', // zzz emoji
                title: `Slow Moving: ${forecast.grade}`,
                description: `${forecast.currentStock}kg hasn't moved in 7 days. Consider promotional pricing.`,
                grade: forecast.grade,
                action: 'view_stock',
            });
        });

        // Sort by priority
        const priorityOrder = { critical: 0, high: 1, medium: 2, low: 3 };
        insights.sort((a, b) => priorityOrder[a.priority] - priorityOrder[b.priority]);

        return {
            success: true,
            insights: insights.slice(0, 10), // Top 10
            summary: {
                totalInsights: insights.length,
                criticalCount: insights.filter(i => i.priority === 'critical').length,
                totalPendingValue,
            },
        };
    } catch (err) {
        console.error('[Analytics-FB] getProactiveInsights error:', err);
        return { success: false, error: err.message, insights: [] };
    }
}

// ---------------------------------------------------------------------------
// Exports (same surface as ../analytics.js)
// ---------------------------------------------------------------------------

module.exports = {
    getStockForecast,
    getClientScores,
    getProactiveInsights,
    GRADE_SUBSTITUTIONS,
};
