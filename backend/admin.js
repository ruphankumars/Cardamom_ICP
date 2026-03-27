const stockCalc = require('./firebase/stock_fb');

async function recalcDeltaFromMenu() {
    return await stockCalc.updateAllStocks();
}

async function rebuildFromScratchFromMenu() {
    return await stockCalc.rebuildFromScratchAPI();
}

async function resetDeltaPointerFromMenu() {
    return await stockCalc.resetDeltaPointerAPI();
}

function showDeltaPointer() {
    return 'Firestore mode — delta pointer not applicable';
}

module.exports = {
    recalcDeltaFromMenu,
    rebuildFromScratchFromMenu,
    resetDeltaPointerFromMenu,
    showDeltaPointer
};
