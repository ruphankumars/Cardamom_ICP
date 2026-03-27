/**
 * Attendance Report Generator
 *
 * Generates a monthly Excel attendance report with workers as rows and
 * calendar days as columns. Includes total present days, total wages due
 * per worker, and team-level summaries.
 *
 * Data sources: workers collection, attendance collection (filtered by month)
 */

const ExcelJS = require('exceljs');
const { getDb } = require('../firebaseClient');
const { COMPANY } = require('./pdfHelpers');

/**
 * Fetch workers and attendance data for a month
 */
async function fetchAttendanceData(month, teamFilter) {
    const db = getDb();

    // Get workers
    const workersSnap = await db.collection('workers').get();
    let workers = workersSnap.docs
        .map(doc => ({ ...doc.data(), _docId: doc.id }))
        .filter(w => w.status !== 'Inactive');

    if (teamFilter) {
        workers = workers.filter(w => (w.team || '').toLowerCase() === teamFilter.toLowerCase());
    }

    workers.sort((a, b) => (a.name || '').localeCompare(b.name || ''));

    // Get attendance records for the month
    const attendanceSnap = await db.collection('attendance').get();
    const attendance = {};
    attendanceSnap.docs.forEach(doc => {
        const d = doc.data();
        if (d.date && d.date.startsWith(month)) {
            if (!attendance[d.workerId]) attendance[d.workerId] = {};
            attendance[d.workerId][d.date] = {
                status: d.status || 'absent',
                otHours: Number(d.otHours) || 0,
                wagePaid: Number(d.wagePaid) || 0
            };
        }
    });

    return { workers, attendance };
}

/**
 * Get days in a month
 */
function getDaysInMonth(month) {
    const [year, mon] = month.split('-').map(Number);
    const daysCount = new Date(year, mon, 0).getDate();
    const days = [];
    for (let d = 1; d <= daysCount; d++) {
        days.push(`${month}-${String(d).padStart(2, '0')}`);
    }
    return days;
}

/**
 * Status to display code
 */
function statusCode(status) {
    switch ((status || '').toLowerCase()) {
        case 'present': return 'P';
        case 'absent': return 'A';
        case 'half_day': return 'H';
        case 'overtime': return 'OT';
        default: return '-';
    }
}

/**
 * Calculate wage for a status
 */
function calculateWage(baseDailyWage, status, otHours = 0) {
    const base = parseFloat(baseDailyWage) || 0;
    if (status === 'absent') return 0;
    if (status === 'half_day') return Math.round(base / 2);
    const otRate = Math.round(base / 8);
    return Math.round(base + (parseFloat(otHours) || 0) * otRate);
}

/**
 * Generate attendance report Excel
 */
