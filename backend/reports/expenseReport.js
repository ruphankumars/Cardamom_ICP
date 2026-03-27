/**
 * Expense Report Generator
 *
 * Generates daily expense breakdown (PDF) or monthly expense summary (Excel).
 * Categories: worker_wages, stitching, loading, transport, fuel, maintenance, misc.
 *
 * Data sources: expenses collection, expense_items collection
 */

const PDFDocument = require('pdfkit');
const ExcelJS = require('exceljs');
const { getDb } = require('../firebaseClient');
const { COMPANY, formatINR, formatCurrency, drawCompanyHeader, pdfToBuffer, formatDate } = require('./pdfHelpers');

const CATEGORIES = ['worker_wages', 'stitching', 'loading', 'transport', 'fuel', 'maintenance', 'misc'];

function categoryLabel(cat) {
    const labels = {
        worker_wages: 'Worker Wages',
        stitching: 'Stitching',
        loading: 'Loading',
        transport: 'Transport',
        fuel: 'Fuel',
        maintenance: 'Maintenance',
        misc: 'Miscellaneous'
    };
    return labels[cat] || cat;
}

/**
 * Fetch expense sheet for a date
 */
async function fetchDailyExpense(date) {
    const db = getDb();
    const expSnap = await db.collection('expenses').where('date', '==', date).limit(1).get();
    if (expSnap.empty) return null;

    const sheet = expSnap.docs[0].data();
    const itemSnap = await db.collection('expense_items').where('sheetId', '==', sheet.id).get();
    sheet.items = itemSnap.docs.map(doc => doc.data());
    return sheet;
}

/**
 * Fetch all expense sheets for a month
 */
async function fetchMonthlyExpenses(month) {
    const db = getDb();
    const expSnap = await db.collection('expenses').get();
    const sheets = [];

    for (const doc of expSnap.docs) {
        const d = doc.data();
        if (d.date && d.date.startsWith(month)) {
            const itemSnap = await db.collection('expense_items').where('sheetId', '==', d.id).get();
            d.items = itemSnap.docs.map(idoc => idoc.data());
            sheets.push(d);
        }
    }

    sheets.sort((a, b) => (a.date || '').localeCompare(b.date || ''));
    return sheets;
}

/**
 * Generate daily expense PDF
 */
