const SHEET_EPOCH_MS = Date.UTC(1899, 11, 30); // Google Sheets / Excel epoch
const DAY_MS = 24 * 60 * 60 * 1000;

function toDate(value) {
    if (value instanceof Date && !isNaN(value)) {
        return new Date(value.getTime());
    }

    // Handle numeric values (Google Sheets serial dates)
    if (typeof value === 'number' && !Number.isNaN(value)) {
        // Serial dates are typically large numbers (e.g., 45850 for Dec 7, 2025)
        // Small numbers are likely not serial dates
        if (value > 1000 && value < 1000000) {
            return new Date(SHEET_EPOCH_MS + value * DAY_MS);
        }
    }

    if (typeof value === 'string') {
        const trimmed = value.trim();
        if (!trimmed) return null;

        // Check if it looks like a serial date number as string (large number)
        const numValue = parseFloat(trimmed);
        if (!Number.isNaN(numValue) && numValue > 1000 && numValue < 1000000 && !trimmed.includes('/') && !trimmed.includes('-')) {
            // It's a serial date number as string
            return new Date(SHEET_EPOCH_MS + numValue * DAY_MS);
        }

        // CRITICAL FIX: Only use ISO parsing for ISO format (yyyy-mm-dd), NOT for slash dates
        // JavaScript Date("07/02/26") interprets as mm/dd/yy, but we need dd/mm/yy
        if (!trimmed.includes('/')) {
            // Try ISO or locale parse (only for dash-separated dates)
            const isoCandidate = new Date(trimmed);
            if (!isNaN(isoCandidate.getTime())) {
                // Check if it's a reasonable date (not epoch or far future)
                const year = isoCandidate.getFullYear();
                if (year >= 1900 && year <= 2100) {
                    return isoCandidate;
                }
            }
        }

        // Try parsing as dd/mm/yy or mm/dd/yy format
        const parts = trimmed.split(/[\/\-]/);
        if (parts.length === 3) {
            let day;
            let month;
            let year;

            if (parts[0].length === 4) {
                // yyyy/mm/dd
                [year, month, day] = parts;
            } else {
                // Assume dd/mm/yy format
                [day, month, year] = parts;
            }

            const dd = parseInt(day, 10);
            const mm = parseInt(month, 10);
            let yy = year;
            if (yy.length > 2) yy = yy.slice(-2);
            const fullYear = 2000 + parseInt(yy, 10);

            if (!Number.isNaN(dd) && !Number.isNaN(mm) && !Number.isNaN(fullYear)) {
                return new Date(fullYear, mm - 1, dd);
            }
        }
    }
    return null;
}

function formatSheetDate(date = new Date()) {
    const d = toDate(date) || new Date();
    // Always format in IST (Asia/Kolkata) so server timezone (UTC on Render)
    // doesn't cause date mismatches with the Indian business day
    const parts = d.toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: '2-digit' });
    // en-GB gives dd/mm/yy which is exactly our sheet format
    return parts;
}

function normalizeSheetDate(value) {
    const d = toDate(value);
    if (!d) return '';
    return formatSheetDate(d);
}

function parseSheetDate(value) {
    const d = toDate(value);
    if (!d) return null;
    return d;
}

module.exports = {
    formatSheetDate,
    normalizeSheetDate,
    parseSheetDate,
    toDate
};

