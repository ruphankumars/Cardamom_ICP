/**
 * Sales Summary Report Generator
 *
 * Generates PDF or Excel sales summary showing revenue by period, grade,
 * and client. Supports filtering by date range, billingFrom, client, and status.
 *
 * Data sources: orders, cart_orders, packed_orders
 */

let _PDFDocument;
function getPDFDocument() { if (!_PDFDocument) _PDFDocument = require('pdfkit'); return _PDFDocument; }
const ExcelJS = require('exceljs');
const { getDb } = require('../firebaseClient');
const CFG = require('../config');
const { COMPANY, formatINR, formatCurrency, drawCompanyHeader, pdfToBuffer, formatDate } = require('./pdfHelpers');

/**
 * Fetch and filter orders for sales summary
 */
async function fetchSalesData(params) {
    const { startDate, endDate, billingFrom = '', client = '', status = 'all' } = params;
    const db = getDb();
    const orders = [];

    // Map status filter to collection(s) for efficiency (matches screen logic)
    const statusMap = {
        'all': ['orders', 'cart_orders', 'packed_orders'],
        'pending': ['orders'],
        'on progress': ['cart_orders'],
        'dispatched': ['cart_orders'],
        'billed': ['packed_orders'],
    };
    const collections = statusMap[(status || 'all').toLowerCase()] || ['orders', 'cart_orders', 'packed_orders'];

    for (const col of collections) {
        const snap = await db.collection(col).get();
        snap.docs.forEach(doc => {
            const d = doc.data();
            if (d.isDeleted) return; // Skip soft-deleted

            // Normalize date: handle both dd/MM/yy and YYYY-MM-DD formats
            const raw = (d.orderDate || '');
            let isoDate = raw.split('T')[0];
            const parts = raw.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/);
            if (parts) {
                const yr = parts[3].length === 2 ? '20' + parts[3] : parts[3];
                isoDate = `${yr}-${parts[2].padStart(2, '0')}-${parts[1].padStart(2, '0')}`;
            }
            if (startDate && isoDate < startDate) return;
            if (endDate && isoDate > endDate) return;
            if (billingFrom && d.billingFrom && d.billingFrom.toLowerCase() !== billingFrom.toLowerCase()) return;
            if (client && d.client && d.client.toLowerCase() !== client.toLowerCase()) return;
            orders.push({ ...d, id: doc.id, _source: col });
        });
    }

    orders.sort((a, b) => (a.orderDate || '').localeCompare(b.orderDate || ''));
    return orders;
}

/**
 * Aggregate sales data
 */
function aggregateSales(orders) {
    const byGrade = {};
    const byClient = {};
    const byMonth = {};
    let totalKgs = 0;
    let totalRevenue = 0;

    orders.forEach(order => {
        const kgs = Number(order.kgs) || 0;
        const price = Number(order.price) || 0;
        const amount = kgs * price;
        const grade = order.grade || 'Unknown';
        const client = order.client || 'Unknown';
        const month = (order.orderDate || '').substring(0, 7); // YYYY-MM

        totalKgs += kgs;
        totalRevenue += amount;

        // By grade
        if (!byGrade[grade]) byGrade[grade] = { kgs: 0, revenue: 0, orders: 0 };
        byGrade[grade].kgs += kgs;
        byGrade[grade].revenue += amount;
        byGrade[grade].orders++;

        // By client
        if (!byClient[client]) byClient[client] = { kgs: 0, revenue: 0, orders: 0 };
        byClient[client].kgs += kgs;
        byClient[client].revenue += amount;
        byClient[client].orders++;

        // By month
        if (month) {
            if (!byMonth[month]) byMonth[month] = { kgs: 0, revenue: 0, orders: 0 };
            byMonth[month].kgs += kgs;
            byMonth[month].revenue += amount;
            byMonth[month].orders++;
        }
    });

    return { byGrade, byClient, byMonth, totalKgs, totalRevenue, totalOrders: orders.length };
}

/**
 * Generate sales summary PDF
 */