async function generateDailyPdf(date) {
    const sheet = await fetchDailyExpense(date);

    const doc = new PDFDocument({ size: 'A4', margin: 50 });
    drawCompanyHeader(doc, 'DAILY EXPENSE REPORT');

    doc.fontSize(10).font('Helvetica')
        .text(`Date: ${formatDate(date)}`, { align: 'center' });
    doc.moveDown(0.5);

    if (!sheet || !sheet.items || sheet.items.length === 0) {
        doc.fontSize(10).fillColor('#999999')
            .text('No expenses recorded for this date.', { align: 'center' });
        return pdfToBuffer(doc);
    }

    // Group items by category
    const byCategory = {};
    (sheet.items || []).forEach(item => {
        const cat = item.category || 'misc';
        if (!byCategory[cat]) byCategory[cat] = [];
        byCategory[cat].push(item);
    });

    // Grand total header
    doc.fontSize(11).font('Helvetica-Bold')
        .text(`Grand Total: ${formatCurrency(sheet.grandTotal || 0)}`, { align: 'center' });
    doc.moveDown(0.5);
    doc.moveTo(50, doc.y).lineTo(545, doc.y).stroke('#CCCCCC');
    doc.moveDown(0.5);

    // Category breakdown
    CATEGORIES.forEach(cat => {
        const items = byCategory[cat];
        if (!items || items.length === 0) return;

        const catTotal = items.reduce((sum, item) => sum + (parseFloat(item.amount) || 0), 0);

        if (doc.y + 80 > doc.page.height - 60) doc.addPage();

        // Category header
        doc.fontSize(10).font('Helvetica-Bold').fillColor('#2E7D32')
            .text(`${categoryLabel(cat)} - ${formatCurrency(catTotal)}`, 50);
        doc.fillColor('#000000');
        doc.moveDown(0.2);

        // Items
        const headers = ['Description', 'Sub-Category', 'Qty', 'Amount'];
        const colWidths = [160, 100, 50, 80];
        const startX = 70;
        const tableWidth = colWidths.reduce((a, b) => a + b, 0);

        let y = doc.y;
        doc.rect(startX, y, tableWidth, 14).fill('#E8F5E9');
        doc.fontSize(7).font('Helvetica-Bold').fillColor('#2E7D32');
        let x = startX;
        headers.forEach((h, i) => {
            doc.text(h, x + 2, y + 3, { width: colWidths[i] - 4, height: 14 });
            x += colWidths[i];
        });
        y += 14;
        doc.fillColor('#000000').font('Helvetica');

        items.forEach((item, ri) => {
            if (y + 14 > doc.page.height - 60) { doc.addPage(); y = 50; }
            if (ri % 2 === 0) { doc.rect(startX, y, tableWidth, 14).fill('#FAFAFA'); doc.fillColor('#000000'); }

            doc.fontSize(7);
            x = startX;
            [
                item.description || item.note || '-',
                item.subCategory || '-',
                item.quantity ? String(item.quantity) : '-',
                formatINR(parseFloat(item.amount) || 0)
            ].forEach((val, i) => {
                doc.text(val, x + 2, y + 3, { width: colWidths[i] - 4, height: 14, ellipsis: true });
                x += colWidths[i];
            });
            y += 14;
        });

        doc.y = y + 8;
    });

    // Summary box
    doc.moveDown(0.5);
    doc.moveTo(50, doc.y).lineTo(545, doc.y).stroke('#CCCCCC');
    doc.moveDown(0.3);
    doc.fontSize(9).font('Helvetica');
    doc.text(`Worker Wages: ${formatCurrency(sheet.workerWages || 0)}`, 50);
    doc.text(`Variable Expenses: ${formatCurrency(sheet.totalVariable || 0)}`, 50);
    doc.text(`Miscellaneous: ${formatCurrency(sheet.totalMisc || 0)}`, 50);
    doc.fontSize(10).font('Helvetica-Bold');
    doc.text(`Grand Total: ${formatCurrency(sheet.grandTotal || 0)}`, 50);
    doc.text(`Status: ${(sheet.status || 'draft').toUpperCase()}`, 50);

    // Footer
    const pageCount = doc.bufferedPageRange().count;
    for (let i = 0; i < pageCount; i++) {
        doc.switchToPage(i);
        const bottom = doc.page.height - 25;
        doc.fontSize(7).font('Helvetica').fillColor('#999999');
        doc.text(
            `Daily Expense Report - ${formatDate(date)} | ${COMPANY.name} | Page ${i + 1} of ${pageCount}`,
            50, bottom, { align: 'center', width: 495 }
        );
    }

    return pdfToBuffer(doc);
}

/**
 * Generate monthly expense Excel
 */
