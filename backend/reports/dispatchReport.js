/**
 * Dispatch Summary Report Generator
 *
 * Generates a daily dispatch summary PDF showing all items packed and dispatched,
 * grouped by client, with vehicle and driver details from gate passes.
 *
 * Data sources: cart_orders, packed_orders (by date), gate_passes (vehicle/driver)
 */

const PDFDocument = require('pdfkit');
const { getDb } = require('../firebaseClient');
const { COMPANY, formatINR, drawCompanyHeader, pdfToBuffer, formatDate } = require('./pdfHelpers');

/**
 * Fetch dispatched orders for a given date
 */
async function fetchDispatchedOrders(date) {
    const db = getDb();
    const orders = [];

    // Check cart_orders for today's dispatches
    const cartSnap = await db.collection('cart_orders').get();
    cartSnap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted === true) return;
        const orderDate = (d.orderDate || d.cartDate || '').split('T')[0];
        if (orderDate === date || (d.cartDate && d.cartDate.split('T')[0] === date)) {
            orders.push({ ...d, id: doc.id, _source: 'cart_orders' });
        }
    });

    // Also check packed_orders for the date
    const packedSnap = await db.collection('packed_orders').get();
    packedSnap.docs.forEach(doc => {
        const d = doc.data();
        if (d.isDeleted === true) return;
        const packDate = (d.packedDate || d.orderDate || '').split('T')[0];
        if (packDate === date) {
            orders.push({ ...d, id: doc.id, _source: 'packed_orders' });
        }
    });

    return orders;
}

/**
 * Fetch gate passes for a given date
 */
async function fetchGatePasses(date) {
    const db = getDb();
    const snap = await db.collection('gate_passes').get();
    const passes = [];
    snap.docs.forEach(doc => {
        const d = doc.data();
        const passDate = (d.requestedAt || '').split('T')[0];
        if (passDate === date) {
            passes.push({ ...d, id: doc.id });
        }
    });
    return passes;
}

/**
 * Generate a dispatch summary PDF
 *
 * @param {Object} params
 * @param {string} params.date - Date in YYYY-MM-DD format
 * @returns {Promise<Buffer>} PDF buffer
 */
