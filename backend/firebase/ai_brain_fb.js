/**
 * AI Brain Module — Firebase Firestore Backend
 * Drop-in replacement for ../ai_brain.js
 *
 * Features:
 * - Daily Intelligence Briefing
 * - Cross-Pattern Analysis (Stock x Pending x Client x Dispatch)
 * - Recommendation Engine
 * - Pattern Detection
 *
 * Collections used:
 *   orders        — pending order book
 *   cart_orders   — today's / dispatched orders
 *   packed_orders — archived dispatched orders
 *
 * Dependencies:
 *   ./analytics_fb              -> getStockForecast, getClientScores, getProactiveInsights
 *   ./predictive_analytics_fb   -> getDemandTrends
 */

const { getDb } = require('../firebaseClient');
const { parseSheetDate } = require('../utils/date');
const { aiCache } = require('../utils/cache');
const analytics = require('./analytics_fb');
const predictive = require('./predictive_analytics_fb');

const MS_PER_DAY = 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Cache Helper
// ---------------------------------------------------------------------------

/**
 * Get cached value or compute and cache it.
 * Useful for expensive AI operations.
 */
// #67: Track in-flight computations to prevent cache stampede
const _inflight = new Map();

function getCachedOrCompute(key, computeFn, ttl = 5 * 60 * 1000) {
    const cached = aiCache.get(key);
    if (cached !== undefined) {
        return cached;
    }
    // If already computing this key, return the in-flight promise
    if (_inflight.has(key)) {
        return _inflight.get(key);
    }
    const promise = Promise.resolve(computeFn()).then(data => {
        aiCache.set(key, data, ttl);
        _inflight.delete(key);
        return data;
    }).catch(err => {
        _inflight.delete(key);
        throw err;
    });
    _inflight.set(key, promise);
    return promise;
}

// ---------------------------------------------------------------------------
// Daily Intelligence Briefing
// ---------------------------------------------------------------------------

