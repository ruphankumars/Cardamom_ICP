/**
 * Payment table image generator using sharp + SVG.
 * Generates payment reminder images server-side so the mobile app
 * doesn't block the UI thread capturing screenshots.
 */
// sharp uses native libvips bindings — may not be available on ICP WASM
let sharp;
try { sharp = require('sharp'); } catch (e) {
    console.warn('[PaymentImageGen] sharp not available:', e.message);
    sharp = null;
}

// Indian number format: 1,23,45,678
function formatINR(num) {
    const n = Math.round(Number(num) || 0);
    const s = n.toString();
    if (s.length <= 3) return s;
    const last3 = s.slice(-3);
    const rest = s.slice(0, -3);
    const grouped = rest.replace(/\B(?=(\d{2})+(?!\d))/g, ',');
    return `${grouped},${last3}`;
}

function escapeXml(str) {
    return String(str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&apos;');
}

function daysBadgeColor(days) {
    if (days <= 20) return '#4CAF50';
    if (days <= 30) return '#F59E0B';
    return '#EF4444';
}

function daysBgColor(days) {
    if (days <= 20) return '#d0f0c0';
    if (days <= 30) return '#fff9c4';
    return '#ffcccc';
}

/**
 * Generate a payment reminder image for a single client.
 * @param {Object} client - { sheetName, company, companyFull, asOnDate, totalAmount, oldestDays, bills: [{date, ref, amount, days}], phones }
 * @returns {Promise<Buffer>} PNG image buffer
 */
async function generatePaymentImage(client) {
    const { sheetName, company, companyFull, asOnDate, totalAmount, bills = [] } = client;

    const companyTag = (company || '').toUpperCase();
    // Strip year part: "Sri Yogaganapathy Traders - (2025-26)" → "Sri Yogaganapathy Traders"
    const companyName = (companyFull || company || '')
        .replace(/\s*[-–]\s*\(.*\)\s*$/, '').trim();

    const WIDTH = 680;
    const PADDING = 24;
    const BANNER_H = 48;
    const COMPANY_SECTION_H = 50;  // company name
    const CLIENT_ROW_H = 40;      // client name + date
    const GAP = 14;
    const BILL_CARD_H = 48;
    const BILL_GAP = 8;
    const TOTAL_ROW_H = 52;
    const BOTTOM_PAD = 20;

    const billsAreaH = bills.length * BILL_CARD_H + (bills.length - 1) * BILL_GAP;
    const HEIGHT = BANNER_H + 16 + COMPANY_SECTION_H + CLIENT_ROW_H + GAP +
                   billsAreaH + 12 + TOTAL_ROW_H + BOTTOM_PAD;

    // Build bill card SVGs
    let billsSvg = '';
    let billY = BANNER_H + 16 + COMPANY_SECTION_H + CLIENT_ROW_H + GAP;

    for (const bill of bills) {
        const days = bill.days || 0;
        const amount = bill.amount || 0;
        const badgeColor = daysBadgeColor(days);
        const bgColor = daysBgColor(days);
        const cardX = PADDING;
        const cardW = WIDTH - 2 * PADDING;

        billsSvg += `
        <rect x="${cardX}" y="${billY}" width="${cardW}" height="${BILL_CARD_H}" rx="12" fill="white"/>
        <rect x="${cardX}" y="${billY}" width="4" height="${BILL_CARD_H}" rx="2" fill="${badgeColor}"/>
        <text x="${cardX + 16}" y="${billY + 30}" fill="#475569" font-size="14" font-weight="600" font-family="Arial, Helvetica, sans-serif">${escapeXml(bill.date || '')}</text>
        <text x="${cardX + 150}" y="${billY + 30}" fill="#475569" font-size="14" font-weight="600" font-family="Arial, Helvetica, sans-serif">${escapeXml(bill.ref || '')}</text>
        <text x="${cardX + 340}" y="${billY + 30}" fill="#1E293B" font-size="17" font-weight="800" font-family="Arial, Helvetica, sans-serif">&#x20B9;${formatINR(amount)}</text>
        <rect x="${cardX + cardW - 70}" y="${billY + 10}" width="55" height="${BILL_CARD_H - 20}" rx="8" fill="${badgeColor}"/>
        <text x="${cardX + cardW - 42}" y="${billY + 32}" text-anchor="middle" fill="white" font-size="13" font-weight="bold" font-family="Arial, Helvetica, sans-serif">${days}d</text>
        `;
        billY += BILL_CARD_H + BILL_GAP;
    }

    // Total row Y
    const totalY = billY + 4;

    const svg = `<svg width="${WIDTH}" height="${HEIGHT}" xmlns="http://www.w3.org/2000/svg">
    <defs>
        <linearGradient id="bgGrad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#FFF5F5"/>
            <stop offset="100%" stop-color="#FEF2F2"/>
        </linearGradient>
        <linearGradient id="bannerGrad" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stop-color="#991B1B"/>
            <stop offset="100%" stop-color="#DC2626"/>
        </linearGradient>
        <clipPath id="roundedClip">
            <rect width="${WIDTH}" height="${HEIGHT}" rx="20"/>
        </clipPath>
    </defs>

    <!-- Background -->
    <g clip-path="url(#roundedClip)">
        <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#bgGrad)"/>
        <!-- Left accent border -->
        <rect x="0" y="0" width="5" height="${HEIGHT}" fill="#DC2626"/>

        <!-- Banner -->
        <rect x="0" y="0" width="${WIDTH}" height="${BANNER_H}" fill="url(#bannerGrad)"/>
        <text x="${WIDTH / 2}" y="${BANNER_H / 2 + 6}" text-anchor="middle" fill="white" font-size="17" font-weight="800" font-family="Arial, Helvetica, sans-serif" letter-spacing="0.3">Outstanding Payment Reminder</text>

        <!-- Company name -->
        <text x="${WIDTH / 2}" y="${BANNER_H + 36}" text-anchor="middle" fill="#1E293B" font-size="18" font-weight="800" font-family="Arial, Helvetica, sans-serif">${escapeXml(companyName)}</text>

        <!-- Client name (left) + Date (right) -->
        <text x="${PADDING + 4}" y="${BANNER_H + 16 + COMPANY_SECTION_H + 16}" fill="#1E293B" font-size="15" font-weight="bold" font-family="Arial, Helvetica, sans-serif">${escapeXml(sheetName)}</text>
        <text x="${WIDTH - PADDING}" y="${BANNER_H + 16 + COMPANY_SECTION_H + 16}" text-anchor="end" fill="#64748B" font-size="13" font-weight="500" font-family="Arial, Helvetica, sans-serif">${escapeXml(asOnDate)}</text>

        <!-- Bill cards -->
        ${billsSvg}

        <!-- Total row -->
        <rect x="${PADDING}" y="${totalY}" width="${WIDTH - 2 * PADDING}" height="${TOTAL_ROW_H}" rx="12" fill="rgba(220,38,38,0.08)"/>
        <rect x="${PADDING}" y="${totalY}" width="4" height="${TOTAL_ROW_H}" rx="2" fill="#DC2626"/>
        <text x="${PADDING + 16}" y="${totalY + 28}" fill="#64748B" font-size="15" font-weight="700" font-family="Arial, Helvetica, sans-serif">Total Outstanding</text>
        <text x="${PADDING + 190}" y="${totalY + 28}" fill="#94A3B8" font-size="11" font-weight="500" font-family="Arial, Helvetica, sans-serif">(&gt;Due Date)</text>
        <text x="${WIDTH - PADDING - 8}" y="${totalY + 32}" text-anchor="end" fill="#DC2626" font-size="20" font-weight="900" font-family="Arial, Helvetica, sans-serif">&#x20B9;${formatINR(totalAmount)}</text>
    </g>
    </svg>`;

    const svgBuffer = Buffer.from(svg);
    // sharp uses native bindings (libvips) which are not available on ICP WASM.
    // Fall back to returning SVG buffer directly if sharp is unavailable.
    if (!sharp) {
        return svgBuffer;
    }
    try {
        return await sharp(svgBuffer).png().toBuffer();
    } catch (e) {
        console.warn('[PaymentImageGen] sharp conversion failed, returning SVG:', e.message);
        return svgBuffer;
    }
}

module.exports = { generatePaymentImage };
