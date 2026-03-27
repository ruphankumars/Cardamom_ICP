/**
 * Client Statement Report Generator
 *
 * Generates a PDF statement showing order history and running balance
 * for a specific client and period. Also supports bulk export (ZIP of PDFs).
 *
 * Data sources: orders, cart_orders, packed_orders (filtered by client + date range)
 */

let _PDFDocument;
function getPDFDocument() { if (!_PDFDocument) _PDFDocument = require('pdfkit'); return _PDFDocument; }
const archiver = require('archiver');
const { getDb } = require('../firebaseClient');
const { COMPANY, formatINR, formatCurrency, drawCompanyHeader, pdfToBuffer, formatDate } = require('./pdfHelpers');

/**
 * Fetch all orders for a client within a date range
 */
async function fetchClientOrders(client, startDate, endDate) {
    const db = getDb();
    const orders = [];

    for (const col of ['orders', 'cart_orders', 'packed_orders']) {
        const snap = await db.collection(col).get();
        snap.docs.forEach(doc => {
            const d = doc.data();
            if (!d.client || d.client.toLowerCase() !== client.toLowerCase()) return;

            const orderDate = (d.orderDate || '').split('T')[0];
            if (orderDate >= startDate && orderDate <= endDate) {
                orders.push({ ...d, id: doc.id, _source: col });
            }
        });
    }

    // Sort by date
    orders.sort((a, b) => (a.orderDate || '').localeCompare(b.orderDate || ''));
    return orders;
}

/**
 * Get list of all unique active clients
 */
async function getAllClients() {
    const db = getDb();
    const clientSet = new Set();

    for (const col of ['orders', 'cart_orders', 'packed_orders']) {
        const snap = await db.collection(col).get();
        snap.docs.forEach(doc => {
            const client = doc.data().client;
            if (client) clientSet.add(client);
        });
    }

    return Array.from(clientSet).sort();
}

/**
 * Generate a client statement PDF
 */