async function generateDailyBriefing() {
    // Use cache key based on today's date to ensure we get fresh data each day
    const today = new Date();
    const cacheKey = `daily-briefing:${today.toISOString().split('T')[0]}`;

    // Check if we have cached result for today
    const cached = aiCache.get(cacheKey);
    if (cached) {
        return cached;
    }

    try {
        const dayOfWeek = today.toLocaleDateString('en-US', { weekday: 'long' });

        const [
            stockForecast,
            clientScores,
            insights,
            demandTrends,
            pendingData,
            dispatchHistory
        ] = await Promise.all([
            analytics.getStockForecast(),
            analytics.getClientScores(),
            analytics.getProactiveInsights(),
            predictive.getDemandTrends(),
            getPendingOrdersSummary(),
            getDispatchHistory(7)
        ]);

        // 1. Priority Actions
        const priorityActions = [];

        if (insights.insights) {
            insights.insights
                .filter(i => i.type === 'dispatch_opportunity')
                .slice(0, 3)
                .forEach(i => {
                    priorityActions.push({
                        type: 'dispatch',
                        icon: '🚚',
                        text: `Dispatch ${i.grade} - ${i.description}`,
                        grade: i.grade,
                        priority: 'high'
                    });
                });
        }

        if (clientScores.clients) {
            clientScores.clients
                .filter(c => c.daysSinceLastOrder > 14 && c.daysSinceLastOrder < 60 && c.totalValue > 100000)
                .slice(0, 2)
                .forEach(c => {
                    priorityActions.push({
                        type: 'contact',
                        icon: '📞',
                        text: `Contact ${c.name} - ${c.daysSinceLastOrder} days since last order`,
                        client: c.name,
                        priority: 'medium'
                    });
                });
        }

        if (stockForecast.forecasts) {
            stockForecast.forecasts
                .filter(f => f.urgency === 'critical')
                .forEach(f => {
                    priorityActions.push({
                        type: 'stock_alert',
                        icon: '⚠️',
                        text: `${f.grade} stock critical (${f.currentStock}kg) - ~${f.daysUntilDepletion} days left`,
                        grade: f.grade,
                        priority: 'critical'
                    });
                });
        }

        // 2. Today's Patterns
        const todayPatterns = [];

        const avgDailyDispatch = dispatchHistory.totalKgs / Math.max(dispatchHistory.days, 1);
        const dayPattern = getDayOfWeekPattern(dispatchHistory, dayOfWeek);
        if (dayPattern.variance !== 0) {
            todayPatterns.push({
                icon: '📅',
                text: `${dayOfWeek} dispatch typically ${dayPattern.variance > 0 ? '+' : ''}${Math.round(dayPattern.variance)}% ${dayPattern.variance > 0 ? 'higher' : 'lower'} than average`
            });
        }

        if (demandTrends.trends && demandTrends.trends.length > 0) {
            const risingGrades = demandTrends.trends.filter(t => t.momentum === 'rising');
            if (risingGrades.length > 0) {
                const top = risingGrades[0];
                todayPatterns.push({
                    icon: '📈',
                    text: `Best performer this week: ${top.grade} (+${top.percentageChange}%)`
                });
            }
        }

        // 3. Predictions
        const predictions = [];

        predictions.push({
            icon: '📊',
            text: `Expected dispatch today: ${Math.round(avgDailyDispatch * (1 + (dayPattern.variance / 100)))} kg`
        });

        if (stockForecast.forecasts) {
            const warningGrades = stockForecast.forecasts
                .filter(f => f.urgency === 'warning')
                .slice(0, 2);
            warningGrades.forEach(f => {
                predictions.push({
                    icon: '⏳',
                    text: `${f.grade} may run low by ${getDateAfterDays(f.daysUntilDepletion)}`
                });
            });
        }

        if (clientScores.clients) {
            const dueClients = clientScores.clients
                .filter(c => c.daysSinceLastOrder >= 7 && c.daysSinceLastOrder <= 14 && c.orderCount >= 3)
                .slice(0, 2);
            dueClients.forEach(c => {
                predictions.push({
                    icon: '👤',
                    text: `${c.name} likely due for order (avg pattern: every ${Math.round(c.daysSinceLastOrder * 0.8)} days)`
                });
            });
        }

        // 4. Opportunities
        const opportunities = [];

        if (stockForecast.forecasts) {
            const highStock = stockForecast.forecasts
                .filter(f => f.urgency === 'slow' && f.currentStock > 1000)
                .slice(0, 2);
            highStock.forEach(f => {
                opportunities.push({
                    icon: '💡',
                    text: `${f.grade} surplus (${f.currentStock}kg) - find new buyers`,
                    grade: f.grade
                });
            });
        }

        if (clientScores.clients && stockForecast.forecasts) {
            const activeClients = clientScores.clients.filter(c => c.daysSinceLastOrder < 30);
            const highStockGrades = stockForecast.forecasts
                .filter(f => f.currentStock > 2000 && f.urgency !== 'critical')
                .map(f => f.grade);

            activeClients.slice(0, 3).forEach(client => {
                const clientGrades = client.topGrades.map(g => g.grade);
                const newGrades = highStockGrades.filter(g => !clientGrades.includes(g));
                if (newGrades.length > 0) {
                    opportunities.push({
                        icon: '🎯',
                        text: `Offer ${newGrades[0]} to ${client.name} (they haven't tried it)`,
                        client: client.name,
                        grade: newGrades[0]
                    });
                }
            });
        }

        // 5. Summary Stats
        const summary = {
            totalStock: stockForecast.forecasts?.reduce((sum, f) => sum + Math.max(0, f.currentStock), 0) || 0,
            totalPending: pendingData.totalKgs,
            pendingValue: pendingData.totalValue,
            activeClients: clientScores.clients?.filter(c => c.daysSinceLastOrder < 30).length || 0,
            criticalGrades: stockForecast.summary?.criticalCount || 0,
            dispatchLast7Days: dispatchHistory.totalKgs
        };

        const result = {
            success: true,
            date: today.toISOString().split('T')[0],
            dayOfWeek,
            priorityActions: priorityActions.slice(0, 5),
            todayPatterns: todayPatterns.slice(0, 4),
            predictions: predictions.slice(0, 4),
            opportunities: opportunities.slice(0, 4),
            summary
        };

        // Cache result for rest of the day (until midnight)
        const msUntilMidnight = MS_PER_DAY - (today.getHours() * 60 * 60 * 1000 + today.getMinutes() * 60 * 1000 + today.getSeconds() * 1000);
        aiCache.set(cacheKey, result, msUntilMidnight);

        return result;

    } catch (err) {
        console.error('[AI Brain-FB] generateDailyBriefing error:', err.message);
        return { success: false, error: err.message };
    }
}