async function generateMonthlyExcel(month) {
    const sheets = await fetchMonthlyExpenses(month);

    const workbook = new ExcelJS.Workbook();
    workbook.creator = COMPANY.name;
    workbook.created = new Date();

    const headerStyle = {
        font: { bold: true, color: { argb: 'FFFFFFFF' } },
        fill: { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF2E7D32' } }
    };

    // Daily totals sheet
    const dailySheet = workbook.addWorksheet('Daily Totals');
    dailySheet.mergeCells('A1:I1');
    dailySheet.getCell('A1').value = `${COMPANY.name} - Monthly Expense Report: ${month}`;
    dailySheet.getCell('A1').font = { bold: true, size: 13 };

    const dailyHeaders = ['Date', ...CATEGORIES.map(categoryLabel), 'Grand Total', 'Status'];
    dailyHeaders.forEach((h, i) => {
        const cell = dailySheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    const categoryTotals = {};
    CATEGORIES.forEach(c => { categoryTotals[c] = 0; });
    let monthGrandTotal = 0;

    sheets.forEach((sheet, si) => {
        const row = si + 4;
        dailySheet.getCell(row, 1).value = sheet.date || '';

        // Calculate per-category totals for this day
        const dayCatTotals = {};
        CATEGORIES.forEach(c => { dayCatTotals[c] = 0; });

        (sheet.items || []).forEach(item => {
            const cat = item.category || 'misc';
            const amt = parseFloat(item.amount) || 0;
            if (dayCatTotals[cat] !== undefined) dayCatTotals[cat] += amt;
        });

        CATEGORIES.forEach((cat, ci) => {
            dailySheet.getCell(row, ci + 2).value = dayCatTotals[cat];
            dailySheet.getCell(row, ci + 2).numFmt = '#,##0.00';
            categoryTotals[cat] += dayCatTotals[cat];
        });

        const gt = sheet.grandTotal || 0;
        monthGrandTotal += gt;
        dailySheet.getCell(row, CATEGORIES.length + 2).value = gt;
        dailySheet.getCell(row, CATEGORIES.length + 2).numFmt = '#,##0.00';
        dailySheet.getCell(row, CATEGORIES.length + 3).value = sheet.status || 'draft';
    });

    // Totals row
    const totalRow = sheets.length + 4;
    dailySheet.getCell(totalRow, 1).value = 'TOTAL';
    dailySheet.getCell(totalRow, 1).font = { bold: true };
    CATEGORIES.forEach((cat, ci) => {
        dailySheet.getCell(totalRow, ci + 2).value = categoryTotals[cat];
        dailySheet.getCell(totalRow, ci + 2).numFmt = '#,##0.00';
        dailySheet.getCell(totalRow, ci + 2).font = { bold: true };
    });
    dailySheet.getCell(totalRow, CATEGORIES.length + 2).value = monthGrandTotal;
    dailySheet.getCell(totalRow, CATEGORIES.length + 2).numFmt = '#,##0.00';
    dailySheet.getCell(totalRow, CATEGORIES.length + 2).font = { bold: true };

    // Column widths
    dailySheet.getColumn(1).width = 14;
    CATEGORIES.forEach((_, i) => { dailySheet.getColumn(i + 2).width = 16; });
    dailySheet.getColumn(CATEGORIES.length + 2).width = 16;
    dailySheet.getColumn(CATEGORIES.length + 3).width = 12;

    // Category summary sheet
    const summarySheet = workbook.addWorksheet('Category Summary');
    summarySheet.mergeCells('A1:C1');
    summarySheet.getCell('A1').value = `Category Summary - ${month}`;
    summarySheet.getCell('A1').font = { bold: true, size: 13 };

    ['Category', 'Total Amount', '% of Total'].forEach((h, i) => {
        const cell = summarySheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    CATEGORIES.forEach((cat, i) => {
        const row = i + 4;
        summarySheet.getCell(row, 1).value = categoryLabel(cat);
        summarySheet.getCell(row, 2).value = categoryTotals[cat];
        summarySheet.getCell(row, 2).numFmt = '#,##0.00';
        summarySheet.getCell(row, 3).value = monthGrandTotal > 0 ? (categoryTotals[cat] / monthGrandTotal) : 0;
        summarySheet.getCell(row, 3).numFmt = '0.0%';
    });

    const catTotalRow = CATEGORIES.length + 4;
    summarySheet.getCell(catTotalRow, 1).value = 'TOTAL';
    summarySheet.getCell(catTotalRow, 1).font = { bold: true };
    summarySheet.getCell(catTotalRow, 2).value = monthGrandTotal;
    summarySheet.getCell(catTotalRow, 2).numFmt = '#,##0.00';
    summarySheet.getCell(catTotalRow, 2).font = { bold: true };
    summarySheet.getCell(catTotalRow, 3).value = 1;
    summarySheet.getCell(catTotalRow, 3).numFmt = '0.0%';

    summarySheet.getColumn(1).width = 20;
    summarySheet.getColumn(2).width = 18;
    summarySheet.getColumn(3).width = 14;

    return workbook.xlsx.writeBuffer();
}

/**
 * Generate expense report
 */
async function generate(params) {
    const { type = 'daily', date, month, format } = params;

    if (type === 'daily') {
        if (!date) throw new Error('Date is required for daily expense report');
        return generateDailyPdf(date);
    }

    if (type === 'monthly') {
        if (!month) throw new Error('Month is required for monthly expense report (format: YYYY-MM)');
        return generateMonthlyExcel(month);
    }

    throw new Error('Type must be "daily" or "monthly"');
}

module.exports = { generate };