async function generateSingleStatement(client, startDate, endDate) {
    const orders = await fetchClientOrders(client, startDate, endDate);

    const doc = new (getPDFDocument())({ size: 'A4', margin: 50 });

    drawCompanyHeader(doc, 'CLIENT STATEMENT');

    // Client and period info
    doc.fontSize(10).font('Helvetica-Bold')
        .text(`Client: ${client}`, 50);
    doc.fontSize(9).font('Helvetica')
        .text(`Period: ${formatDate(startDate)} to ${formatDate(endDate)}`, 50);
    doc.moveDown(0.5);

    if (orders.length === 0) {
        doc.fontSize(10).fillColor('#999999')
            .text('No orders found for this client in the selected period.', { align: 'center' });
        return pdfToBuffer(doc);
    }

    // Orders table
    const headers = ['#', 'Date', 'Grade', 'Bag/Box', 'Qty', 'Kgs', 'Rate', 'Amount', 'Balance'];
    const colWidths = [22, 58, 70, 45, 35, 50, 50, 55, 60];
    const startX = 50;
    const tableWidth = colWidths.reduce((a, b) => a + b, 0);

    let y = doc.y;

    // Header row
    doc.rect(startX, y, tableWidth, 16).fill('#2E7D32');
    doc.fontSize(7).font('Helvetica-Bold').fillColor('#FFFFFF');
    let x = startX;
    headers.forEach((h, i) => {
        doc.text(h, x + 2, y + 3, { width: colWidths[i] - 4, height: 16, ellipsis: true });
        x += colWidths[i];
    });
    y += 16;

    // Data rows
    doc.font('Helvetica').fillColor('#000000');
    let runningBalance = 0;
    let totalKgs = 0;
    let totalAmount = 0;

    orders.forEach((order, idx) => {
        if (y + 16 > doc.page.height - 80) {
            doc.addPage();
            y = 50;
            // Redraw header
            doc.rect(startX, y, tableWidth, 16).fill('#2E7D32');
            doc.fontSize(7).font('Helvetica-Bold').fillColor('#FFFFFF');
            x = startX;
            headers.forEach((h, i) => {
                doc.text(h, x + 2, y + 3, { width: colWidths[i] - 4, height: 16, ellipsis: true });
                x += colWidths[i];
            });
            y += 16;
            doc.font('Helvetica').fillColor('#000000');
        }

        const kgs = Number(order.kgs) || 0;
        const price = Number(order.price) || 0;
        const amount = kgs * price;
        runningBalance += amount;
        totalKgs += kgs;
        totalAmount += amount;

        if (idx % 2 === 0) {
            doc.rect(startX, y, tableWidth, 16).fill('#F5F5F5');
            doc.fillColor('#000000');
        }

        const rowData = [
            String(idx + 1),
            formatDate(order.orderDate),
            order.grade || '',
            order.bagbox || '',
            String(Number(order.no) || 0),
            formatINR(kgs),
            formatINR(price),
            formatINR(amount),
            formatINR(runningBalance)
        ];

        x = startX;
        doc.fontSize(7);
        rowData.forEach((val, i) => {
            doc.text(val, x + 2, y + 3, { width: colWidths[i] - 4, height: 16, ellipsis: true });
            x += colWidths[i];
        });
        y += 16;
    });

    // Summary
    y += 10;
    doc.y = y;
    doc.moveTo(50, y).lineTo(545, y).stroke('#CCCCCC');
    y += 8;

    doc.fontSize(9).font('Helvetica-Bold');
    doc.text(`Total Orders: ${orders.length}`, 50, y);
    doc.text(`Total Kgs: ${formatINR(totalKgs)}`, 200, y);
    doc.text(`Outstanding Balance: ${formatCurrency(totalAmount)}`, 350, y);

    // Footer
    const pageCount = doc.bufferedPageRange().count;
    for (let i = 0; i < pageCount; i++) {
        doc.switchToPage(i);
        const bottom = doc.page.height - 25;
        doc.fontSize(7).font('Helvetica').fillColor('#999999');
        doc.text(
            `Client Statement - ${client} | ${COMPANY.name} | Page ${i + 1} of ${pageCount}`,
            50, bottom, { align: 'center', width: 495 }
        );
    }

    return pdfToBuffer(doc);
}

/**
 * Generate a single client statement or bulk ZIP
 */
async function generate(params) {
    const { client, startDate, endDate } = params;

    if (!startDate || !endDate) {
        throw new Error('startDate and endDate are required');
    }

    if (!client) {
        throw new Error('Client name is required for single statement');
    }

    return generateSingleStatement(client, startDate, endDate);
}

/**
 * Generate bulk client statements as a ZIP archive
 */
async function generateBulk(params) {
    const { startDate, endDate } = params;

    if (!startDate || !endDate) {
        throw new Error('startDate and endDate are required');
    }

    const clients = await getAllClients();
    if (clients.length === 0) {
        throw new Error('No clients found with orders');
    }

    return new Promise((resolve, reject) => {
        const archive = archiver('zip', { zlib: { level: 6 } });
        const chunks = [];

        archive.on('data', chunk => chunks.push(chunk));
        archive.on('end', () => resolve(Buffer.concat(chunks)));
        archive.on('error', reject);

        // Generate each client statement and add to ZIP
        const genAll = async () => {
            for (const client of clients) {
                try {
                    const pdfBuffer = await generateSingleStatement(client, startDate, endDate);
                    const safeName = client.replace(/[^a-zA-Z0-9 ]/g, '').replace(/\s+/g, '_');
                    archive.append(pdfBuffer, { name: `${safeName}_statement.pdf` });
                } catch (err) {
                    console.error(`[ClientStatement] Error generating for ${client}:`, err.message);
                }
            }
            archive.finalize();
        };

        genAll().catch(reject);
    });
}

module.exports = { generate, generateBulk };