async function generate(params) {
    const { month, team = '' } = params;

    if (!month) {
        throw new Error('Month is required (format: YYYY-MM)');
    }

    const { workers, attendance } = await fetchAttendanceData(month, team);
    const days = getDaysInMonth(month);

    const workbook = new ExcelJS.Workbook();
    workbook.creator = COMPANY.name;
    workbook.created = new Date();

    const sheet = workbook.addWorksheet('Attendance');

    // Title
    const totalCols = 5 + days.length; // Name, Team, Base Wage, ... days ..., Present, Total Wages
    sheet.mergeCells(1, 1, 1, totalCols);
    sheet.getCell('A1').value = `${COMPANY.name} - Monthly Attendance Report`;
    sheet.getCell('A1').font = { bold: true, size: 14 };

    sheet.mergeCells(2, 1, 2, totalCols);
    sheet.getCell('A2').value = `Month: ${month}${team ? ` | Team: ${team}` : ''} | Generated: ${new Date().toLocaleDateString('en-IN')}`;
    sheet.getCell('A2').font = { size: 10 };

    // Header row
    const headerRow = 4;
    const headerStyle = {
        font: { bold: true, color: { argb: 'FFFFFFFF' }, size: 9 },
        fill: { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF2E7D32' } },
        alignment: { horizontal: 'center', vertical: 'middle' },
        border: {
            top: { style: 'thin' }, bottom: { style: 'thin' },
            left: { style: 'thin' }, right: { style: 'thin' }
        }
    };

    const headers = ['Worker Name', 'Team', 'Base Wage'];
    days.forEach(day => {
        // Just the day number
        headers.push(String(parseInt(day.split('-')[2])));
    });
    headers.push('Present Days', 'Total Wages');

    headers.forEach((h, i) => {
        const cell = sheet.getCell(headerRow, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
        cell.alignment = headerStyle.alignment;
        cell.border = headerStyle.border;
    });

    // Freeze header row and worker name column
    sheet.views = [{ state: 'frozen', xSplit: 1, ySplit: headerRow }];

    // Data rows
    let teamTotalWages = 0;
    let teamTotalPresent = 0;
    const teamSummary = {};

    workers.forEach((worker, wi) => {
        const row = headerRow + 1 + wi;
        const workerId = worker.id || worker._docId;
        const baseWage = Number(worker.baseDailyWage) || 0;
        const workerAttendance = attendance[workerId] || {};

        sheet.getCell(row, 1).value = worker.name || '';
        sheet.getCell(row, 2).value = worker.team || 'Unassigned';
        sheet.getCell(row, 3).value = baseWage;
        sheet.getCell(row, 3).numFmt = '#,##0';

        let presentDays = 0;
        let totalWages = 0;

        days.forEach((day, di) => {
            const record = workerAttendance[day];
            const cell = sheet.getCell(row, 4 + di);

            if (record) {
                cell.value = statusCode(record.status);
                const wage = record.wagePaid || calculateWage(baseWage, record.status, record.otHours);
                totalWages += wage;

                if (record.status === 'present' || record.status === 'overtime') {
                    presentDays += 1;
                } else if (record.status === 'half_day') {
                    presentDays += 0.5;
                }

                // Color coding
                switch (record.status) {
                    case 'present':
                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFC8E6C9' } };
                        break;
                    case 'absent':
                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFFFCDD2' } };
                        break;
                    case 'half_day':
                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFFFF9C4' } };
                        break;
                    case 'overtime':
                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFBBDEFB' } };
                        break;
                }
            } else {
                cell.value = '-';
                cell.font = { color: { argb: 'FFCCCCCC' } };
            }

            cell.alignment = { horizontal: 'center' };
            cell.border = { top: { style: 'thin', color: { argb: 'FFE0E0E0' } }, bottom: { style: 'thin', color: { argb: 'FFE0E0E0' } } };
        });

        // Summary columns
        const presentCell = sheet.getCell(row, 4 + days.length);
        presentCell.value = presentDays;
        presentCell.font = { bold: true };
        presentCell.alignment = { horizontal: 'center' };

        const wageCell = sheet.getCell(row, 5 + days.length);
        wageCell.value = totalWages;
        wageCell.numFmt = '#,##0';
        wageCell.font = { bold: true };

        teamTotalWages += totalWages;
        teamTotalPresent += presentDays;

        // Team summary
        const team = worker.team || 'Unassigned';
        if (!teamSummary[team]) teamSummary[team] = { workers: 0, presentDays: 0, totalWages: 0 };
        teamSummary[team].workers++;
        teamSummary[team].presentDays += presentDays;
        teamSummary[team].totalWages += totalWages;
    });

    // Grand total row
    const totalRow = headerRow + 1 + workers.length + 1;
    sheet.getCell(totalRow, 1).value = 'GRAND TOTAL';
    sheet.getCell(totalRow, 1).font = { bold: true, size: 11 };
    sheet.getCell(totalRow, 4 + days.length).value = teamTotalPresent;
    sheet.getCell(totalRow, 4 + days.length).font = { bold: true, size: 11 };
    sheet.getCell(totalRow, 5 + days.length).value = teamTotalWages;
    sheet.getCell(totalRow, 5 + days.length).numFmt = '#,##0';
    sheet.getCell(totalRow, 5 + days.length).font = { bold: true, size: 11 };

    // Team summary sheet
    const summarySheet = workbook.addWorksheet('Team Summary');
    summarySheet.mergeCells('A1:D1');
    summarySheet.getCell('A1').value = `Team Summary - ${month}`;
    summarySheet.getCell('A1').font = { bold: true, size: 13 };

    ['Team', 'Workers', 'Total Present Days', 'Total Wages'].forEach((h, i) => {
        const cell = summarySheet.getCell(3, i + 1);
        cell.value = h;
        cell.font = headerStyle.font;
        cell.fill = headerStyle.fill;
    });

    Object.entries(teamSummary).sort((a, b) => a[0].localeCompare(b[0])).forEach(([team, data], i) => {
        const row = i + 4;
        summarySheet.getCell(row, 1).value = team;
        summarySheet.getCell(row, 2).value = data.workers;
        summarySheet.getCell(row, 3).value = data.presentDays;
        summarySheet.getCell(row, 4).value = data.totalWages;
        summarySheet.getCell(row, 4).numFmt = '#,##0';
    });

    summarySheet.getColumn(1).width = 20;
    summarySheet.getColumn(2).width = 12;
    summarySheet.getColumn(3).width = 20;
    summarySheet.getColumn(4).width = 18;

    // Column widths for main sheet
    sheet.getColumn(1).width = 20;
    sheet.getColumn(2).width = 14;
    sheet.getColumn(3).width = 12;
    for (let d = 0; d < days.length; d++) {
        sheet.getColumn(4 + d).width = 4;
    }
    sheet.getColumn(4 + days.length).width = 14;
    sheet.getColumn(5 + days.length).width = 14;

    return workbook.xlsx.writeBuffer();
}

module.exports = { generate };
