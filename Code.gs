/**
 * ==========================================
 * UPDATED Code.gs - Order Status Flow
 * ==========================================
 * Status Flow: Pending → On Progress → Billed
 * - sygt_order_book: "Pending" (initial orders)
 * - cart_orders: "On Progress" (orders added to daily cart)
 * - packed_orders: "Billed" (archived/completed orders)
 */

// ============================================================================
// 1. AppConfig
// ============================================================================
var CFG = {
    sheets: {
        live: 'live_stock',
        abs: 'absolute_grades',
        comp: 'computed_stock',
        virt: 'virtual_stock',
        sale: 'sale_order',
        packedSale: 'packed_saleorder_quantity_tilldate',
        net: 'net_stock',
        orderBook: 'sygt_order_book',
        cart: 'cart_orders',
        packed: 'packed_orders',
        dropdown: 'DropdownData',
        adjust: 'stock_adjustments'
    },
    types: ['Colour Bold', 'Fruit Bold', 'Rejection'],
    absGrades: ['8 mm', '7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below'],
    virtualGrades: ['8.5 mm', '7.8 bold', '7 to 8 mm', '6.5 to 8 mm', '6.5 to 7.5 mm', '6 to 7 mm', 'Mini Bold', 'Pan'],
    saleOrderHeaders: ['8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm', 'Mini Bold', 'Pan'],
    // NEW: Order status constants
    status: {
        PENDING: 'Pending',
        ON_PROGRESS: 'On Progress',
        BILLED: 'Billed'
    }
};

// ============================================================================
// 2. AdminMenu
// ============================================================================
function onOpen() {
    SpreadsheetApp.getUi()
        .createMenu('Stock Admin')
        .addItem('Recalculate (Delta)', 'recalcDeltaFromMenu')
        .addItem('Merge All Orders → sale_order', 'rebuildSaleOrderFromAllSources')
        .addItem('Rebuild Packed Sale Order', 'rebuildPackedSaleOrderFromPackedOrders')
        .addSeparator()
        .addItem('Rebuild from scratch', 'rebuildFromScratchFromMenu')
        .addItem('Reset delta pointer', 'resetDeltaPointerFromMenu')
        .addSeparator()
        .addItem('Verify Order Integrity', 'verifyOrderIntegrityFromMenu')
        .addItem('Show delta pointer', 'showDeltaPointer')
        .addToUi();
}

function recalcDeltaFromMenu() {
    const ui = SpreadsheetApp.getUi();
    try {
        segregateBulkPurchase_appendDelta();
        calculateVirtualStock();
        calculateNetStock();
        const lastRow = SpreadsheetApp.getActive().getSheetByName(CFG.sheets.live).getLastRow();
        const ptr = PropertiesService.getScriptProperties().getProperty('LAST_PROCESSED_ROW') || '1';
        ui.alert('✅ Recalculate (Delta)', 'Stocks updated.\nLAST_PROCESSED_ROW: ' + ptr + '\n' + CFG.sheets.live + ' last row: ' + lastRow, ui.ButtonSet.OK);
    } catch (err) {
        ui.alert('❌ Recalculate failed', String(err), ui.ButtonSet.OK);
    }
}

function rebuildFromScratchFromMenu() {
    const ui = SpreadsheetApp.getUi();
    const confirm = ui.alert('Rebuild from scratch?', 'This will recompute ALL stocks including packed_saleorder_quantity_tilldate. Continue?', ui.ButtonSet.OK_CANCEL);
    if (confirm !== ui.Button.OK) return;
    try {
        const ss = SpreadsheetApp.getActive();
        const lastRow = ss.getSheetByName(CFG.sheets.live).getLastRow();
        
        // Clear packed_saleorder_quantity_tilldate before rebuild
        const packedSale = ss.getSheetByName(CFG.sheets.packedSale);
        if (packedSale && packedSale.getLastColumn() > 1) {
            packedSale.getRange(2, 2, 3, packedSale.getLastColumn() - 1).clearContent();
        }
        
        segregateBulkPurchase();
        calculateVirtualStock();
        rebuildSaleOrderFromAllSources();
        rebuildPackedSaleOrderFromPackedOrders(); // NEW: Rebuild from packed_orders
        calculateNetStock();
        PropertiesService.getScriptProperties().setProperty('LAST_PROCESSED_ROW', String(lastRow));
        ui.alert('🧹 Rebuild complete', 'Rebuilt all including packed_saleorder_quantity_tilldate.\nDelta pointer set to row: ' + lastRow, ui.ButtonSet.OK);
    } catch (err) {
        ui.alert('❌ Rebuild failed', String(err), ui.ButtonSet.OK);
    }
}

function resetDeltaPointerFromMenu() {
    const ui = SpreadsheetApp.getUi();
    const confirm = ui.alert('Reset delta pointer?', 'Next Delta run will re-read ALL rows. Continue?', ui.ButtonSet.OK_CANCEL);
    if (confirm !== ui.Button.OK) return;
    PropertiesService.getScriptProperties().deleteProperty('LAST_PROCESSED_ROW');
    ui.alert('🔁 Pointer reset', 'Run Recalculate (Delta) next.', ui.ButtonSet.OK);
}

function showDeltaPointer() {
    const ui = SpreadsheetApp.getUi();
    const ptr = PropertiesService.getScriptProperties().getProperty('LAST_PROCESSED_ROW') || '1';
    const lastRow = SpreadsheetApp.getActive().getSheetByName(CFG.sheets.live).getLastRow();
    ui.alert('ℹ️ Delta pointer', 'LAST_PROCESSED_ROW: ' + ptr + '\n' + CFG.sheets.live + ' last row: ' + lastRow, ui.ButtonSet.OK);
}

// ============================================================================
// 3. Helpers
// ============================================================================
function _norm(s) { return String(s || '').toLowerCase().replace(/\s+/g, ' ').trim(); }
const SALE_CANONICAL = ['8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm', 'mini bold', 'pan'];
let errorLog = [];

function safeNumber(value, context) {
    const num = parseFloat(value);
    if (isNaN(num) || value === '' || value === null || value === undefined) {
        if (context) errorLog.push('⚠️ Invalid data in: ' + context);
        return 0;
    }
    return num;
}