async function generate(params) {
    const { date } = params;

    if (!date) {
        throw new Error('Date is required');
    }

    const orders = await fetchDispatchedOrders(date);
    const gatePasses = await fetchGatePasses(date);

    // Group orders by client
    const clientGroups = {};
    orders.forEach(order => {
        const client = order.client || 'Unknown';
        if (!clientGroups[client]) clientGroups[client] = [];
        clientGroups[client].push(order);
    });

    const doc = new PDFDocument({ size: 'A4', margin: 50 });

    // Header
    drawCompanyHeader(doc, 'DISPATCH SUMMARY');

    // Date
    doc.fontSize(10).font('Helvetica')
        .text(`Date: ${formatDate(date)}`, { align: 'center' });
    doc.moveDown(0.5);

    // Summary stats
    const totalBags = orders.reduce((sum, o) => sum + ((o.bagbox || '').toLowerCase().includes('bag') ? (Number(o.no) || 0) : 0), 0);
    const totalBoxes = orders.reduce((sum, o) => sum + ((o.bagbox || '').toLowerCase().includes('box') ? (Number(o.no) || 0) : 0), 0);
    const totalKgs = orders.reduce((sum, o) => sum + (Number(o.kgs) || 0), 0);
    const clientCount = Object.keys(clientGroups).length;

    doc.fontSize(9).font('Helvetica-Bold');
    doc.text(`Clients: ${clientCount} | Bags: ${totalBags} | Boxes: ${totalBoxes} | Total Weight: ${formatINR(totalKgs)} kg`, { align: 'center' });
    doc.moveDown(0.5);

    // Divider
    doc.moveTo(50, doc.y).lineTo(545, doc.y).stroke('#CCCCCC');
    doc.moveDown(0.5);

    // Client-wise dispatch details
    const clients = Object.keys(clientGroups).sort();

    clients.forEach((client, ci) => {
        const items = clientGroups[client];

        // Check page space
        if (doc.y + 100 > doc.page.height - 60) {
            doc.addPage();
        }

        // Client header
        doc.fontSize(10).font('Helvetica-Bold').fillColor('#2E7D32')
            .text(`${ci + 1}. ${client}`, 50);
        doc.fillColor('#000000');
        doc.moveDown(0.3);

        // Items table
        const headers = ['Grade', 'Bag/Box', 'Qty', 'Kgs', 'Brand', 'Status'];
        const colWidths = [100, 60, 50, 70, 80, 80];
        const startX = 70;

        // Header row
        let y = doc.y;
        const tableWidth = colWidths.reduce((a, b) => a + b, 0);
        doc.rect(startX, y, tableWidth, 16).fill('#E8F5E9');
        doc.fontSize(7).font('Helvetica-Bold').fillColor('#2E7D32');
        let x = startX;
        headers.forEach((h, i) => {
            doc.text(h, x + 2, y + 4, { width: colWidths[i] - 4, height: 16, ellipsis: true });
            x += colWidths[i];
        });
        y += 16;
        doc.fillColor('#000000').font('Helvetica');

        let clientKgs = 0;
        let clientBags = 0;
        let clientBoxes = 0;

        items.forEach((item, ri) => {
            if (y + 16 > doc.page.height - 60) {
                doc.addPage();
                y = 50;
            }

            const qty = Number(item.no) || 0;
            const kgs = Number(item.kgs) || 0;
            clientKgs += kgs;
            if ((item.bagbox || '').toLowerCase().includes('bag')) clientBags += qty;
            else clientBoxes += qty;

            if (ri % 2 === 0) {
                doc.rect(startX, y, tableWidth, 16).fill('#FAFAFA');
                doc.fillColor('#000000');
            }

            const rowData = [
                item.grade || '',
                item.bagbox || '',
                String(qty),
                formatINR(kgs),
                item.brand || '',
                item.status || ''
            ];

            x = startX;
            doc.fontSize(7);
            rowData.forEach((val, i) => {
                doc.text(val, x + 2, y + 4, { width: colWidths[i] - 4, height: 16, ellipsis: true });
                x += colWidths[i];
            });
            y += 16;
        });

        // Client subtotal
        y += 2;
        doc.fontSize(7).font('Helvetica-Bold')
            .text(`Subtotal: Bags: ${clientBags} | Boxes: ${clientBoxes} | Weight: ${formatINR(clientKgs)} kg`, startX, y);
        doc.y = y + 16;
        doc.moveDown(0.3);
    });

    // Gate pass details
    if (gatePasses.length > 0) {
        doc.moveDown(0.5);
        if (doc.y + 80 > doc.page.height - 60) doc.addPage();

        doc.moveTo(50, doc.y).lineTo(545, doc.y).stroke('#CCCCCC');
        doc.moveDown(0.3);
        doc.fontSize(11).font('Helvetica-Bold').fillColor('#2E7D32')
            .text('Vehicle & Driver Details', 50);
        doc.fillColor('#000000');
        doc.moveDown(0.3);

        gatePasses.forEach((pass, i) => {
            if (doc.y + 40 > doc.page.height - 60) doc.addPage();

            doc.fontSize(8).font('Helvetica-Bold')
                .text(`${i + 1}. ${pass.passNumber || pass.id}`, 60);
            doc.font('Helvetica').fontSize(7);
            doc.text(`Vehicle: ${pass.vehicleNumber || 'N/A'} | Driver: ${pass.driverName || 'N/A'} | Phone: ${pass.driverPhone || 'N/A'}`, 70);
            doc.text(`Bags: ${pass.bagCount || 0} | Boxes: ${pass.boxCount || 0} | Weight: ${formatINR(pass.finalWeight || pass.actualWeight || 0)} kg`, 70);
            doc.moveDown(0.3);
        });
    }

    // No dispatches message
    if (orders.length === 0) {
        doc.moveDown(2);
        doc.fontSize(12).font('Helvetica').fillColor('#999999')
            .text('No dispatches recorded for this date.', { align: 'center' });
    }

    // Footer
    const pageCount = doc.bufferedPageRange().count;
    for (let i = 0; i < pageCount; i++) {
        doc.switchToPage(i);
        const bottom = doc.page.height - 25;
        doc.fontSize(7).font('Helvetica').fillColor('#999999');
        doc.text(
            `Dispatch Summary - ${formatDate(date)} | ${COMPANY.name} | Page ${i + 1} of ${pageCount}`,
            50, bottom, { align: 'center', width: 495 }
        );
    }

    return pdfToBuffer(doc);
}

module.exports = { generate };
