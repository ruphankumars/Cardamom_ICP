/**
 * Workers & Attendance — Firebase Firestore Backend
 * Drop-in replacement for ../workersAttendance.js
 */
const { getDb, createBatch } = require('../../src/backend/database/sqliteClient');

const WORKERS_COL = 'workers';
const ATTENDANCE_COL = 'attendance';

function workersCol() { return getDb().collection(WORKERS_COL); }
function attendanceCol() { return getDb().collection(ATTENDANCE_COL); }

function normalizeName(name) { return name.toLowerCase().replace(/\s+/g, '').trim(); }

function levenshteinDistance(a, b) {
    const m = Array.from({ length: b.length + 1 }, (_, i) => [i]);
    for (let j = 0; j <= a.length; j++) m[0][j] = j;
    for (let i = 1; i <= b.length; i++)
        for (let j = 1; j <= a.length; j++)
            m[i][j] = Math.min(m[i - 1][j] + 1, m[i][j - 1] + 1, m[i - 1][j - 1] + (a[j - 1] !== b[i - 1] ? 1 : 0));
    return m[b.length][a.length];
}

async function getWorkers(includeInactive = false) {
    const snap = await workersCol().get();
    let workers = snap.docs.map(doc => {
        const d = doc.data();
        return {
            ...d,
            _docId: doc.id,
            // Normalize fields: ensure team is always a string
            team: String(d.team ?? 'General'),
            baseDailyWage: Number(d.baseDailyWage) || 0,
        };
    });
    if (!includeInactive) workers = workers.filter(w => w.status !== 'Inactive');
    return workers;
}

async function searchWorkers(query) {
    const workers = await getWorkers(false);
    const q = normalizeName(query);
    const scored = workers.map(w => {
        const name = normalizeName(w.name || '');
        const exact = name.includes(q);
        const dist = levenshteinDistance(q, name.substring(0, q.length + 2));
        return { worker: w, score: exact ? 0 : dist };
    }).filter(s => s.score <= 3).sort((a, b) => a.score - b.score);
    return scored.map(s => s.worker).slice(0, 10);
}

async function addWorker(data) {
    // Duplicate check
    const workers = await getWorkers(true);
    const norm = normalizeName(data.name || '');
    const dup = workers.find(w => normalizeName(w.name || '') === norm);
    if (dup) {
        // If the duplicate was soft-deleted, reactivate it instead of rejecting
        if (dup.status === 'Inactive') {
            const snap = await workersCol().where('id', '==', dup.id).limit(1).get();
            if (!snap.empty) {
                const reactivated = { status: 'Active', deletedAt: null, phone: data.phone || dup.phone || '', baseDailyWage: Number(data.baseDailyWage) || dup.baseDailyWage || 0, team: data.team || dup.team || '', notes: data.notes || dup.notes || '' };
                await snap.docs[0].ref.update(reactivated);
                const worker = { ...dup, ...reactivated };
                console.log(`[Workers] Reactivated previously deleted worker: ${dup.name}`);
                return { success: true, worker, reactivated: true };
            }
        }
        return { success: false, error: 'Worker already exists', existingWorker: dup, isDuplicate: true };
    }

    const id = `W${Date.now()}`;
    const worker = { id, name: data.name, phone: data.phone || '', baseDailyWage: Number(data.baseDailyWage) || 0, team: data.team || '', status: 'Active', joinDate: new Date().toISOString().split('T')[0], notes: data.notes || '' };
    await workersCol().doc(id).set(worker);
    return { success: true, worker };
}

async function forceAddWorker(data) {
    const id = `W${Date.now()}`;
    const worker = { id, name: data.name, phone: data.phone || '', baseDailyWage: Number(data.baseDailyWage) || 0, team: data.team || '', status: 'Active', joinDate: new Date().toISOString().split('T')[0], notes: data.notes || '' };
    await workersCol().doc(id).set(worker);
    return { success: true, worker };
}