async function generatePdf(orders, params) {
    const agg = aggregateSales(orders);

    const doc = new (getPDFDocument())({ size: 'A4', margin: 50 });

    drawCompanyHeader(doc, 'SALES SUMMARY');

    // Period
    doc.fontSize(9).font('Helvetica')
        .text(`Period: ${formatDate(params.startDate)} to ${formatDate(params.endDate)}`, { align: 'center' });
    if (params.billingFrom) doc.text(`Billing From: ${params.billingFrom}`, { align: 'center' });
    if (params.client) doc.text(`Client: ${params.client}`, { align: 'center' });
    doc.moveDown(0.5);

    // Overall summary
    doc.fontSize(10).font('Helvetica-Bold')
        .text(`Total Orders: ${agg.totalOrders} | Total Kgs: ${formatINR(agg.totalKgs)} | Total Revenue: ${formatCurrency(agg.totalRevenue)}`, { align: 'center' });
    doc.moveDown(0.5);
    doc.moveTo(50, doc.y).lineTo(545, doc.y).stroke('#CCCCCC');
    doc.moveDown(0.5);

    // Sales by Grade
    doc.fontSize(11).font('Helvetica-Bold').fillColor('#2E7D32')
        .text('Sales by Grade', 50);
    doc.fillColor('#000000');
    doc.moveDown(0.3);

    const gradeHeaders = ['Grade', 'Orders', 'Kgs', 'Revenue'];
    const gradeWidths = [150, 60, 100, 120];
    const startX = 60;

    let y = doc.y;
    const tw = gradeWidths.reduce((a, b) => a + b, 0);
    doc.rect(startX, y, tw, 16).fill('#E8F5E9');
    doc.fontSize(7).font('Helvetica-Bold').fillColor('#2E7D32');
    let x = startX;
    gradeHeaders.forEach((h, i) => {
        doc.text(h, x + 3, y + 4, { width: gradeWidths[i] - 6, height: 16 });
        x += gradeWidths[i];
    });
    y += 16;
    doc.fillColor('#000000').font('Helvetica');

    const sortedGrades = Object.entries(agg.byGrade).sort((a, b) => b[1].revenue - a[1].revenue);
    sortedGrades.forEach(([grade, data], ri) => {
        if (y + 16 > doc.page.height - 100) { doc.addPage(); y = 50; }
        if (ri % 2 === 0) { doc.rect(startX, y, tw, 16).fill('#FAFAFA'); doc.fillColor('#000000'); }
        doc.fontSize(7);
        x = startX;
        [grade, String(data.orders), formatINR(data.kgs), formatCurrency(data.revenue)].forEach((val, i) => {
            doc.text(val, x + 3, y + 4, { width: gradeWidths[i] - 6, height: 16, ellipsis: true });
            x += gradeWidths[i];
        });
        y += 16;
    });
    doc.y = y + 10;

    // Sales by Client
    if (doc.y + 100 > doc.page.height - 60) doc.addPage();
    doc.fontSize(11).font('Helvetica-Bold').fillColor('#2E7D32')
        .text('Sales by Client', 50);
    doc.fillColor('#000000');
    doc.moveDown(0.3);

    y = doc.y;
    doc.rect(startX, y, tw, 16).fill('#E8F5E9');
    doc.fontSize(7).font('Helvetica-Bold').fillColor('#2E7D32');
    x = startX;
    ['Client', 'Orders', 'Kgs', 'Revenue'].forEach((h, i) => {
        doc.text(h, x + 3, y + 4, { width: gradeWidths[i] - 6, height: 16 });
        x += gradeWidths[i];
    });
    y += 16;
    doc.fillColor('#000000').font('Helvetica');

    const sortedClients = Object.entries(agg.byClient).sort((a, b) => b[1].revenue - a[1].revenue);
    sortedClients.forEach(([client, data], ri) => {
        if (y + 16 > doc.page.height - 60) { doc.addPage(); y = 50; }
        if (ri % 2 === 0) { doc.rect(startX, y, tw, 16).fill('#FAFAFA'); doc.fillColor('#000000'); }
        doc.fontSize(7);
        x = startX;
        [client, String(data.orders), formatINR(data.kgs), formatCurrency(data.revenue)].forEach((val, i) => {
            doc.text(val, x + 3, y + 4, { width: gradeWidths[i] - 6, height: 16, ellipsis: true });
            x += gradeWidths[i];
        });
        y += 16;
    });

    // Footer
    const pageCount = doc.bufferedPageRange().count;
    for (let i = 0; i < pageCount; i++) {
        doc.switchToPage(i);
        const bottom = doc.page.height - 25;
        doc.fontSize(7).font('Helvetica').fillColor('#999999');
        doc.text(
            `Sales Summary | ${COMPANY.name} | Page ${i + 1} of ${pageCount}`,
            50, bottom, { align: 'center', width: 495 }
        );
    }

    return pdfToBuffer(doc);
}

/**
 * Generate sales summary Excel
 */