function getAdjustmentMap_() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const sheet = ss.getSheetByName(CFG.sheets.adjust);
    if (!sheet) return {};
    const data = sheet.getDataRange().getValues();
    if (!data || data.length <= 1) return {};
    const headers = data[0], rows = data.slice(1);
    const typeCol = headers.indexOf('Type'), gradeCol = headers.indexOf('Grade'), deltaCol = headers.indexOf('Delta Kgs');
    if (typeCol === -1 || gradeCol === -1 || deltaCol === -1) return {};
    const map = {};
    rows.forEach(row => {
        const type = String(row[typeCol] || '').trim();
        const grade = String(row[gradeCol] || '').trim();
        const delta = parseFloat(row[deltaCol]);
        if (!type || !grade || isNaN(delta) || delta === 0) return;
        if (!map[type]) map[type] = {};
        map[type][grade] = (map[type][grade] || 0) + delta;
    });
    return map;
}

// ============================================================================
// 4. Stock Calculations
// ============================================================================
function segregateBulkPurchase() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const bulkSheet = ss.getSheetByName(CFG.sheets.live);
    const absSheet = ss.getSheetByName(CFG.sheets.abs);
    const computedSheet = ss.getSheetByName(CFG.sheets.comp);
    const types = CFG.types, grades = CFG.absGrades;
    const lastRow = bulkSheet.getLastRow();
    if (lastRow < 2) throw new Error('❌ No bulk purchase data.');
    const rows = bulkSheet.getRange(2, 2, lastRow - 1, 3).getValues();
    let boldQty = 0, floatQty = 0, mediumQty = 0;
    for (const r of rows) { boldQty += parseFloat(r[0]) || 0; floatQty += parseFloat(r[1]) || 0; mediumQty += parseFloat(r[2]) || 0; }
    const ratioMatrix = absSheet.getRange(2, 2, 9, 6).getValues();
    const boldMatrix = ratioMatrix.slice(0, 3), floatMatrix = ratioMatrix.slice(3, 6), medMatrix = ratioMatrix.slice(6, 9);
    const finalMatrix = types.map((_, row) => grades.map((_, col) => Math.round(boldMatrix[row][col] * boldQty + floatMatrix[row][col] * floatQty + medMatrix[row][col] * mediumQty)));
    computedSheet.getRange(2, 2, 3, 6).setValues(finalMatrix);
}

function segregateBulkPurchase_appendDelta() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const props = PropertiesService.getScriptProperties();
    const bulkSheet = ss.getSheetByName(CFG.sheets.live);
    const absSheet = ss.getSheetByName(CFG.sheets.abs);
    const compSheet = ss.getSheetByName(CFG.sheets.comp);
    const lastRow = bulkSheet.getLastRow();
    const lastProcessed = parseInt(props.getProperty('LAST_PROCESSED_ROW') || '1', 10);
    if (lastRow <= lastProcessed) return;
    const newRows = bulkSheet.getRange(lastProcessed + 1, 2, lastRow - lastProcessed, 3).getValues();
    let bold = 0, floatB = 0, medium = 0;
    newRows.forEach(r => { bold += +r[0] || 0; floatB += +r[1] || 0; medium += +r[2] || 0; });
    const types = CFG.types, grades = CFG.absGrades;
    const ratio = absSheet.getRange(2, 2, 9, 6).getValues();
    const boldM = ratio.slice(0, 3), floatM = ratio.slice(3, 6), medM = ratio.slice(6, 9);
    let existing = compSheet.getRange(2, 2, 3, 6).getValues().map(row => row.map(v => +v || 0));
    const updated = types.map((_, r) => grades.map((_, c) => {
        let v = existing[r][c] + boldM[r][c] * bold + floatM[r][c] * floatB + medM[r][c] * medium;
        let out = Math.round(v); if (Object.is(out, -0)) out = 0; return out;
    }));
    compSheet.getRange(2, 2, 3, 6).setValues(updated);
    props.setProperty('LAST_PROCESSED_ROW', String(lastRow));
}

function calculateVirtualStock() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const compSheet = ss.getSheetByName(CFG.sheets.comp);
    const virtualSheet = ss.getSheetByName(CFG.sheets.virt);
    const types = CFG.types;
    const get = col => compSheet.getRange(2, col, 3).getValues().map(r => parseFloat(r[0]) || 0);
    const data = { '8 mm': get(2), '7.5 to 8 mm': get(3), '7 to 7.5 mm': get(4), '6.5 to 7 mm': get(5), '6 to 6.5 mm': get(6), '6 mm below': get(7) };
    const result = types.map((_, i) => {
        const e = data['8 mm'][i], se = data['7.5 to 8 mm'][i], s = data['7 to 7.5 mm'][i];
        const sf = data['6.5 to 7 mm'][i], sx = data['6 to 6.5 mm'][i], sb = data['6 mm below'][i];
        return [
            e > 0 ? Math.round(0.05 * e) : 0,
            e > 0 && se > 0 ? Math.round(2 * Math.min(e, se)) : 0,
            se > 0 && s > 0 ? Math.round(2 * Math.min(se, s)) : 0,
            se > 0 && s > 0 && sf > 0 ? Math.round(3 * Math.min(se, s, sf)) : 0,
            s > 0 && sf > 0 ? Math.round(2 * Math.min(s, sf)) : 0,
            sf > 0 && sx > 0 ? Math.round(2 * Math.min(sf, sx)) : 0,
            sb > 0 && sx > 0 ? Math.round(2 * Math.min(sb, sx)) : 0,
            sb > 0 ? Math.round(0.5 * sb) : 0
        ];
    });
    virtualSheet.getRange(2, 2, 3, 8).setValues(result);
}

