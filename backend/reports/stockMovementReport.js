/**
 * Stock Movement Report Generator
 *
 * Generates an Excel report showing purchases, dispatches, and adjustments
 * for a custom date range, optionally filtered by stock type.
 *
 * Data sources:
 *   - live_stock_entries (purchases)
 *   - cart_orders + packed_orders (dispatches)
 *   - stock_adjustments (manual adjustments)
 */

const ExcelJS = require('exceljs');
const { getDb } = require('../firebaseClient');
const CFG = require('../config');
const { COMPANY } = require('./pdfHelpers');

/**
 * Fetch stock movements for a date range
 */
async function fetchMovements(startDate, endDate, typeFilter) {
    const db = getDb();

    // Purchases from live_stock_entries
    const purchaseSnap = await db.collection('live_stock_entries').get();
    const purchases = [];
    purchaseSnap.docs.forEach(doc => {
        const d = doc.data();
        const entryDate = (d.date || d.entryDate || '').split('T')[0];
        if (entryDate >= startDate && entryDate <= endDate) {
            if (!typeFilter || (d.type && d.type.toLowerCase().includes(typeFilter.toLowerCase()))) {
                purchases.push({ ...d, id: doc.id, movementType: 'Purchase' });
            }
        }
    });

    // Dispatches from cart_orders and packed_orders
    const dispatches = [];
    for (const col of ['cart_orders', 'packed_orders']) {
        const snap = await db.collection(col).get();
        snap.docs.forEach(doc => {
            const d = doc.data();
            const orderDate = (d.orderDate || d.cartDate || d.packedDate || '').split('T')[0];
            if (orderDate >= startDate && orderDate <= endDate) {
                if (!typeFilter || !d.grade || true) { // dispatches don't have a 'type' field typically
                    dispatches.push({ ...d, id: doc.id, movementType: 'Dispatch', _source: col });
                }
            }
        });
    }

    // Adjustments from stock_adjustments
    const adjSnap = await db.collection('stock_adjustments').get();
    const adjustments = [];
    adjSnap.docs.forEach(doc => {
        const d = doc.data();
        const adjDate = (d.date || d.createdAt || '').split('T')[0];
        if (adjDate >= startDate && adjDate <= endDate) {
            if (!typeFilter || (d.type && d.type.toLowerCase().includes(typeFilter.toLowerCase()))) {
                adjustments.push({ ...d, id: doc.id, movementType: 'Adjustment' });
            }
        }
    });

    return { purchases, dispatches, adjustments };
}

/**
 * Generate stock movement Excel report
 */