async function generateExcel(orders, params) {
    const agg = aggregateSales(orders);

    const workbook = new ExcelJS.Workbook();
    workbook.creator = COMPANY.name;
    workbook.created = new Date();

    const headerStyle = {
        font: { bold: true, color: { argb: 'FFFFFFFF' } },
        fill: { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF2E7D32' } }
    };

    // Orders detail sheet
    const detailSheet = workbook.addWorksheet('Orders');
    detailSheet.mergeCells('A1:H1');
    detailSheet.getCell('A1').value = `Sales Detail: ${params.startDate} to ${params.endDate}`;
    detailSheet.getCell('A1').font = { bold: true, size: 13 };

    const detailHeaders = ['Date', 'Client', 'Grade', 'Bag/Box', 'Qty', 'Kgs', 'Rate', 'Amount'];
    detailHeaders.forEach((h, i) => {
        const cell = detailSheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    orders.forEach((order, i) => {
        const row = i + 4;
        const kgs = Number(order.kgs) || 0;
        const price = Number(order.price) || 0;
        detailSheet.getCell(row, 1).value = order.orderDate || '';
        detailSheet.getCell(row, 2).value = order.client || '';
        detailSheet.getCell(row, 3).value = order.grade || '';
        detailSheet.getCell(row, 4).value = order.bagbox || '';
        detailSheet.getCell(row, 5).value = Number(order.no) || 0;
        detailSheet.getCell(row, 6).value = kgs;
        detailSheet.getCell(row, 6).numFmt = '#,##0.00';
        detailSheet.getCell(row, 7).value = price;
        detailSheet.getCell(row, 7).numFmt = '#,##0.00';
        detailSheet.getCell(row, 8).value = kgs * price;
        detailSheet.getCell(row, 8).numFmt = '#,##0.00';
    });

    [15, 20, 18, 10, 8, 12, 12, 15].forEach((w, i) => { detailSheet.getColumn(i + 1).width = w; });

    // By Grade sheet
    const gradeSheet = workbook.addWorksheet('By Grade');
    gradeSheet.mergeCells('A1:D1');
    gradeSheet.getCell('A1').value = 'Sales by Grade';
    gradeSheet.getCell('A1').font = { bold: true, size: 13 };

    ['Grade', 'Orders', 'Kgs', 'Revenue'].forEach((h, i) => {
        const cell = gradeSheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    const sortedGrades = Object.entries(agg.byGrade).sort((a, b) => b[1].revenue - a[1].revenue);
    sortedGrades.forEach(([grade, data], i) => {
        const row = i + 4;
        gradeSheet.getCell(row, 1).value = grade;
        gradeSheet.getCell(row, 2).value = data.orders;
        gradeSheet.getCell(row, 3).value = data.kgs;
        gradeSheet.getCell(row, 3).numFmt = '#,##0.00';
        gradeSheet.getCell(row, 4).value = data.revenue;
        gradeSheet.getCell(row, 4).numFmt = '#,##0.00';
    });

    [20, 10, 15, 18].forEach((w, i) => { gradeSheet.getColumn(i + 1).width = w; });

    // By Client sheet
    const clientSheet = workbook.addWorksheet('By Client');
    clientSheet.mergeCells('A1:D1');
    clientSheet.getCell('A1').value = 'Sales by Client';
    clientSheet.getCell('A1').font = { bold: true, size: 13 };

    ['Client', 'Orders', 'Kgs', 'Revenue'].forEach((h, i) => {
        const cell = clientSheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    const sortedClients = Object.entries(agg.byClient).sort((a, b) => b[1].revenue - a[1].revenue);
    sortedClients.forEach(([client, data], i) => {
        const row = i + 4;
        clientSheet.getCell(row, 1).value = client;
        clientSheet.getCell(row, 2).value = data.orders;
        clientSheet.getCell(row, 3).value = data.kgs;
        clientSheet.getCell(row, 3).numFmt = '#,##0.00';
        clientSheet.getCell(row, 4).value = data.revenue;
        clientSheet.getCell(row, 4).numFmt = '#,##0.00';
    });

    [25, 10, 15, 18].forEach((w, i) => { clientSheet.getColumn(i + 1).width = w; });

    // By Month sheet
    const monthSheet = workbook.addWorksheet('By Month');
    monthSheet.mergeCells('A1:D1');
    monthSheet.getCell('A1').value = 'Sales by Month';
    monthSheet.getCell('A1').font = { bold: true, size: 13 };

    ['Month', 'Orders', 'Kgs', 'Revenue'].forEach((h, i) => {
        const cell = monthSheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    const sortedMonths = Object.entries(agg.byMonth).sort((a, b) => a[0].localeCompare(b[0]));
    sortedMonths.forEach(([month, data], i) => {
        const row = i + 4;
        monthSheet.getCell(row, 1).value = month;
        monthSheet.getCell(row, 2).value = data.orders;
        monthSheet.getCell(row, 3).value = data.kgs;
        monthSheet.getCell(row, 3).numFmt = '#,##0.00';
        monthSheet.getCell(row, 4).value = data.revenue;
        monthSheet.getCell(row, 4).numFmt = '#,##0.00';
    });

    [15, 10, 15, 18].forEach((w, i) => { monthSheet.getColumn(i + 1).width = w; });

    return workbook.xlsx.writeBuffer();
}

/**
 * Generate sales summary report
 */
async function generate(params) {
    const { startDate, endDate, format = 'excel' } = params;

    if (!startDate || !endDate) {
        throw new Error('startDate and endDate are required');
    }

    const orders = await fetchSalesData(params);

    if (format === 'pdf') {
        return generatePdf(orders, params);
    }
    return generateExcel(orders, params);
}

module.exports = { generate };