function calculateNetStock() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const computedSheet = ss.getSheetByName(CFG.sheets.comp);
    const saleSheet = ss.getSheetByName(CFG.sheets.sale);
    const netSheet = ss.getSheetByName(CFG.sheets.net);
    const packedSaleSheet = ss.getSheetByName(CFG.sheets.packedSale);
    ensureNetHeaders();
    const types = CFG.types, ABS = CFG.absGrades;
    const adjMap = getAdjustmentMap_();
    const hdrRow = saleSheet.getRange(1, 2, 1, saleSheet.getLastColumn() - 1).getValues()[0] || [];
    const normKey = s => String(s || '').toLowerCase().replace(/\s+/g, ' ').replace(/\bmm\b/g, '').replace(/[–—-]/g, ' to ').replace(/\s+/g, '').trim();
    const hdrKeyToRel = {}; hdrRow.forEach((h, i) => { hdrKeyToRel[normKey(h)] = i; });
    const relIdxFor = label => { const k = normKey(label); return k in hdrKeyToRel ? hdrKeyToRel[k] : -1; };
    const getSold = (row, label) => { const rel = relIdxFor(label); return rel >= 0 ? (parseFloat(row[rel]) || 0) : 0; };
    const computed = computedSheet.getRange(2, 2, 3, 6).getValues().map(r => r.map(v => +v || 0));
    const saleWidth = hdrRow.length;
    const sales = saleSheet.getRange(2, 2, 3, saleWidth).getValues().map(r => r.map(v => +v || 0));
    
    let packedSales = [[],[],[]];
    if (packedSaleSheet && packedSaleSheet.getLastColumn() > 1) {
        const packedWidth = packedSaleSheet.getLastColumn() - 1;
        packedSales = packedSaleSheet.getRange(2, 2, 3, packedWidth).getValues().map(r => r.map(v => +v || 0));
    }
    const getPackedSold = (row, label) => { const rel = relIdxFor(label); return rel >= 0 && row[rel] !== undefined ? (parseFloat(row[rel]) || 0) : 0; };
    
    const out = [];
    for (let r = 0; r < types.length; r++) {
        const abs = computed[r].slice(), sold = sales[r], packed = packedSales[r] || [];
        
        for (let i = 0; i < ABS.length - 1; i++) abs[i] -= getSold(sold, ABS[i]);
        const q = { '8.5 mm': getSold(sold, '8.5 mm'), '7.8 bold': getSold(sold, '7.8 bold'), '7 to 8 mm': getSold(sold, '7 to 8 mm'), '6.5 to 8 mm': getSold(sold, '6.5 to 8 mm'), '6.5 to 7.5 mm': getSold(sold, '6.5 to 7.5 mm'), '6 to 7 mm': getSold(sold, '6 to 7 mm'), 'Mini Bold': getSold(sold, 'Mini Bold'), Pan: getSold(sold, 'Pan') };
        if (q['8.5 mm'] > 0) abs[0] -= 0.05 * q['8.5 mm'];
        if (q['7.8 bold'] > 0) { abs[0] -= 0.5 * q['7.8 bold']; abs[1] -= 0.5 * q['7.8 bold']; }
        if (q['7 to 8 mm'] > 0) { abs[1] -= 0.5 * q['7 to 8 mm']; abs[2] -= 0.5 * q['7 to 8 mm']; }
        if (q['6.5 to 8 mm'] > 0) { abs[1] -= q['6.5 to 8 mm'] / 3; abs[2] -= q['6.5 to 8 mm'] / 3; abs[3] -= q['6.5 to 8 mm'] / 3; }
        if (q['6.5 to 7.5 mm'] > 0) { abs[2] -= 0.5 * q['6.5 to 7.5 mm']; abs[3] -= 0.5 * q['6.5 to 7.5 mm']; }
        if (q['6 to 7 mm'] > 0) { abs[3] -= 0.5 * q['6 to 7 mm']; abs[4] -= 0.5 * q['6 to 7 mm']; }
        if (q['Mini Bold'] > 0) { abs[4] -= 0.5 * q['Mini Bold']; abs[5] -= 0.5 * q['Mini Bold']; }
        if (q.Pan > 0) abs[5] -= 0.5 * q.Pan;
        
        for (let i = 0; i < ABS.length - 1; i++) abs[i] -= getPackedSold(packed, ABS[i]);
        const pq = { '8.5 mm': getPackedSold(packed, '8.5 mm'), '7.8 bold': getPackedSold(packed, '7.8 bold'), '7 to 8 mm': getPackedSold(packed, '7 to 8 mm'), '6.5 to 8 mm': getPackedSold(packed, '6.5 to 8 mm'), '6.5 to 7.5 mm': getPackedSold(packed, '6.5 to 7.5 mm'), '6 to 7 mm': getPackedSold(packed, '6 to 7 mm'), 'Mini Bold': getPackedSold(packed, 'Mini Bold'), Pan: getPackedSold(packed, 'Pan') };
        if (pq['8.5 mm'] > 0) abs[0] -= 0.05 * pq['8.5 mm'];
        if (pq['7.8 bold'] > 0) { abs[0] -= 0.5 * pq['7.8 bold']; abs[1] -= 0.5 * pq['7.8 bold']; }
        if (pq['7 to 8 mm'] > 0) { abs[1] -= 0.5 * pq['7 to 8 mm']; abs[2] -= 0.5 * pq['7 to 8 mm']; }
        if (pq['6.5 to 8 mm'] > 0) { abs[1] -= pq['6.5 to 8 mm'] / 3; abs[2] -= pq['6.5 to 8 mm'] / 3; abs[3] -= pq['6.5 to 8 mm'] / 3; }
        if (pq['6.5 to 7.5 mm'] > 0) { abs[2] -= 0.5 * pq['6.5 to 7.5 mm']; abs[3] -= 0.5 * pq['6.5 to 7.5 mm']; }
        if (pq['6 to 7 mm'] > 0) { abs[3] -= 0.5 * pq['6 to 7 mm']; abs[4] -= 0.5 * pq['6 to 7 mm']; }
        if (pq['Mini Bold'] > 0) { abs[4] -= 0.5 * pq['Mini Bold']; abs[5] -= 0.5 * pq['Mini Bold']; }
        if (pq.Pan > 0) abs[5] -= 0.5 * pq.Pan;
        
        const adjForType = adjMap[types[r]] || {};
        for (let i = 0; i < ABS.length; i++) { abs[i] += adjForType[ABS[i]] || 0; }
        for (let i = 0; i < abs.length; i++) { abs[i] = Math.round(abs[i]); if (Object.is(abs[i], -0)) abs[i] = 0; }
        const virtual = [
            abs[0] > 0 ? Math.round(0.05 * abs[0]) : 0, abs[0] > 0 && abs[1] > 0 ? Math.round(2 * Math.min(abs[0], abs[1])) : 0,
            abs[1] > 0 && abs[2] > 0 ? Math.round(2 * Math.min(abs[1], abs[2])) : 0, abs[1] > 0 && abs[2] > 0 && abs[3] > 0 ? Math.round(3 * Math.min(abs[1], abs[2], abs[3])) : 0,
            abs[2] > 0 && abs[3] > 0 ? Math.round(2 * Math.min(abs[2], abs[3])) : 0, abs[3] > 0 && abs[4] > 0 ? Math.round(2 * Math.min(abs[3], abs[4])) : 0,
            abs[4] > 0 && abs[5] > 0 ? Math.round(2 * Math.min(abs[4], abs[5])) : 0, abs[5] > 0 ? Math.round(0.5 * abs[5]) : 0
        ];
        out.push([virtual[0], abs[0], virtual[1], abs[1], virtual[2], virtual[3], abs[2], virtual[4], abs[3], virtual[5], abs[4], abs[5], virtual[6], virtual[7]]);
    }
    netSheet.getRange(2, 2, 3, 14).setValues(out);
}

