/**
 * Stock Position Report Generator
 *
 * Generates a current stock snapshot showing net stock by type and grade.
 * Supports PDF and Excel formats.
 *
 * Data source: net_stock_cache collection (3 docs: Colour Bold, Fruit Bold, Rejection)
 */

let _PDFDocument;
function getPDFDocument() { if (!_PDFDocument) _PDFDocument = require('pdfkit'); return _PDFDocument; }
const ExcelJS = require('exceljs');
const { getDb } = require('../firebaseClient');
const CFG = require('../config');
const { COMPANY, formatINR, drawCompanyHeader, pdfToBuffer, formatDate } = require('./pdfHelpers');

/**
 * Fetch current stock data from net_stock_cache
 */
async function fetchStockData() {
    const db = getDb();
    const snap = await db.collection('net_stock_cache').get();
    const stockByType = {};

    snap.docs.forEach(doc => {
        const typeName = doc.id; // 'Colour Bold', 'Fruit Bold', 'Rejection'
        const data = doc.data();
        stockByType[typeName] = {
            netAbsolute: data.netAbsolute || {},
            netVirtual: data.netVirtual || {},
            lastUpdated: data.lastUpdated || data.updatedAt || ''
        };
    });

    return stockByType;
}

/**
 * Generate stock position PDF
 */
async function generatePdf(stockByType) {
    const doc = new (getPDFDocument())({ size: 'A4', margin: 50 });

    drawCompanyHeader(doc, 'STOCK POSITION REPORT');

    doc.fontSize(9).font('Helvetica')
        .text(`Generated: ${new Date().toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`, { align: 'center' });
    doc.moveDown(0.5);

    // For each stock type
    for (const type of CFG.types) {
        const data = stockByType[type] || { netAbsolute: {}, netVirtual: {} };

        if (doc.y + 200 > doc.page.height - 60) doc.addPage();

        // Type header
        doc.fontSize(11).font('Helvetica-Bold').fillColor('#2E7D32')
            .text(type, 50);
        doc.fillColor('#000000');
        doc.moveDown(0.3);

        // Absolute grades table
        doc.fontSize(9).font('Helvetica-Bold').text('Absolute Grades (kg)', 60);
        doc.moveDown(0.2);

        const absHeaders = ['Grade', 'Net Stock (kg)'];
        const absColWidths = [200, 150];
        const startX = 70;

        let y = doc.y;
        const tableWidth = absColWidths.reduce((a, b) => a + b, 0);
        doc.rect(startX, y, tableWidth, 16).fill('#E8F5E9');
        doc.fontSize(7).font('Helvetica-Bold').fillColor('#2E7D32');
        let x = startX;
        absHeaders.forEach((h, i) => {
            doc.text(h, x + 3, y + 4, { width: absColWidths[i] - 6, height: 16 });
            x += absColWidths[i];
        });
        y += 16;
        doc.fillColor('#000000').font('Helvetica');

        let totalAbs = 0;
        CFG.absGrades.forEach((grade, ri) => {
            const val = Number(data.netAbsolute[grade]) || 0;
            totalAbs += val;

            if (ri % 2 === 0) {
                doc.rect(startX, y, tableWidth, 16).fill('#FAFAFA');
                doc.fillColor('#000000');
            }

            doc.fontSize(7);
            doc.text(grade, startX + 3, y + 4, { width: absColWidths[0] - 6, height: 16 });
            doc.text(formatINR(val), startX + absColWidths[0] + 3, y + 4, { width: absColWidths[1] - 6, height: 16 });
            y += 16;
        });

        // Total row
        doc.rect(startX, y, tableWidth, 16).fill('#E8F5E9');
        doc.fontSize(7).font('Helvetica-Bold').fillColor('#2E7D32');
        doc.text('Total', startX + 3, y + 4, { width: absColWidths[0] - 6, height: 16 });
        doc.text(formatINR(totalAbs), startX + absColWidths[0] + 3, y + 4, { width: absColWidths[1] - 6, height: 16 });
        y += 20;
        doc.fillColor('#000000');
        doc.y = y;

        // Virtual grades table
        doc.fontSize(9).font('Helvetica-Bold').text('Virtual Grades (kg)', 60);
        doc.moveDown(0.2);

        y = doc.y;
        doc.rect(startX, y, tableWidth, 16).fill('#E8F5E9');
        doc.fontSize(7).font('Helvetica-Bold').fillColor('#2E7D32');
        x = startX;
        absHeaders.forEach((h, i) => {
            doc.text(h, x + 3, y + 4, { width: absColWidths[i] - 6, height: 16 });
            x += absColWidths[i];
        });
        y += 16;
        doc.fillColor('#000000').font('Helvetica');

        let totalVirt = 0;
        CFG.virtualGrades.forEach((grade, ri) => {
            const val = Number(data.netVirtual[grade]) || 0;
            totalVirt += val;

            if (ri % 2 === 0) {
                doc.rect(startX, y, tableWidth, 16).fill('#FAFAFA');
                doc.fillColor('#000000');
            }

            doc.fontSize(7);
            doc.text(grade, startX + 3, y + 4, { width: absColWidths[0] - 6, height: 16 });
            doc.text(formatINR(val), startX + absColWidths[0] + 3, y + 4, { width: absColWidths[1] - 6, height: 16 });
            y += 16;
        });

        // Total row
        doc.rect(startX, y, tableWidth, 16).fill('#E8F5E9');
        doc.fontSize(7).font('Helvetica-Bold').fillColor('#2E7D32');
        doc.text('Total', startX + 3, y + 4, { width: absColWidths[0] - 6, height: 16 });
        doc.text(formatINR(totalVirt), startX + absColWidths[0] + 3, y + 4, { width: absColWidths[1] - 6, height: 16 });
        y += 20;
        doc.fillColor('#000000');
        doc.y = y;
        doc.moveDown(0.5);
    }

    // Footer
    const pageCount = doc.bufferedPageRange().count;
    for (let i = 0; i < pageCount; i++) {
        doc.switchToPage(i);
        const bottom = doc.page.height - 25;
        doc.fontSize(7).font('Helvetica').fillColor('#999999');
        doc.text(
            `Stock Position Report | ${COMPANY.name} | Page ${i + 1} of ${pageCount}`,
            50, bottom, { align: 'center', width: 495 }
        );
    }

    return pdfToBuffer(doc);
}

