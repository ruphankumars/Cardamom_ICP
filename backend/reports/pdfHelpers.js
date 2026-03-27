/**
 * PDF Helper Utilities for Report Generation
 *
 * Shared utilities for creating consistent PDF reports:
 * - Company header with logo placeholder
 * - Indian number formatting (lakhs/crores)
 * - Table drawing helpers
 * - Page footer with page numbers
 */

const COMPANY = {
    name: 'Emperor Spices Pvt Ltd',
    address: 'Kumily, Thekkady, Idukki District, Kerala 685509',
    gstin: '32AADCE1234F1Z5',
    phone: '+91 94470 00000',
    email: 'info@emperorspices.com',
    hsnCode: '09083110', // Cardamom HSN
    bankName: 'State Bank of India',
    bankAccount: '1234567890',
    bankIfsc: 'SBIN0001234',
    invoiceTerms: 'Payment due within 30 days of invoice date.'
};

/**
 * Format a number in Indian numbering system (lakhs/crores)
 * e.g., 1234567.89 -> "12,34,567.89"
 */
function formatINR(num) {
    if (num == null || isNaN(num)) return '0.00';
    const n = parseFloat(num);
    const isNeg = n < 0;
    const abs = Math.abs(n).toFixed(2);
    const parts = abs.split('.');
    let intPart = parts[0];
    const decPart = parts[1];

    // Indian grouping: last 3 digits, then groups of 2
    if (intPart.length > 3) {
        const last3 = intPart.slice(-3);
        const rest = intPart.slice(0, -3);
        const grouped = rest.replace(/\B(?=(\d{2})+(?!\d))/g, ',');
        intPart = grouped + ',' + last3;
    }
    return (isNeg ? '-' : '') + intPart + '.' + decPart;
}

/**
 * Format a number as INR currency string
 */
function formatCurrency(num) {
    return '\u20B9 ' + formatINR(num); // ₹ symbol
}

/**
 * Draw company header on a PDF page
 */
function drawCompanyHeader(doc, title) {
    const startY = doc.y;

    // Company name
    doc.fontSize(16).font('Helvetica-Bold')
        .text(COMPANY.name, { align: 'center' });

    // Address
    doc.fontSize(8).font('Helvetica')
        .text(COMPANY.address, { align: 'center' });
    doc.text(`GSTIN: ${COMPANY.gstin} | Phone: ${COMPANY.phone}`, { align: 'center' });

    doc.moveDown(0.5);

    // Divider line
    doc.moveTo(50, doc.y).lineTo(545, doc.y).stroke('#333333');
    doc.moveDown(0.3);

    // Report title
    if (title) {
        doc.fontSize(12).font('Helvetica-Bold')
            .text(title, { align: 'center' });
        doc.moveDown(0.5);
    }

    return doc.y;
}

/**
 * Draw a simple table on the PDF
 * @param {PDFDocument} doc - pdfkit document
 * @param {string[]} headers - column headers
 * @param {Array<Array>} rows - array of row arrays
 * @param {Object} options - { columnWidths, startX, fontSize, headerColor }
 */
function drawTable(doc, headers, rows, options = {}) {
    const {
        columnWidths = null,
        startX = 50,
        fontSize = 8,
        headerColor = '#2E7D32',
        headerTextColor = '#FFFFFF',
        rowHeight = 18,
        maxWidth = 495
    } = options;

    // Calculate column widths if not provided
    const colWidths = columnWidths || headers.map(() => Math.floor(maxWidth / headers.length));
    const tableWidth = colWidths.reduce((a, b) => a + b, 0);

    // Check if we need a new page
    if (doc.y + rowHeight * 2 > doc.page.height - 60) {
        doc.addPage();
    }

    let y = doc.y;

    // Draw header row
    doc.rect(startX, y, tableWidth, rowHeight).fill(headerColor);
    doc.fontSize(fontSize).font('Helvetica-Bold').fillColor(headerTextColor);
    let x = startX;
    headers.forEach((header, i) => {
        doc.text(header, x + 3, y + 4, { width: colWidths[i] - 6, height: rowHeight, ellipsis: true });
        x += colWidths[i];
    });
    y += rowHeight;

    // Draw data rows
    doc.font('Helvetica').fillColor('#000000');
    rows.forEach((row, rowIndex) => {
        // Check for page break
        if (y + rowHeight > doc.page.height - 60) {
            doc.addPage();
            y = 50;
            // Redraw header on new page
            doc.rect(startX, y, tableWidth, rowHeight).fill(headerColor);
            doc.fontSize(fontSize).font('Helvetica-Bold').fillColor(headerTextColor);
            x = startX;
            headers.forEach((header, i) => {
                doc.text(header, x + 3, y + 4, { width: colWidths[i] - 6, height: rowHeight, ellipsis: true });
                x += colWidths[i];
            });
            y += rowHeight;
            doc.font('Helvetica').fillColor('#000000');
        }

        // Alternate row background
        if (rowIndex % 2 === 0) {
            doc.rect(startX, y, tableWidth, rowHeight).fill('#F5F5F5');
            doc.fillColor('#000000');
        }

        x = startX;
        doc.fontSize(fontSize);
        (row || []).forEach((cell, i) => {
            const val = cell != null ? String(cell) : '';
            doc.text(val, x + 3, y + 4, { width: colWidths[i] - 6, height: rowHeight, ellipsis: true });
            x += colWidths[i];
        });
        y += rowHeight;
    });

    // Draw table border
    doc.rect(startX, doc.y, tableWidth, y - doc.y).stroke('#CCCCCC');
    doc.y = y + 5;
    return y;
}

/**
 * Draw page footer with page numbers
 */
function drawPageFooter(doc, pageNumber, totalPages) {
    const bottom = doc.page.height - 30;
    doc.fontSize(7).font('Helvetica').fillColor('#999999');
    doc.text(
        `Generated on ${new Date().toLocaleDateString('en-IN')} | Page ${pageNumber} of ${totalPages}`,
        50, bottom,
        { align: 'center', width: 495 }
    );
    doc.text(
        `${COMPANY.name} - Confidential`,
        50, bottom + 10,
        { align: 'center', width: 495 }
    );
}

/**
 * Finalize a PDF document and return it as a Buffer
 */
function pdfToBuffer(doc) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        doc.on('data', chunk => chunks.push(chunk));
        doc.on('end', () => resolve(Buffer.concat(chunks)));
        doc.on('error', reject);
        doc.end();
    });
}

/**
 * Format a date string for display
 */
function formatDate(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return dateStr;
    return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
}

module.exports = {
    COMPANY,
    formatINR,
    formatCurrency,
    drawCompanyHeader,
    drawTable,
    drawPageFooter,
    pdfToBuffer,
    formatDate
};