function ensureNetHeaders() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const net = ss.getSheetByName(CFG.sheets.net);
    if (!net) throw new Error('❌ net_stock sheet not found');
    const headers = ['8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm', '6 mm below', 'Mini Bold', 'Pan'];
    net.getRange(1, 2, 1, 14).setValues([headers]);
}

// ============================================================================
// 5. Order Book & Sale Order Functions
// ============================================================================
var OrderBook = (function () {
    function assignLotNumbers(sheet) {
        const data = sheet.getDataRange().getValues();
        const clientCol = 2, lotCol = 3;
        const lotCounters = {};
        for (let i = 1; i < data.length; i++) {
            const client = data[i][clientCol], lot = data[i][lotCol];
            if (client && lot && lot.toString().startsWith('L')) {
                const num = parseInt(lot.toString().substring(1), 10);
                if (!isNaN(num)) lotCounters[client] = Math.max(lotCounters[client] || 0, num);
            }
        }
        for (let i = 1; i < data.length; i++) {
            const client = data[i][clientCol]; let lot = data[i][lotCol];
            if (!client || (lot && lot.toString().startsWith('L'))) continue;
            lotCounters[client] = (lotCounters[client] || 0) + 1;
            sheet.getRange(i + 1, lotCol + 1).setValue('L' + lotCounters[client]);
        }
        SpreadsheetApp.flush();
    }
    return { assignLotNumbers };
})();

function _flexNorm(s) { return String(s || '').toLowerCase().replace(/\s+/g, ' ').trim(); }
const _SALE_CANON = ['8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm', 'mini bold', 'pan'];
const _SALE_ROW_INDEX = { 'Colour Bold': 2, 'Fruit Bold': 3, Rejection: 4 };

function _buildSaleIdxMap_(saleSheet) {
    const headers = saleSheet.getRange(1, 1, 1, saleSheet.getLastColumn()).getValues()[0] || [];
    const gradeHeads = headers.slice(1), normHeads = gradeHeads.map(_norm);
    const map = {};
    _SALE_CANON.forEach(canon => { const i = normHeads.findIndex(h => h === _norm(canon)); if (i >= 0) map[canon] = i; });
    return map;
}

function _pickCanonFromText_(gradeText) {
    const t = _flexNorm(gradeText);
    const isMini = /\bmini\b/.test(t) && /\bbold\b/.test(t);
    const isPan = /\bpan\b/.test(t);
    const isBold78 = /7\.?8\b/.test(t) && /\bbold\b/.test(t);
    if (isMini) return 'mini bold'; if (isPan) return 'pan'; if (isBold78) return '7.8 bold';
    const m = t.match(/(\d+(?:\.\d+)?)\s*(?:to|–|—|-)?\s*(\d+(?:\.\d+)?)?/);
    if (m) {
        const a = m[1] ? Math.round(parseFloat(m[1]) * 2) / 2 : null;
        const b = m[2] ? Math.round(parseFloat(m[2]) * 2) / 2 : null;
        if (a != null && b == null) { const single = a + ' mm'; if (_SALE_CANON.includes(single)) return single; }
        if (a != null && b != null) { const range = a + ' to ' + b + ' mm'; if (_SALE_CANON.includes(range)) return range; }
    }
    for (const c of _SALE_CANON) { if (t.includes(_flexNorm(c).replace(' mm', ''))) return c; }
    return null;
}

function _chooseSaleRowName_(gradeText) {
    const t = _norm(gradeText);
    if (t.includes('colour') || t.includes('color')) return 'Colour Bold';
    if (t.includes('fruit')) return 'Fruit Bold';
    if (t.includes('rejection') || t.includes('split')) return 'Rejection';
    return null;
}

function _addToCell_(sheet, r, c, q) { const cur = +sheet.getRange(r, c).getValue() || 0; sheet.getRange(r, c).setValue(cur + Number(q)); }
function _subtractFromCell_(sheet, r, c, q) { const cur = +sheet.getRange(r, c).getValue() || 0; sheet.getRange(r, c).setValue(cur - Number(q)); }

// ============================================================================
// 6. Rebuild Sale Order - UPDATED for Status Flow
// ============================================================================
function rebuildSaleOrderFromAllSources() {
    const ss = SpreadsheetApp.getActive();
    const sale = ss.getSheetByName(CFG.sheets.sale);
    if (!sale) throw new Error('❌ sale_order sheet not found');
    const lastRow = sale.getLastRow(), lastCol = sale.getLastColumn();
    if (lastRow >= 2 && lastCol >= 2) sale.getRange(2, 2, lastRow - 1, lastCol - 1).clearContent();
    
    // Merge from sygt_order_book (Pending orders only)
    mergeSygtIntoSaleOrder();
    // Merge from cart_orders (On Progress orders)
    mergeCartIntoSaleOrder();
    
    recalcAllStocksQuick();
    SpreadsheetApp.getActive().toast('Sale order rebuilt from all sources ✔');
}

// Merge sygt_order_book: ONLY "Pending" status orders
function mergeSygtIntoSaleOrder() {
    const ss = SpreadsheetApp.getActive();
    const sale = ss.getSheetByName(CFG.sheets.sale);
    const orders = ss.getSheetByName(CFG.sheets.orderBook);
    if (!orders) return;
    const data = orders.getDataRange().getValues();
    const hdr = data[0], rows = data.slice(1);
    const iGrade = hdr.indexOf('Grade'), iKgs = hdr.indexOf('Kgs'), iStatus = hdr.indexOf('Status');
    if (iGrade < 0 || iKgs < 0 || iStatus < 0) return;
    const saleIdxMap = _buildSaleIdxMap_(sale);
    rows.forEach(row => {
        // UPDATED: Only include "Pending" status orders
        if (_norm(row[iStatus]) !== _norm(CFG.status.PENDING)) return;
        const gradeText = String(row[iGrade] || ''), qty = parseFloat(row[iKgs]) || 0;
        if (!qty) return;
        const saleRowName = _chooseSaleRowName_(gradeText);
        if (!saleRowName) return;
        const rIdx = _SALE_ROW_INDEX[saleRowName]; if (!rIdx) return;
        
        const t = _norm(gradeText);
        if (t.includes('6.5 above') && saleRowName === 'Rejection') {
            const rel8mm = saleIdxMap['8 mm'];
            const rel65to8 = saleIdxMap['6.5 to 8 mm'];
            if (rel8mm != null && rel65to8 != null) {
                _addToCell_(sale, rIdx, 2 + rel8mm, Math.ceil(qty * 0.25));
                _addToCell_(sale, rIdx, 2 + rel65to8, Math.ceil(qty * 0.75));
                return;
            }
        }
        
        const canon = _pickCanonFromText_(gradeText);
        if (!canon || saleIdxMap[canon] == null) return;
        _addToCell_(sale, rIdx, 2 + saleIdxMap[canon], qty);
    });
    SpreadsheetApp.flush();
}