/**
 * Generate stock position Excel
 */
async function generateExcel(stockByType) {
    const workbook = new ExcelJS.Workbook();
    workbook.creator = COMPANY.name;
    workbook.created = new Date();

    for (const type of CFG.types) {
        const data = stockByType[type] || { netAbsolute: {}, netVirtual: {} };
        const sheet = workbook.addWorksheet(type);

        // Title
        sheet.mergeCells('A1:C1');
        const titleCell = sheet.getCell('A1');
        titleCell.value = `${COMPANY.name} - Stock Position: ${type}`;
        titleCell.font = { bold: true, size: 14 };

        sheet.mergeCells('A2:C2');
        sheet.getCell('A2').value = `Generated: ${new Date().toLocaleDateString('en-IN')}`;

        // Absolute grades
        const absStartRow = 4;
        sheet.getCell(`A${absStartRow}`).value = 'Absolute Grades';
        sheet.getCell(`A${absStartRow}`).font = { bold: true, size: 11 };

        sheet.getCell(`A${absStartRow + 1}`).value = 'Grade';
        sheet.getCell(`B${absStartRow + 1}`).value = 'Net Stock (kg)';
        [sheet.getCell(`A${absStartRow + 1}`), sheet.getCell(`B${absStartRow + 1}`)].forEach(c => {
            c.font = { bold: true, color: { argb: 'FFFFFFFF' } };
            c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF2E7D32' } };
        });

        let row = absStartRow + 2;
        let totalAbs = 0;
        CFG.absGrades.forEach(grade => {
            const val = Number(data.netAbsolute[grade]) || 0;
            totalAbs += val;
            sheet.getCell(`A${row}`).value = grade;
            sheet.getCell(`B${row}`).value = val;
            sheet.getCell(`B${row}`).numFmt = '#,##0.00';
            row++;
        });
        sheet.getCell(`A${row}`).value = 'Total';
        sheet.getCell(`A${row}`).font = { bold: true };
        sheet.getCell(`B${row}`).value = totalAbs;
        sheet.getCell(`B${row}`).numFmt = '#,##0.00';
        sheet.getCell(`B${row}`).font = { bold: true };
        row += 2;

        // Virtual grades
        sheet.getCell(`A${row}`).value = 'Virtual Grades';
        sheet.getCell(`A${row}`).font = { bold: true, size: 11 };
        row++;

        sheet.getCell(`A${row}`).value = 'Grade';
        sheet.getCell(`B${row}`).value = 'Net Stock (kg)';
        [sheet.getCell(`A${row}`), sheet.getCell(`B${row}`)].forEach(c => {
            c.font = { bold: true, color: { argb: 'FFFFFFFF' } };
            c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF2E7D32' } };
        });
        row++;

        let totalVirt = 0;
        CFG.virtualGrades.forEach(grade => {
            const val = Number(data.netVirtual[grade]) || 0;
            totalVirt += val;
            sheet.getCell(`A${row}`).value = grade;
            sheet.getCell(`B${row}`).value = val;
            sheet.getCell(`B${row}`).numFmt = '#,##0.00';
            row++;
        });
        sheet.getCell(`A${row}`).value = 'Total';
        sheet.getCell(`A${row}`).font = { bold: true };
        sheet.getCell(`B${row}`).value = totalVirt;
        sheet.getCell(`B${row}`).numFmt = '#,##0.00';
        sheet.getCell(`B${row}`).font = { bold: true };

        // Column widths
        sheet.getColumn('A').width = 25;
        sheet.getColumn('B').width = 20;
    }

    return workbook.xlsx.writeBuffer();
}

/**
 * Generate stock position report
 */
async function generate(params) {
    const { format = 'pdf' } = params;
    const stockByType = await fetchStockData();

    if (format === 'excel') {
        return generateExcel(stockByType);
    }
    return generatePdf(stockByType);
}

module.exports = { generate };