async function updateWorker(id, updates) {
    let snap = await workersCol().where('id', '==', id).limit(1).get();
    if (snap.empty) {
        // Fallback: search by name
        snap = await workersCol().where('name', '==', id).limit(1).get();
    }
    if (snap.empty) return { success: false, error: 'Worker not found' };
    await snap.docs[0].ref.update(updates);
    return { success: true, worker: { ...snap.docs[0].data(), ...updates } };
}

async function deleteWorker(id) {
    // Try by id field first
    let snap = await workersCol().where('id', '==', id).limit(1).get();
    if (snap.empty) {
        // Try by name
        snap = await workersCol().where('name', '==', id).limit(1).get();
    }
    if (snap.empty) return { success: false, error: 'Worker not found' };

    // Soft delete - set status to Inactive
    await snap.docs[0].ref.update({ status: 'Inactive', deletedAt: new Date().toISOString() });
    console.log(`[Workers] Soft-deleted worker: ${id}`);
    return { success: true, deleted: id };
}

async function getWorkerTeams() {
    const workers = await getWorkers(false);
    const teams = {};
    workers.forEach(w => {
        const team = w.team || 'Unassigned';
        if (!teams[team]) teams[team] = [];
        teams[team].push(w);
    });
    return teams;
}

// ---- Attendance ----

async function getAttendanceByDate(date) {
    const snap = await attendanceCol().where('date', '==', date).get();
    return snap.docs.map(doc => doc.data());
}

async function markAttendance(data) {
    // Enforce 7-day lock server-side
    const lockCheck = isRecordLocked(data.date);
    if (lockCheck.isLocked) {
        return { success: false, error: `Attendance record for ${data.date} is locked (older than 7 days)` };
    }

    const id = `${data.date}_${data.workerId}`;
    const now = new Date().toISOString();

    // Look up worker name and base wage if not provided
    let workerName = data.workerName || '';
    let baseDailyWage = Number(data.baseDailyWage) || 0;
    if (!workerName || !baseDailyWage) {
        const workers = await getWorkers(true);
        const worker = workers.find(w => w.id === data.workerId);
        if (worker) {
            workerName = workerName || worker.name || '';
            baseDailyWage = baseDailyWage || Number(worker.baseDailyWage) || 0;
        }
    }

    const docRef = attendanceCol().doc(id);
    const docSnap = await docRef.get();
    let existingRecord = docSnap.exists ? docSnap.data() : null;

    let scanTime = data.scanTime || now;
    let checkInTime = existingRecord ? existingRecord.checkInTime : scanTime;
    let checkOutTime = existingRecord ? scanTime : null; // If existing, this new scan is checkout

    // Prevent accidental double-scan: ignore checkout if less than 30 minutes since check-in
    if (existingRecord && checkOutTime) {
        const inDate = new Date(checkInTime);
        const outDate = new Date(checkOutTime);
        if (!isNaN(inDate.getTime()) && !isNaN(outDate.getTime())) {
            const minutesSinceCheckIn = (outDate - inDate) / (1000 * 60);
            if (minutesSinceCheckIn < 30) {
                return { success: false, message: `Checkout ignored: only ${Math.round(minutesSinceCheckIn)} minutes since check-in. Minimum 30 minutes required.` };
            }
        }
    }

    // Allow explicit override from frontend if needed
    if (data.checkInTime) checkInTime = data.checkInTime;
    if (data.checkOutTime) checkOutTime = data.checkOutTime;

    let status = data.status || (existingRecord ? existingRecord.status : 'present');
    let otHours = Number(data.otHours) || (existingRecord ? existingRecord.otHours : 0);

    // Auto-calculate if we have both checkIn and checkOut
    if (checkInTime && checkOutTime) {
        const inDate = new Date(checkInTime);
        const outDate = new Date(checkOutTime);
        if (!isNaN(inDate.getTime()) && !isNaN(outDate.getTime())) {
            const hoursWorked = (outDate - inDate) / (1000 * 60 * 60);

            if (hoursWorked < 4) {
                status = 'half_am';
                otHours = 0;
            } else if (hoursWorked >= 4 && hoursWorked <= 8) {
                status = 'full';
                otHours = 0;
            } else if (hoursWorked > 8) {
                status = 'ot';
                otHours = Math.round((hoursWorked - 8) * 100) / 100;
            }
        }
    } else if (!existingRecord && !data.status) {
        // Just checked in — mark as present (full day assumed)
        status = 'full';
    }

    // Use passed status/otHours if explicitly provided (manual override)
    if (data.status) status = data.status;
    if (data.otHours !== undefined) otHours = Number(data.otHours);

    const wageOverride = data.wageOverride != null ? Number(data.wageOverride) : null;
    const calculatedWage = calculateWage(baseDailyWage, status, otHours);
    const finalWage = wageOverride != null ? wageOverride : calculatedWage;

    const record = {
        id, date: data.date, workerId: data.workerId, workerName,
        status, otHours, otReason: data.otReason || '', 
        checkInTime, checkOutTime,
        wagePaid: finalWage, calculatedWage, finalWage, wageOverride,
        markedBy: data.markedBy || '', 
        markedAt: existingRecord ? existingRecord.markedAt : now, 
        updatedBy: existingRecord ? (data.markedBy || '') : '', 
        updatedAt: existingRecord ? now : ''
    };
    
    await docRef.set(record, { merge: true });
    return { success: true, attendance: record };
}