// Merge cart_orders: ONLY "On Progress" status orders
function mergeCartIntoSaleOrder() {
    const ss = SpreadsheetApp.getActive();
    const sale = ss.getSheetByName(CFG.sheets.sale);
    const cart = ss.getSheetByName(CFG.sheets.cart);
    if (!cart) return;
    const data = cart.getDataRange().getValues();
    if (data.length <= 1) return;
    const hdr = data[0], rows = data.slice(1);
    const iGrade = hdr.indexOf('Grade'), iKgs = hdr.indexOf('Kgs'), iStatus = hdr.indexOf('Status');
    if (iGrade < 0 || iKgs < 0) return;
    const saleIdxMap = _buildSaleIdxMap_(sale);
    rows.forEach(row => {
        const status = iStatus >= 0 ? _norm(row[iStatus]) : _norm(CFG.status.ON_PROGRESS);
        // UPDATED: Only include "On Progress" status orders
        if (status !== _norm(CFG.status.ON_PROGRESS)) return;
        const gradeText = String(row[iGrade] || ''), qty = parseFloat(row[iKgs]) || 0;
        if (!qty) return;
        const saleRowName = _chooseSaleRowName_(gradeText) || 'Colour Bold';
        const rIdx = _SALE_ROW_INDEX[saleRowName]; if (!rIdx) return;
        
        const t = _norm(gradeText);
        if (t.includes('6.5 above') && saleRowName === 'Rejection') {
            const rel8mm = saleIdxMap['8 mm'];
            const rel65to8 = saleIdxMap['6.5 to 8 mm'];
            if (rel8mm != null && rel65to8 != null) {
                _addToCell_(sale, rIdx, 2 + rel8mm, Math.ceil(qty * 0.25));
                _addToCell_(sale, rIdx, 2 + rel65to8, Math.ceil(qty * 0.75));
                return;
            }
        }
        
        const canon = _pickCanonFromText_(gradeText);
        if (!canon || saleIdxMap[canon] == null) return;
        _addToCell_(sale, rIdx, 2 + saleIdxMap[canon], qty);
    });
    SpreadsheetApp.flush();
}

// ============================================================================
// 7. Handle Packed Orders - UPDATED to set "Billed" status
// ============================================================================
function handleOrderMovedToPacked(type, grade, qty) {
    const ss = SpreadsheetApp.getActive();
    const sale = ss.getSheetByName(CFG.sheets.sale);
    if (!sale) return;
    
    let packedSale = ss.getSheetByName(CFG.sheets.packedSale);
    if (!packedSale) {
        packedSale = ss.insertSheet(CFG.sheets.packedSale);
        const saleHeaders = sale.getRange(1, 1, 1, sale.getLastColumn()).getValues();
        packedSale.getRange(1, 1, 1, saleHeaders[0].length).setValues(saleHeaders);
        const typeLabels = sale.getRange(2, 1, 3, 1).getValues();
        packedSale.getRange(2, 1, 3, 1).setValues(typeLabels);
        const numCols = saleHeaders[0].length - 1;
        packedSale.getRange(2, 2, 3, numCols).setValues([Array(numCols).fill(0), Array(numCols).fill(0), Array(numCols).fill(0)]);
    }
    
    const saleIdxMap = _buildSaleIdxMap_(sale);
    const saleRowName = CFG.types.includes(type) ? type : _chooseSaleRowName_(grade);
    if (!saleRowName) return;
    const rIdx = _SALE_ROW_INDEX[saleRowName]; if (!rIdx) return;
    const canon = _pickCanonFromText_(grade);
    if (!canon || saleIdxMap[canon] == null) return;
    
    const saleCol = 2 + saleIdxMap[canon];
    const currentVal = +sale.getRange(rIdx, saleCol).getValue() || 0;
    sale.getRange(rIdx, saleCol).setValue(Math.max(0, currentVal - qty));
    _addToCell_(packedSale, rIdx, saleCol, qty);
    
    recalcAllStocksQuick();
}

function recalcAllStocksQuick() {
    const lock = LockService.getDocumentLock();
    if (!lock.tryLock(30000)) return;
    try {
        segregateBulkPurchase_appendDelta();
        calculateVirtualStock();
        calculateNetStock();
    } finally { lock.releaseLock(); }
}