// ---------------------------------------------------------------------------
// Deep Stock Analysis for a specific grade
// ---------------------------------------------------------------------------

async function analyzeGrade(grade) {
    // Use grade as cache key for analysis
    const cacheKey = `grade-analysis:${grade}`;

    // Check if we have cached result
    const cached = aiCache.get(cacheKey);
    if (cached) {
        return cached;
    }

    try {
        const [stockForecast, pendingData, dispatchHistory, clientScores] = await Promise.all([
            analytics.getStockForecast(),
            getPendingOrdersForGrade(grade),
            getDispatchHistoryForGrade(grade, 30),
            analytics.getClientScores()
        ]);

        const forecast = stockForecast.forecasts?.find(f => f.grade === grade);

        const clientsForGrade = clientScores.clients?.filter(c =>
            c.topGrades.some(g => g.grade === grade)
        ) || [];

        const recommendations = [];

        if (forecast) {
            if (forecast.urgency === 'critical') {
                recommendations.push({
                    priority: 'critical',
                    icon: '🚨',
                    text: 'Urgent: Consider substitution or expedited restock'
                });
            }

            if (forecast.urgency === 'slow' && forecast.currentStock > 1000) {
                recommendations.push({
                    priority: 'medium',
                    icon: '📢',
                    text: `Push to ${clientsForGrade.length} clients who buy this grade`
                });
            }
        }

        if (pendingData.orders.length > 0 && forecast?.currentStock >= pendingData.totalKgs) {
            recommendations.push({
                priority: 'high',
                icon: '✅',
                text: `Can fulfill all ${pendingData.orders.length} pending orders immediately`
            });
        }

        const result = {
            success: true,
            grade,
            currentStock: forecast?.currentStock || 0,
            urgency: forecast?.urgency || 'unknown',
            daysUntilDepletion: forecast?.daysUntilDepletion,
            dailyRate: forecast?.dailyRate || 0,
            pendingOrders: pendingData,
            dispatchHistory: {
                last30Days: dispatchHistory.totalKgs,
                avgDaily: dispatchHistory.totalKgs / 30
            },
            topClients: clientsForGrade.slice(0, 5).map(c => ({
                name: c.name,
                totalOrdered: c.topGrades.find(g => g.grade === grade)?.kgs || 0,
                lastOrderDays: c.daysSinceLastOrder
            })),
            recommendations
        };

        // Cache for 5 minutes
        aiCache.set(cacheKey, result, 5 * 60 * 1000);

        return result;

    } catch (err) {
        console.error('[AI Brain-FB] analyzeGrade error:', err.message);
        return { success: false, error: err.message };
    }
}

// ---------------------------------------------------------------------------
// Deep Client Analysis
// ---------------------------------------------------------------------------