async function getAttendanceSummary(date) {
    const records = await getAttendanceByDate(date);
    const present = records.filter(r => ['present', 'full', 'full_day', 'overtime', 'ot'].includes(r.status)).length;
    const absent = records.filter(r => r.status === 'absent').length;
    const halfAm = records.filter(r => ['half_am'].includes(r.status)).length;
    const halfPm = records.filter(r => ['half_pm'].includes(r.status)).length;
    const halfDay = records.filter(r => ['half_day'].includes(r.status)).length;
    const otCount = records.filter(r => r.status === 'ot').length;
    const totalWages = records.reduce((sum, r) => sum + (parseFloat(r.wagePaid) || 0), 0);
    const totalOT = records.reduce((sum, r) => sum + (parseFloat(r.otHours) || 0), 0);

    // Enrich records with worker names if missing
    let enrichedRecords = records;
    const missingNames = records.filter(r => !r.workerName);
    if (missingNames.length > 0) {
        const allWorkers = await getWorkers(true);
        const workerMap = {};
        allWorkers.forEach(w => { workerMap[w.id] = w.name; });
        enrichedRecords = records.map(r => ({
            ...r,
            workerName: r.workerName || workerMap[r.workerId] || 'Unknown',
            finalWage: r.finalWage ?? r.wagePaid ?? 0,
        }));
    } else {
        enrichedRecords = records.map(r => ({
            ...r,
            finalWage: r.finalWage ?? r.wagePaid ?? 0,
        }));
    }

    return {
        date,
        total: records.length,
        totalWorkers: records.length,
        present, absent, halfDay,
        breakdown: { full: present, half_am: halfAm, half_pm: halfPm, ot: otCount },
        totalWages: Math.round(totalWages),
        totalOTHours: totalOT,
        records: enrichedRecords,
        workers: enrichedRecords,
    };
}

async function removeAttendance(date, workerId) {
    // Enforce 7-day lock server-side
    const lockCheck = isRecordLocked(date);
    if (lockCheck.isLocked) {
        return { success: false, error: `Attendance record for ${date} is locked (older than 7 days)` };
    }
    const id = `${date}_${workerId}`;
    await attendanceCol().doc(id).delete();
    return { success: true };
}