// ============================================================================
// 8. onEdit Trigger - UPDATED for Status Flow
// ============================================================================
function onEdit(e) {
    if (!e) return;
    const sheet = e.source.getActiveSheet();
    const name = sheet.getName();
    const range = e.range;
    const startCol = range.getColumn(), endCol = startCol + range.getNumColumns() - 1;
    const startRow = range.getRow(), endRow = startRow + range.getNumRows() - 1;

    // sygt_order_book: Ensure new orders get "Pending" status
    if (name === CFG.sheets.orderBook) {
        if (startRow >= 2) {
            if (endCol >= 1 && startCol <= 4) {
                try { OrderBook.assignLotNumbers(sheet); } catch (err) { Logger.log(err); }
            }
            
            // Auto-set status to "Pending" if Status column is empty
            const iStatus = 10; // Status is column K (11th column, 0-indexed = 10)
            for (let r = startRow; r <= endRow; r++) {
                const currentStatus = sheet.getRange(r, iStatus + 1).getValue();
                if (!currentStatus || String(currentStatus).trim() === '') {
                    sheet.getRange(r, iStatus + 1).setValue(CFG.status.PENDING);
                }
            }
            
            // Auto-calculate Kgs
            if ((startCol <= 7 && endCol >= 6) || (startCol <= 6 && endCol >= 6) || (startCol <= 7 && endCol >= 7)) {
                try {
                    for (let r = startRow; r <= endRow; r++) {
                        const bagBox = String(sheet.getRange(r, 6).getValue() || '').toLowerCase().trim();
                        const noVal = parseFloat(sheet.getRange(r, 7).getValue()) || 0;
                        if (bagBox && noVal > 0) {
                            let weightPerUnit = bagBox === 'bag' ? 50 : (bagBox === 'box' ? 25 : 0);
                            if (weightPerUnit > 0) sheet.getRange(r, 8).setValue(noVal * weightPerUnit);
                        }
                    }
                } catch (err) { Logger.log('Kgs auto-calc error: ' + err); }
            }
            
            try { rebuildSaleOrderFromAllSources(); } catch (err) { Logger.log(err); }
        }
        return;
    }

    // cart_orders: Orders here should have "On Progress" status
    if (name === CFG.sheets.cart) {
        if (startRow >= 2) {
            // Ensure status is "On Progress" for cart orders
            const iStatus = 10; // Status column
            for (let r = startRow; r <= endRow; r++) {
                const currentStatus = sheet.getRange(r, iStatus + 1).getValue();
                if (!currentStatus || String(currentStatus).trim() === '' || _norm(currentStatus) === _norm(CFG.status.PENDING)) {
                    sheet.getRange(r, iStatus + 1).setValue(CFG.status.ON_PROGRESS);
                }
            }
            try { rebuildSaleOrderFromAllSources(); } catch (err) { Logger.log(err); }
        }
        return;
    }

    // packed_orders: Orders here should have "Billed" status
    if (name === CFG.sheets.packed) {
        if (startRow >= 2) {
            try {
                const data = sheet.getDataRange().getValues();
                const hdr = data[0];
                const iGrade = hdr.indexOf('Grade');
                const iKgs = hdr.indexOf('Kgs');
                const iStatus = hdr.indexOf('Status');
                
                if (iGrade >= 0 && iKgs >= 0) {
                    for (let r = startRow; r <= endRow && r <= data.length; r++) {
                        const row = data[r - 1];
                        const status = String(row[iStatus] || '').toLowerCase();
                        
                        // UPDATED: Set status to "Billed" and process
                        if (status !== 'billed' && status !== 'subtracted') {
                            const gradeText = String(row[iGrade] || '');
                            const qty = parseFloat(row[iKgs]) || 0;
                            
                            if (gradeText && qty > 0) {
                                const type = _chooseSaleRowName_(gradeText) || 'Colour Bold';
                                handleOrderMovedToPacked(type, gradeText, qty);
                                // Set status to "Billed"
                                if (iStatus >= 0) {
                                    sheet.getRange(r, iStatus + 1).setValue(CFG.status.BILLED);
                                }
                            }
                        }
                    }
                }
            } catch (err) { Logger.log('packed_orders error: ' + err); }
        }
        return;
    }

    // sale_order: recalc net stock
    if (name === CFG.sheets.sale && startRow >= 2) {
        try { recalcAllStocksQuick(); } catch (err) { Logger.log(err); }
        return;
    }

    // stock_adjustments
    if (name === CFG.sheets.adjust && startRow >= 2) {
        try { calculateNetStock(); } catch (err) { Logger.log(err); }
        return;
    }

    // live_stock
    if (name === CFG.sheets.live && startRow >= 2) {
        try {
            segregateBulkPurchase();
            calculateVirtualStock();
            calculateNetStock();
            PropertiesService.getScriptProperties().setProperty('LAST_PROCESSED_ROW', String(sheet.getLastRow()));
        } catch (err) { Logger.log('live_stock recalc error: ' + err); }
        return;
    }
}

// ============================================================================
// 9. API Functions
// ============================================================================
function getNetStockPayloadForDashboard() {
    const ss = SpreadsheetApp.getActive();
    const sh = ss.getSheetByName(CFG.sheets.net);
    if (!sh) throw new Error('Sheet not found: ' + CFG.sheets.net);
    ensureNetHeaders();
    const headers = sh.getRange(1, 2, 1, 14).getValues()[0];
    const rows = sh.getRange(2, 2, 3, 14).getValues();
    return { headers: headers, rows: rows };
}

function updateAllStocks() {
    try {
        errorLog = [];
        segregateBulkPurchase_appendDelta();
        calculateVirtualStock();
        calculateNetStock();
        let dashboardHtml = validateSaleOrder();
        if (errorLog.length > 0) dashboardHtml = '<h3>⚠️ Issues:</h3><ul>' + errorLog.map(e => '<li>' + e + '</li>').join('') + '</ul>' + dashboardHtml;
        return { message: '✅ Stocks recalculated (Delta).', dashboard: dashboardHtml };
    } catch (err) {
        return { message: '❌ Error: ' + err.message, dashboard: '' };
    }
}

function validateSaleOrder() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const netSheet = ss.getSheetByName(CFG.sheets.net);
    const types = ['Colour Bold', 'Fruit Bold', 'Rejection'];
    const displayAbsGrades = ['8 mm', '7.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7 mm', '6 to 6.5 mm', '6 mm below'];
    const absColMap = { '8 mm': 1, '7.5 to 8 mm': 3, '7 to 7.5 mm': 6, '6.5 to 7 mm': 8, '6 to 6.5 mm': 10, '6 mm below': 11 };
    const data = netSheet.getRange(2, 2, 3, 14).getValues();
    let stockHtml = "<h3>📊 Stock Summary</h3><table><tr><th>Type</th>";
    displayAbsGrades.forEach(g => { stockHtml += '<th>' + g + '</th>'; });
    stockHtml += '</tr>';
    for (let t = 0; t < types.length; t++) {
        stockHtml += '<tr><td><b>' + types[t] + '</b></td>';
        for (const g of displayAbsGrades) {
            const absQty = parseFloat(data[t][absColMap[g]]) || 0;
            stockHtml += "<td style='color:" + (absQty < 0 ? 'red' : 'green') + ";font-weight:bold'>" + Math.round(absQty) + '</td>';
        }
        stockHtml += '</tr>';
    }
    stockHtml += '</table>';
    return getDeltaStatusHtml() + stockHtml;
}