async function analyzeClient(clientName) {
    // Use client name as cache key for analysis
    const cacheKey = `client-analysis:${clientName.toLowerCase()}`;

    // Check if we have cached result
    const cached = aiCache.get(cacheKey);
    if (cached) {
        return cached;
    }

    try {
        const [clientScores, pendingData, stockForecast] = await Promise.all([
            analytics.getClientScores(),
            getPendingOrdersForClient(clientName),
            analytics.getStockForecast()
        ]);

        const client = clientScores.clients?.find(c =>
            c.name.toLowerCase() === clientName.toLowerCase()
        );

        if (!client) {
            return { success: false, error: 'Client not found' };
        }

        const rank = (clientScores.clients?.findIndex(c => c.name === client.name) || 0) + 1;
        const totalClients = clientScores.clients?.length || 1;

        const recommendations = [];

        pendingData.orders.forEach(order => {
            const gradeStock = stockForecast.forecasts?.find(f => f.grade === order.grade);
            if (gradeStock && gradeStock.currentStock >= order.kgs) {
                recommendations.push({
                    priority: 'high',
                    icon: '⚡',
                    action: 'dispatch',
                    text: `Dispatch ${order.kgs}kg ${order.grade} NOW (in stock!)`,
                    grade: order.grade,
                    qty: order.kgs
                });
            }
        });

        if (client.daysSinceLastOrder > 7) {
            recommendations.push({
                priority: 'medium',
                icon: '📞',
                action: 'contact',
                text: `Follow up - ${client.daysSinceLastOrder} days since last interaction`
            });
        }

        const clientGrades = client.topGrades.map(g => g.grade);
        const highStockGrades = stockForecast.forecasts
            ?.filter(f => f.currentStock > 2000 && !clientGrades.includes(f.grade))
            .slice(0, 2) || [];

        highStockGrades.forEach(f => {
            recommendations.push({
                priority: 'low',
                icon: '🎯',
                action: 'upsell',
                text: `Offer ${f.grade} (${f.currentStock}kg available, client hasn't tried)`
            });
        });

        const result = {
            success: true,
            client: {
                name: client.name,
                score: client.velocityScore,
                rank,
                totalClients,
                churnRisk: client.churnRisk
            },
            financial: {
                totalValue: client.totalValue,
                avgOrderValue: client.avgOrderValue,
                orderCount: client.orderCount,
                pendingValue: pendingData.totalValue,
                pendingOrders: pendingData.orders.length
            },
            patterns: {
                topGrades: client.topGrades,
                daysSinceLastOrder: client.daysSinceLastOrder
            },
            pendingOrders: pendingData.orders,
            recommendations
        };

        // Cache for 5 minutes
        aiCache.set(cacheKey, result, 5 * 60 * 1000);

        return result;

    } catch (err) {
        console.error('[AI Brain-FB] analyzeClient error:', err.message);
        return { success: false, error: err.message };
    }
}

// ---------------------------------------------------------------------------
// Get all recommendations across all dimensions
// ---------------------------------------------------------------------------

async function getAllRecommendations() {
    // Cache based on date since recommendations change daily
    const today = new Date();
    const cacheKey = `all-recommendations:${today.toISOString().split('T')[0]}`;

    // Check if we have cached result for today
    const cached = aiCache.get(cacheKey);
    if (cached) {
        return cached;
    }

    try {
        const briefing = await generateDailyBriefing();

        if (!briefing.success) {
            return { success: false, error: briefing.error };
        }

        const allRecommendations = [
            ...briefing.priorityActions.map(a => ({ ...a, category: 'priority' })),
            ...briefing.opportunities.map(o => ({ ...o, category: 'opportunity' }))
        ];

        const result = {
            success: true,
            recommendations: allRecommendations,
            summary: briefing.summary
        };

        // Cache result for rest of the day
        const msUntilMidnight = MS_PER_DAY - (today.getHours() * 60 * 60 * 1000 + today.getMinutes() * 60 * 1000 + today.getSeconds() * 1000);
        aiCache.set(cacheKey, result, msUntilMidnight);

        return result;

    } catch (err) {
        console.error('[AI Brain-FB] getAllRecommendations error:', err.message);
        return { success: false, error: err.message };
    }
}

// ---------------------------------------------------------------------------
// Helper Functions (all read from Firestore)
// ---------------------------------------------------------------------------

async function getPendingOrdersSummary() {
    try {
        const db = getDb();
        const orderSnap = await db.collection('orders').get();
        let totalKgs = 0;
        let totalValue = 0;
        let orderCount = 0;

        if (!orderSnap.empty) {
            orderSnap.docs.forEach(doc => {
                const d = doc.data();
                if (d.isDeleted === true) return;
                const status = String(d.status || '').toLowerCase();
                if (status !== 'pending') return;

                const kgs = Number(d.kgs) || 0;
                const price = Number(d.price) || 0;

                totalKgs += kgs;
                totalValue += kgs * price;
                orderCount++;
            });
        }

        return { totalKgs, totalValue, orderCount };
    } catch (err) {
        return { totalKgs: 0, totalValue: 0, orderCount: 0 };
    }
}

