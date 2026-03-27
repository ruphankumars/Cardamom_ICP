/**
 * Invoice Report Generator
 *
 * Generates a GST-compliant PDF invoice for selected orders.
 * Data sources: orders, cart_orders, packed_orders collections.
 */

let _PDFDocument;
function getPDFDocument() { if (!_PDFDocument) _PDFDocument = require('pdfkit'); return _PDFDocument; }
const { getDb } = require('../firebaseClient');
const { COMPANY, formatINR, formatCurrency, drawCompanyHeader, pdfToBuffer, formatDate } = require('./pdfHelpers');

const ORDERS_COL = 'orders';
const CART_COL = 'cart_orders';
const PACKED_COL = 'packed_orders';

/**
 * Fetch orders by their IDs from all three collections
 */
async function fetchOrdersByIds(orderIds) {
    const db = getDb();
    const orders = [];

    // Search across all three collections
    for (const col of [ORDERS_COL, CART_COL, PACKED_COL]) {
        const snap = await db.collection(col).get();
        snap.docs.forEach(doc => {
            if (orderIds.includes(doc.id)) {
                orders.push({ ...doc.data(), id: doc.id, _source: col });
            }
        });
    }

    return orders;
}

/**
 * Generate an invoice PDF
 *
 * @param {Object} params
 * @param {string[]} params.orderIds - Array of order document IDs
 * @param {string} params.client - Client name for the invoice
 * @param {boolean} params.includeGst - Whether to include GST
 * @param {number} params.gstRate - GST percentage (default 5)
 * @returns {Promise<Buffer>} PDF buffer
 */
async function generate(params) {
    const { orderIds = [], client = '', includeGst = true, gstRate = 5 } = params;

    if (!orderIds.length) {
        throw new Error('At least one order ID is required');
    }

    const orders = await fetchOrdersByIds(orderIds);
    if (!orders.length) {
        throw new Error('No orders found for the given IDs');
    }

    const clientName = client || orders[0].client || 'Unknown Client';

    // Create PDF
    const doc = new (getPDFDocument())({ size: 'A4', margin: 50 });

    // Header
    drawCompanyHeader(doc, 'TAX INVOICE');

    // Invoice metadata
    const invoiceNo = `INV-${Date.now().toString(36).toUpperCase()}`;
    const invoiceDate = new Date().toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });

    doc.fontSize(9).font('Helvetica');
    doc.text(`Invoice No: ${invoiceNo}`, 50, doc.y, { continued: true });
    doc.text(`Date: ${invoiceDate}`, { align: 'right' });
    doc.moveDown(0.3);
    doc.text(`To: ${clientName}`, 50);
    doc.moveDown(0.5);

    // HSN Code notice
    doc.fontSize(7).fillColor('#666666')
        .text(`HSN Code: ${COMPANY.hsnCode} (Cardamom)`, 50);
    doc.fillColor('#000000');
    doc.moveDown(0.5);

    // Line items table
    const headers = ['#', 'Date', 'Grade', 'Bag/Box', 'Qty', 'Kgs', 'Rate', 'Amount'];
    const colWidths = [25, 65, 80, 50, 40, 55, 55, 65];

    // Draw header
    let y = doc.y;
    const startX = 50;
    const tableWidth = colWidths.reduce((a, b) => a + b, 0);

    doc.rect(startX, y, tableWidth, 18).fill('#2E7D32');
    doc.fontSize(8).font('Helvetica-Bold').fillColor('#FFFFFF');
    let x = startX;
    headers.forEach((h, i) => {
        doc.text(h, x + 2, y + 4, { width: colWidths[i] - 4, height: 18, ellipsis: true });
        x += colWidths[i];
    });
    y += 18;

    // Draw rows
    doc.font('Helvetica').fillColor('#000000');
    let subtotal = 0;

    orders.forEach((order, idx) => {
        if (y + 18 > doc.page.height - 100) {
            doc.addPage();
            y = 50;
        }

        const qty = Number(order.no) || 0;
        const kgs = Number(order.kgs) || 0;
        const price = Number(order.price) || 0;
        const amount = kgs * price;
        subtotal += amount;

        if (idx % 2 === 0) {
            doc.rect(startX, y, tableWidth, 18).fill('#F5F5F5');
            doc.fillColor('#000000');
        }

        const rowData = [
            String(idx + 1),
            formatDate(order.orderDate),
            order.grade || '',
            order.bagbox || '',
            String(qty),
            formatINR(kgs),
            formatINR(price),
            formatINR(amount)
        ];

        x = startX;
        doc.fontSize(8);
        rowData.forEach((val, i) => {
            doc.text(val, x + 2, y + 4, { width: colWidths[i] - 4, height: 18, ellipsis: true });
            x += colWidths[i];
        });
        y += 18;
    });

    // Totals section
    y += 5;
    doc.y = y;

    const rightCol = 380;
    const valCol = 470;

    doc.fontSize(9).font('Helvetica');
    doc.text('Subtotal:', rightCol, y);
    doc.text(formatCurrency(subtotal), valCol, y, { align: 'right', width: 65 });
    y += 16;

    if (includeGst) {
        const cgstRate = gstRate / 2;
        const sgstRate = gstRate / 2;
        const cgst = subtotal * (cgstRate / 100);
        const sgst = subtotal * (sgstRate / 100);
        const total = subtotal + cgst + sgst;

        doc.text(`CGST @ ${cgstRate}%:`, rightCol, y);
        doc.text(formatCurrency(cgst), valCol, y, { align: 'right', width: 65 });
        y += 14;

        doc.text(`SGST @ ${sgstRate}%:`, rightCol, y);
        doc.text(formatCurrency(sgst), valCol, y, { align: 'right', width: 65 });
        y += 18;

        doc.moveTo(rightCol, y).lineTo(545, y).stroke('#333333');
        y += 5;

        doc.fontSize(11).font('Helvetica-Bold');
        doc.text('Total:', rightCol, y);
        doc.text(formatCurrency(total), valCol, y, { align: 'right', width: 65 });
        y += 20;
    } else {
        doc.moveTo(rightCol, y).lineTo(545, y).stroke('#333333');
        y += 5;
        doc.fontSize(11).font('Helvetica-Bold');
        doc.text('Total:', rightCol, y);
        doc.text(formatCurrency(subtotal), valCol, y, { align: 'right', width: 65 });
        y += 20;
    }

    // Bank details
    y += 10;
    doc.y = y;
    doc.fontSize(8).font('Helvetica-Bold').text('Bank Details:', 50, y);
    y += 12;
    doc.font('Helvetica').fontSize(7);
    doc.text(`Bank: ${COMPANY.bankName}`, 50, y);
    doc.text(`A/C: ${COMPANY.bankAccount}`, 50, y + 10);
    doc.text(`IFSC: ${COMPANY.bankIfsc}`, 50, y + 20);

    // Terms
    y += 40;
    doc.fontSize(7).fillColor('#666666');
    doc.text(`Terms: ${COMPANY.invoiceTerms}`, 50, y);

    // Footer
    const pageCount = doc.bufferedPageRange().count;
    for (let i = 0; i < pageCount; i++) {
        doc.switchToPage(i);
        const bottom = doc.page.height - 25;
        doc.fontSize(7).font('Helvetica').fillColor('#999999');
        doc.text(
            `${COMPANY.name} | GSTIN: ${COMPANY.gstin} | Page ${i + 1} of ${pageCount}`,
            50, bottom, { align: 'center', width: 495 }
        );
    }

    return pdfToBuffer(doc);
}

module.exports = { generate };