function getDeltaStatusHtml() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const bulkSheet = ss.getSheetByName(CFG.sheets.live);
    const props = PropertiesService.getScriptProperties();
    const lastRow = bulkSheet.getLastRow();
    const ptr = parseInt(props.getProperty('LAST_PROCESSED_ROW') || '1', 10);
    const pending = Math.max(0, lastRow - ptr);
    return '<div style="border-left:6px solid ' + (pending > 0 ? '#f39c12' : '#27ae60') + ';background:#fff;padding:14px;margin:10px 0 18px 0;border-radius:10px">' +
        '<b>⚙️ Delta Status</b><br>Processed: ' + ptr + ' | Last Row: ' + lastRow + ' | Pending: <b style="color:' + (pending > 0 ? '#d35400' : '#27ae60') + '">' + pending + '</b></div>';
}

function resetDeltaPointerAPI() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    ss.getSheetByName(CFG.sheets.comp).getRange(2, 2, 3, 6).setValues([[0,0,0,0,0,0],[0,0,0,0,0,0],[0,0,0,0,0,0]]);
    PropertiesService.getScriptProperties().setProperty('LAST_PROCESSED_ROW', '1');
    return '🔁 Pointer reset. Click Recalculate.';
}

function rebuildFromScratchAPI() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const liveSheet = ss.getSheetByName(CFG.sheets.live);
    const compSheet = ss.getSheetByName(CFG.sheets.comp);
    const packedSale = ss.getSheetByName(CFG.sheets.packedSale);
    const lastRow = liveSheet.getLastRow();
    
    // Clear computed_stock
    if (compSheet) compSheet.getRange(2, 2, 3, 6).setValues([[0,0,0,0,0,0],[0,0,0,0,0,0],[0,0,0,0,0,0]]);
    
    // Clear packed_saleorder_quantity_tilldate
    if (packedSale && packedSale.getLastColumn() > 1) {
        packedSale.getRange(2, 2, 3, packedSale.getLastColumn() - 1).clearContent();
    }
    
    segregateBulkPurchase();
    calculateVirtualStock();
    rebuildSaleOrderFromAllSources();
    rebuildPackedSaleOrderFromPackedOrders(); // NEW: Rebuild from packed_orders
    calculateNetStock();
    PropertiesService.getScriptProperties().setProperty('LAST_PROCESSED_ROW', String(lastRow));
    return '🧹 Rebuilt from scratch!\n• sale_order: rebuilt from sygt_order_book + cart_orders\n• packed_saleorder_quantity_tilldate: rebuilt from packed_orders\n• Delta pointer set to row: ' + lastRow;
}

/**
 * Rebuild packed_saleorder_quantity_tilldate from all orders in packed_orders sheet
 */
function rebuildPackedSaleOrderFromPackedOrders() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const packed = ss.getSheetByName(CFG.sheets.packed);
    const sale = ss.getSheetByName(CFG.sheets.sale);
    
    if (!packed || !sale) return;
    
    const data = packed.getDataRange().getValues();
    if (data.length <= 1) return;
    
    const hdr = data[0], rows = data.slice(1);
    const iGrade = hdr.indexOf('Grade');
    const iKgs = hdr.indexOf('Kgs');
    
    if (iGrade < 0 || iKgs < 0) return;
    
    // Ensure packed_saleorder_quantity_tilldate sheet exists
    let packedSale = ss.getSheetByName(CFG.sheets.packedSale);
    if (!packedSale) {
        packedSale = ss.insertSheet(CFG.sheets.packedSale);
        const saleHeaders = sale.getRange(1, 1, 1, sale.getLastColumn()).getValues();
        packedSale.getRange(1, 1, 1, saleHeaders[0].length).setValues(saleHeaders);
        const typeLabels = sale.getRange(2, 1, 3, 1).getValues();
        packedSale.getRange(2, 1, 3, 1).setValues(typeLabels);
    }
    
    const saleIdxMap = _buildSaleIdxMap_(sale);
    const numCols = sale.getLastColumn() - 1;
    
    // Initialize matrix with zeros
    const matrix = [
        Array(numCols).fill(0),
        Array(numCols).fill(0),
        Array(numCols).fill(0)
    ];
    
    // Process each packed order
    let processedCount = 0;
    rows.forEach(row => {
        const gradeText = String(row[iGrade] || '');
        const qty = parseFloat(row[iKgs]) || 0;
        
        if (!gradeText || qty <= 0) return;
        
        const saleRowName = _chooseSaleRowName_(gradeText) || 'Colour Bold';
        const rIdx = _SALE_ROW_INDEX[saleRowName];
        if (!rIdx) return;
        
        const canon = _pickCanonFromText_(gradeText);
        if (!canon || saleIdxMap[canon] == null) return;
        
        const colIdx = saleIdxMap[canon];
        matrix[rIdx - 2][colIdx] += qty;
        processedCount++;
    });
    
    // Write to packed_saleorder_quantity_tilldate
    packedSale.getRange(2, 2, 3, numCols).setValues(matrix);
    Logger.log('Rebuilt packed_saleorder_quantity_tilldate from ' + processedCount + ' orders');
}

function addStockAdjustment(adj) {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    let sheet = ss.getSheetByName(CFG.sheets.adjust);
    if (!sheet) { sheet = ss.insertSheet(CFG.sheets.adjust); sheet.getRange(1, 1, 1, 5).setValues([['Date', 'Type', 'Grade', 'Delta Kgs', 'Reason']]); }
    const type = String(adj.type || '').trim(), grade = String(adj.grade || '').trim(), delta = parseFloat(adj.delta), reason = String(adj.reason || '').trim();
    if (!type || !grade || isNaN(delta) || delta === 0) throw new Error('Invalid adjustment.');
    let dateVal = adj.date ? new Date(adj.date) : new Date(); if (isNaN(dateVal.getTime())) dateVal = new Date();
    sheet.appendRow([dateVal, type, grade, delta, reason || '']);
    calculateNetStock();
    return '✅ Adjustment added.';
}

function getNetStockForUi() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const net = ss.getSheetByName(CFG.sheets.net);
    ensureNetHeaders();
    const labels = net.getRange(2, 1, 3, 1).getValues().map(r => String(r[0] || '').trim());
    const data = net.getRange(2, 2, 3, 14).getValues();
    const headers = ['8.5 mm', '8 mm', '7.8 bold', '7.5 to 8 mm', '7 to 8 mm', '6.5 to 8 mm', '7 to 7.5 mm', '6.5 to 7.5 mm', '6.5 to 7 mm', '6 to 7 mm', '6 to 6.5 mm', '6 mm below', 'Mini Bold', 'Pan'];
    const rows = data.map((row, i) => ({ type: labels[i] || CFG.types[i], values: row.map(v => +v || 0) }));
    return { headers, rows };
}