async function getPendingOrdersForGrade(grade) {
    try {
        const db = getDb();
        const orderSnap = await db.collection('orders').get();
        const orders = [];
        let totalKgs = 0;
        let totalValue = 0;

        if (!orderSnap.empty) {
            orderSnap.docs.forEach(doc => {
                const d = doc.data();
                if (d.isDeleted === true) return;
                const status = String(d.status || '').toLowerCase();
                const rowGrade = String(d.grade || '').trim();
                if (status !== 'pending' || rowGrade !== grade) return;

                const kgs = Number(d.kgs) || 0;
                const price = Number(d.price) || 0;
                const client = String(d.client || '').trim();

                orders.push({ client, kgs, price, value: kgs * price });
                totalKgs += kgs;
                totalValue += kgs * price;
            });
        }

        return { orders, totalKgs, totalValue };
    } catch (err) {
        return { orders: [], totalKgs: 0, totalValue: 0 };
    }
}

async function getPendingOrdersForClient(clientName) {
    try {
        const db = getDb();
        const orderSnap = await db.collection('orders').get();
        const orders = [];
        let totalKgs = 0;
        let totalValue = 0;

        if (!orderSnap.empty) {
            orderSnap.docs.forEach(doc => {
                const d = doc.data();
                if (d.isDeleted === true) return;
                const status = String(d.status || '').toLowerCase();
                const client = String(d.client || '').trim();
                if (status !== 'pending' || client.toLowerCase() !== clientName.toLowerCase()) return;

                const grade = String(d.grade || '').trim();
                const kgs = Number(d.kgs) || 0;
                const price = Number(d.price) || 0;

                orders.push({ grade, kgs, price, value: kgs * price });
                totalKgs += kgs;
                totalValue += kgs * price;
            });
        }

        return { orders, totalKgs, totalValue };
    } catch (err) {
        return { orders: [], totalKgs: 0, totalValue: 0 };
    }
}

async function getDispatchHistory(days) {
    try {
        const cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - days);

        const db = getDb();
        const packedSnap = await db.collection('packed_orders').get();
        let totalKgs = 0;
        const byDay = {};

        if (!packedSnap.empty) {
            packedSnap.docs.forEach(doc => {
                const d = doc.data();
                if (d.isDeleted === true) return;
                const packedDate = parseSheetDate(d.packedDate);
                if (!packedDate || packedDate < cutoff) return;

                const kgs = Number(d.kgs) || 0;
                totalKgs += kgs;

                const dayKey = packedDate.toLocaleDateString('en-US', { weekday: 'long' });
                byDay[dayKey] = (byDay[dayKey] || 0) + kgs;
            });
        }

        return { totalKgs, days, byDay };
    } catch (err) {
        return { totalKgs: 0, days, byDay: {} };
    }
}

async function getDispatchHistoryForGrade(grade, days) {
    try {
        const cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - days);

        const db = getDb();
        const packedSnap = await db.collection('packed_orders').get();
        let totalKgs = 0;

        if (!packedSnap.empty) {
            packedSnap.docs.forEach(doc => {
                const d = doc.data();
                if (d.isDeleted === true) return;
                const packedDate = parseSheetDate(d.packedDate);
                const rowGrade = String(d.grade || '').trim();
                if (!packedDate || packedDate < cutoff || rowGrade !== grade) return;

                totalKgs += Number(d.kgs) || 0;
            });
        }

        return { totalKgs };
    } catch (err) {
        return { totalKgs: 0 };
    }
}

function getDayOfWeekPattern(dispatchHistory, dayOfWeek) {
    const totalKgs = dispatchHistory.totalKgs || 1;
    const days = dispatchHistory.days || 7;
    const avgDaily = totalKgs / days;
    const dayKgs = dispatchHistory.byDay?.[dayOfWeek] || avgDaily;

    const daysOfThisWeekday = Math.ceil(days / 7);
    const avgForThisDay = dayKgs / daysOfThisWeekday;

    const variance = avgDaily > 0 ? ((avgForThisDay - avgDaily) / avgDaily) * 100 : 0;

    return { variance: Math.round(variance), avgForThisDay };
}

function getDateAfterDays(days) {
    const date = new Date();
    date.setDate(date.getDate() + days);
    return date.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
}

module.exports = {
    generateDailyBriefing,
    analyzeGrade,
    analyzeClient,
    getAllRecommendations
};