async function generate(params) {
    const { startDate, endDate, type: typeFilter = '' } = params;

    if (!startDate || !endDate) {
        throw new Error('startDate and endDate are required');
    }

    const { purchases, dispatches, adjustments } = await fetchMovements(startDate, endDate, typeFilter);

    const workbook = new ExcelJS.Workbook();
    workbook.creator = COMPANY.name;
    workbook.created = new Date();

    const headerStyle = {
        font: { bold: true, color: { argb: 'FFFFFFFF' } },
        fill: { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF2E7D32' } },
        alignment: { horizontal: 'center' }
    };

    // ---- Purchases sheet ----
    const purchaseSheet = workbook.addWorksheet('Purchases');
    purchaseSheet.mergeCells('A1:F1');
    purchaseSheet.getCell('A1').value = `Stock Purchases: ${startDate} to ${endDate}${typeFilter ? ` (${typeFilter})` : ''}`;
    purchaseSheet.getCell('A1').font = { bold: true, size: 13 };

    const purchaseHeaders = ['Date', 'Type', 'Bold Qty', 'Float Qty', 'Medium Qty', 'Notes'];
    purchaseHeaders.forEach((h, i) => {
        const cell = purchaseSheet.getCell(3, i + 1);
        cell.value = h;
        Object.assign(cell, headerStyle);
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    purchases.sort((a, b) => (a.date || '').localeCompare(b.date || ''));
    purchases.forEach((p, i) => {
        const row = i + 4;
        purchaseSheet.getCell(row, 1).value = p.date || p.entryDate || '';
        purchaseSheet.getCell(row, 2).value = p.type || '';
        purchaseSheet.getCell(row, 3).value = Number(p.boldQty) || 0;
        purchaseSheet.getCell(row, 3).numFmt = '#,##0.00';
        purchaseSheet.getCell(row, 4).value = Number(p.floatQty) || 0;
        purchaseSheet.getCell(row, 4).numFmt = '#,##0.00';
        purchaseSheet.getCell(row, 5).value = Number(p.mediumQty) || 0;
        purchaseSheet.getCell(row, 5).numFmt = '#,##0.00';
        purchaseSheet.getCell(row, 6).value = p.notes || '';
    });

    purchaseSheet.getColumn(1).width = 15;
    purchaseSheet.getColumn(2).width = 18;
    purchaseSheet.getColumn(3).width = 15;
    purchaseSheet.getColumn(4).width = 15;
    purchaseSheet.getColumn(5).width = 15;
    purchaseSheet.getColumn(6).width = 25;

    // ---- Dispatches sheet ----
    const dispatchSheet = workbook.addWorksheet('Dispatches');
    dispatchSheet.mergeCells('A1:G1');
    dispatchSheet.getCell('A1').value = `Stock Dispatches: ${startDate} to ${endDate}`;
    dispatchSheet.getCell('A1').font = { bold: true, size: 13 };

    const dispatchHeaders = ['Date', 'Client', 'Grade', 'Bag/Box', 'Qty', 'Kgs', 'Brand'];
    dispatchHeaders.forEach((h, i) => {
        const cell = dispatchSheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    dispatches.sort((a, b) => (a.orderDate || '').localeCompare(b.orderDate || ''));
    dispatches.forEach((d, i) => {
        const row = i + 4;
        dispatchSheet.getCell(row, 1).value = d.orderDate || d.cartDate || d.packedDate || '';
        dispatchSheet.getCell(row, 2).value = d.client || '';
        dispatchSheet.getCell(row, 3).value = d.grade || '';
        dispatchSheet.getCell(row, 4).value = d.bagbox || '';
        dispatchSheet.getCell(row, 5).value = Number(d.no) || 0;
        dispatchSheet.getCell(row, 6).value = Number(d.kgs) || 0;
        dispatchSheet.getCell(row, 6).numFmt = '#,##0.00';
        dispatchSheet.getCell(row, 7).value = d.brand || '';
    });

    dispatchSheet.getColumn(1).width = 15;
    dispatchSheet.getColumn(2).width = 20;
    dispatchSheet.getColumn(3).width = 18;
    dispatchSheet.getColumn(4).width = 12;
    dispatchSheet.getColumn(5).width = 10;
    dispatchSheet.getColumn(6).width = 15;
    dispatchSheet.getColumn(7).width = 15;

    // ---- Adjustments sheet ----
    const adjSheet = workbook.addWorksheet('Adjustments');
    adjSheet.mergeCells('A1:F1');
    adjSheet.getCell('A1').value = `Stock Adjustments: ${startDate} to ${endDate}`;
    adjSheet.getCell('A1').font = { bold: true, size: 13 };

    const adjHeaders = ['Date', 'Type', 'Grade', 'Qty (kg)', 'Direction', 'Reason'];
    adjHeaders.forEach((h, i) => {
        const cell = adjSheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    adjustments.sort((a, b) => (a.date || '').localeCompare(b.date || ''));
    adjustments.forEach((a, i) => {
        const row = i + 4;
        adjSheet.getCell(row, 1).value = a.date || a.createdAt || '';
        adjSheet.getCell(row, 2).value = a.type || '';
        adjSheet.getCell(row, 3).value = a.grade || '';
        adjSheet.getCell(row, 4).value = Number(a.qty || a.adjustmentKgs) || 0;
        adjSheet.getCell(row, 4).numFmt = '#,##0.00';
        adjSheet.getCell(row, 5).value = a.direction || (Number(a.qty || a.adjustmentKgs) >= 0 ? 'Add' : 'Subtract');
        adjSheet.getCell(row, 6).value = a.reason || a.notes || '';
    });

    adjSheet.getColumn(1).width = 15;
    adjSheet.getColumn(2).width = 18;
    adjSheet.getColumn(3).width = 18;
    adjSheet.getColumn(4).width = 15;
    adjSheet.getColumn(5).width = 12;
    adjSheet.getColumn(6).width = 30;

    // ---- Summary sheet ----
    const summarySheet = workbook.addWorksheet('Summary');
    summarySheet.mergeCells('A1:D1');
    summarySheet.getCell('A1').value = `Stock Movement Summary: ${startDate} to ${endDate}`;
    summarySheet.getCell('A1').font = { bold: true, size: 13 };

    summarySheet.getCell('A3').value = 'Category';
    summarySheet.getCell('B3').value = 'Count';
    summarySheet.getCell('C3').value = 'Total Kgs';
    ['A3', 'B3', 'C3'].forEach(ref => {
        summarySheet.getCell(ref).font = headerStyle.font;
        summarySheet.getCell(ref).fill = headerStyle.fill;
    });

    const totalPurchaseKgs = purchases.reduce((s, p) => s + (Number(p.boldQty) || 0) + (Number(p.floatQty) || 0) + (Number(p.mediumQty) || 0), 0);
    const totalDispatchKgs = dispatches.reduce((s, d) => s + (Number(d.kgs) || 0), 0);
    const totalAdjKgs = adjustments.reduce((s, a) => s + (Number(a.qty || a.adjustmentKgs) || 0), 0);

    summarySheet.getCell('A4').value = 'Purchases';
    summarySheet.getCell('B4').value = purchases.length;
    summarySheet.getCell('C4').value = totalPurchaseKgs;
    summarySheet.getCell('C4').numFmt = '#,##0.00';

    summarySheet.getCell('A5').value = 'Dispatches';
    summarySheet.getCell('B5').value = dispatches.length;
    summarySheet.getCell('C5').value = totalDispatchKgs;
    summarySheet.getCell('C5').numFmt = '#,##0.00';

    summarySheet.getCell('A6').value = 'Adjustments';
    summarySheet.getCell('B6').value = adjustments.length;
    summarySheet.getCell('C6').value = totalAdjKgs;
    summarySheet.getCell('C6').numFmt = '#,##0.00';

    summarySheet.getColumn('A').width = 20;
    summarySheet.getColumn('B').width = 12;
    summarySheet.getColumn('C').width = 18;

    return workbook.xlsx.writeBuffer();
}

module.exports = { generate };