function addTodayPurchase(qtyArray) {
    if (!Array.isArray(qtyArray) || qtyArray.length !== 3) return '❌ Invalid purchase data.';
    const [boldQty, floatQty, mediumQty] = qtyArray.map(q => parseFloat(q) || 0);
    if (boldQty <= 0 && floatQty <= 0 && mediumQty <= 0) return '❌ Enter at least one valid quantity.';
    SpreadsheetApp.getActiveSpreadsheet().getSheetByName(CFG.sheets.live).appendRow([new Date(), boldQty, floatQty, mediumQty]);
    return '✅ Added: Bold: ' + boldQty + ' kg, Floating: ' + floatQty + ' kg, Medium: ' + mediumQty + ' kg';
}

/**
 * Verify order integrity - checks that sale_order and packed_saleorder match their source orders GRADE-WISE
 */
function verifyOrderIntegrityFromMenu() {
    const ui = SpreadsheetApp.getUi();
    try {
        const result = verifyOrderIntegrity();
        if (result.healthy) {
            ui.alert('✅ Integrity Check Passed', result.message + '\n\n' + formatIntegritySummary(result.summary), ui.ButtonSet.OK);
        } else {
            let issueList = result.issues.map(i => '• ' + i.message).join('\n');
            ui.alert('⚠️ Integrity Issues Found', result.message + '\n\n' + issueList + '\n\nClick "Rebuild from scratch" to fix.', ui.ButtonSet.OK);
        }
    } catch (err) {
        ui.alert('❌ Integrity Check Failed', String(err), ui.ButtonSet.OK);
    }
}

function formatIntegritySummary(summary) {
    let msg = '';
    if (summary.orders) {
        msg += 'sygt_order_book (Pending): ' + (summary.orders.sygtPending || 0) + ' kg\n';
        msg += 'cart_orders (On Progress): ' + (summary.orders.cartOnProgress || 0) + ' kg\n';
        msg += 'Expected sale_order total: ' + (summary.orders.expectedSaleTotal || 0) + ' kg\n';
        msg += 'Actual sale_order total: ' + (summary.saleOrder?.actualTotal || 0) + ' kg\n\n';
        msg += 'packed_orders: ' + (summary.orders.packedOrders || 0) + ' kg\n';
        msg += 'Actual packed_saleorder: ' + (summary.packedSale?.actualTotal || 0) + ' kg';
    }
    return msg;
}

function verifyOrderIntegrity() {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const issues = [];
    const summary = { saleOrder: {}, packedSale: {}, orders: {} };
    
    // 1. Calculate expected sale_order from sygt (Pending) + cart (On Progress)
    let expectedSaleTotal = 0;
    
    const sygt = ss.getSheetByName(CFG.sheets.orderBook);
    if (sygt) {
        const sygtData = sygt.getDataRange().getValues();
        const h = sygtData[0];
        const iKgs = h.indexOf('Kgs'), iStatus = h.indexOf('Status');
        let sygtTotal = 0;
        sygtData.slice(1).forEach(row => {
            if (_norm(row[iStatus]) === 'pending') {
                sygtTotal += parseFloat(row[iKgs]) || 0;
            }
        });
        summary.orders.sygtPending = Math.round(sygtTotal);
        expectedSaleTotal += sygtTotal;
    }
    
    const cart = ss.getSheetByName(CFG.sheets.cart);
    if (cart) {
        const cartData = cart.getDataRange().getValues();
        const h = cartData[0];
        const iKgs = h.indexOf('Kgs'), iStatus = h.indexOf('Status');
        let cartTotal = 0;
        cartData.slice(1).forEach(row => {
            if (_norm(row[iStatus]) === 'on progress') {
                cartTotal += parseFloat(row[iKgs]) || 0;
            }
        });
        summary.orders.cartOnProgress = Math.round(cartTotal);
        expectedSaleTotal += cartTotal;
    }
    
    summary.orders.expectedSaleTotal = Math.round(expectedSaleTotal);
    
    // 2. Read actual sale_order total
    const sale = ss.getSheetByName(CFG.sheets.sale);
    let actualSaleTotal = 0;
    if (sale && sale.getLastColumn() > 1) {
        const saleData = sale.getRange(2, 2, 3, sale.getLastColumn() - 1).getValues();
        saleData.forEach(row => {
            row.forEach(v => { actualSaleTotal += parseFloat(v) || 0; });
        });
    }
    summary.saleOrder = { actualTotal: Math.round(actualSaleTotal) };
    
    if (Math.abs(expectedSaleTotal - actualSaleTotal) > 1) {
        issues.push({
            type: 'SALE_ORDER_MISMATCH',
            message: 'sale_order (' + Math.round(actualSaleTotal) + 'kg) ≠ expected (' + Math.round(expectedSaleTotal) + 'kg from sygt+cart)'
        });
    }
    
    // 3. Calculate expected packed_saleorder from packed_orders
    const packed = ss.getSheetByName(CFG.sheets.packed);
    let expectedPackedTotal = 0;
    if (packed) {
        const packedData = packed.getDataRange().getValues();
        const h = packedData[0];
        const iKgs = h.indexOf('Kgs');
        packedData.slice(1).forEach(row => {
            expectedPackedTotal += parseFloat(row[iKgs]) || 0;
        });
    }
    summary.orders.packedOrders = Math.round(expectedPackedTotal);
    
    // 4. Read actual packed_saleorder_quantity_tilldate total
    const packedSale = ss.getSheetByName(CFG.sheets.packedSale);
    let actualPackedSaleTotal = 0;
    if (packedSale && packedSale.getLastColumn() > 1) {
        const pData = packedSale.getRange(2, 2, 3, packedSale.getLastColumn() - 1).getValues();
        pData.forEach(row => {
            row.forEach(v => { actualPackedSaleTotal += parseFloat(v) || 0; });
        });
    }
    summary.packedSale = { actualTotal: Math.round(actualPackedSaleTotal) };
    
    if (Math.abs(expectedPackedTotal - actualPackedSaleTotal) > 1) {
        issues.push({
            type: 'PACKED_SALE_MISMATCH',
            message: 'packed_saleorder (' + Math.round(actualPackedSaleTotal) + 'kg) ≠ packed_orders (' + Math.round(expectedPackedTotal) + 'kg)'
        });
    }
    
    return {
        healthy: issues.length === 0,
        issues: issues,
        summary: summary,
        message: issues.length === 0 ? '✅ All order quantities are in sync' : '⚠️ Found ' + issues.length + ' integrity issue(s)'
    };
}