async function copyPreviousDayWorkers(fromDate, toDate, markedBy) {
    const prevRecords = await getAttendanceByDate(fromDate);
    if (prevRecords.length === 0) return { success: false, message: 'No records found for source date' };

    // Look up actual base wages from workers collection (wagePaid includes OT so it inflates)
    const allWorkers = await getWorkers(true);
    const workerMap = {};
    allWorkers.forEach(w => { workerMap[w.id] = w; });

    let copied = 0;
    for (const r of prevRecords) {
        const worker = workerMap[r.workerId];
        const baseDailyWage = worker ? (Number(worker.baseDailyWage) || 0) : 0;
        await markAttendance({ date: toDate, workerId: r.workerId, workerName: r.workerName, status: 'full', baseDailyWage, markedBy });
        copied++;
    }
    return { success: true, copiedCount: copied };
}

async function getAttendanceCalendar(year, month) {
    const monthStr = String(month).padStart(2, '0');
    const dateFrom = `${year}-${monthStr}-01`;
    const dateTo = `${year}-${monthStr}-31`; // Safe upper bound; Firestore string comparison handles it

    const snap = await attendanceCol()
        .where('date', '>=', dateFrom)
        .where('date', '<=', dateTo)
        .get();

    const calendar = {};
    snap.docs.forEach(doc => {
        const d = doc.data();
        if (!d.date) return;
        if (!calendar[d.date]) calendar[d.date] = { date: d.date, workerCount: 0, totalWages: 0 };
        calendar[d.date].workerCount++;
        calendar[d.date].totalWages += parseFloat(d.wagePaid) || 0;
    });
    return calendar;
}

function calculateWage(baseDailyWage, status, otHours = 0) {
    const base = parseFloat(baseDailyWage) || 0;
    if (status === 'absent' || status === 'leave') return 0;
    const otRate = Math.round(base / 8);
    const ot = (parseFloat(otHours) || 0) * otRate;
    if (status === 'half_day' || status === 'half_am' || status === 'half_pm') {
        return Math.round((base / 2) + ot); // Half-day base + any OT hours
    }
    return Math.round(base + ot);
}

function isRecordLocked(date) {
    const d = new Date(date);
    const now = new Date();
    const diffDays = Math.floor((now - d) / (1000 * 60 * 60 * 24));
    return { locked: diffDays > 7, daysOld: diffDays, lockAfterDays: 7 };
}

// ---- Face Attendance ----

async function storeFaceData(workerId, faceData) {
    const workerRef = workersCol().doc(workerId);
    const doc = await workerRef.get();
    if (!doc.exists) {
        // Try to find by 'id' field
        const snap = await workersCol().where('id', '==', workerId).limit(1).get();
        if (snap.empty) throw new Error('Worker not found');
        await snap.docs[0].ref.update({ faceData, faceEnrolledAt: new Date().toISOString() });
        return { success: true };
    }
    await workerRef.update({ faceData, faceEnrolledAt: new Date().toISOString() });
    return { success: true };
}

async function clearFaceData(workerId) {
    const workerRef = workersCol().doc(workerId);
    const doc = await workerRef.get();
    if (!doc.exists) {
        const snap = await workersCol().where('id', '==', workerId).limit(1).get();
        if (snap.empty) throw new Error('Worker not found');
        await snap.docs[0].ref.update({ faceData: null, faceEnrolledAt: null });
        return { success: true };
    }
    await workerRef.update({ faceData: null, faceEnrolledAt: null });
    return { success: true };
}

async function getAllFaceData() {
    const snap = await workersCol().get();
    return snap.docs
        .filter(doc => {
            const fd = doc.data().faceData;
            // Exclude null, undefined, and empty objects
            return fd != null && typeof fd === 'object' && Object.keys(fd).length > 0;
        })
        .map(doc => {
            const data = doc.data();
            return {
                workerId: data.id || doc.id,
                workerName: data.name,
                faceData: data.faceData,
            };
        });
}

module.exports = {
    getWorkers, searchWorkers, addWorker, forceAddWorker, updateWorker, deleteWorker, getWorkerTeams,
    getAttendanceByDate, markAttendance, getAttendanceSummary, removeAttendance,
    copyPreviousDayWorkers, getAttendanceCalendar, calculateWage, isRecordLocked,
    storeFaceData, clearFaceData, getAllFaceData
};
