/**
 * Task Manager — Firebase Firestore Backend
 * Drop-in replacement for ../taskManager.js
 */
const { v4: uuidv4 } = require('uuid');
const { getDb } = require('../firebaseClient');

const COL = 'tasks';
function col() { return getDb().collection(COL); }

// ============================================
// Task State Machine Validation
// ============================================

/**
 * Define valid state transitions for task statuses.
 * Each status maps to an array of allowed next statuses.
 */
const VALID_TRANSITIONS = {
    'pending': ['in_progress', 'cancelled'],
    'in_progress': ['completed', 'on_hold', 'cancelled'],
    'on_hold': ['in_progress', 'cancelled'],
    'completed': [], // Terminal state
    'cancelled': [] // Terminal state
};

/**
 * Check if a transition from currentStatus to newStatus is valid.
 * Returns { isValid: boolean, error: string | null }
 */
function validateStateTransition(currentStatus, newStatus) {
    // If same status, it's allowed (no-op)
    if (currentStatus === newStatus) {
        return { isValid: true, error: null };
    }

    // Check if current status is defined in state machine
    if (!VALID_TRANSITIONS.hasOwnProperty(currentStatus)) {
        return {
            isValid: false,
            error: `Unknown current status: '${currentStatus}'`
        };
    }

    // Check if new status is a valid transition
    if (!VALID_TRANSITIONS[currentStatus].includes(newStatus)) {
        const allowed = VALID_TRANSITIONS[currentStatus].length > 0
            ? VALID_TRANSITIONS[currentStatus].join(', ')
            : 'no transitions allowed (terminal state)';
        return {
            isValid: false,
            error: `Invalid transition from '${currentStatus}' to '${newStatus}'. Allowed transitions: ${allowed}`
        };
    }

    return { isValid: true, error: null };
}

async function getTasks(assigneeId) {
    let query = col().orderBy('createdAt', 'desc');
    const snap = await query.get();
    let tasks = snap.docs.map(doc => ({ ...doc.data() }));
    if (assigneeId) tasks = tasks.filter(t => t.assigneeId === assigneeId);
    return tasks;
}

/**
 * Get tasks with cursor-based pagination and optional assignee filter.
 */
async function getTasksPaginated({ limit = 25, cursor = null, assigneeId = null } = {}) {
    limit = Math.max(1, Math.min(limit, 100));

    let query = col();
    if (assigneeId) {
        query = query.where('assigneeId', '==', assigneeId);
    }
    query = query.orderBy('createdAt', 'desc').limit(limit + 1);

    if (cursor) {
        try {
            const cursorDoc = await col().doc(cursor).get();
            if (cursorDoc.exists) {
                let q2 = col();
                if (assigneeId) {
                    q2 = q2.where('assigneeId', '==', assigneeId);
                }
                query = q2.orderBy('createdAt', 'desc').startAfter(cursorDoc).limit(limit + 1);
            }
        } catch (e) { /* ignore */ }
    }

    const snap = await query.get();
    const docs = snap.docs.slice(0, limit);
    const hasMore = snap.docs.length > limit;

    return {
        data: docs.map(doc => ({ ...doc.data() })),
        pagination: {
            cursor: hasMore ? docs[docs.length - 1].id : null,
            hasMore,
            limit
        }
    };
}

async function createTask(taskData) {
    const id = uuidv4();
    const now = new Date().toISOString();
    const task = {
        id, ...taskData,
        tags: taskData.tags || [],
        subtasks: taskData.subtasks || [],
        status: taskData.status || 'pending',
        createdAt: now, updatedAt: now
    };
    await col().doc(id).set(task);
    return { success: true, task };
}

async function updateTask(id, updates) {
    const docRef = col().doc(id);
    const snap = await docRef.get();
    if (!snap.exists) return { success: false, error: 'Task not found' };

    const currentTask = snap.data();

    // If status is being updated, validate the state transition
    if (updates.status && updates.status !== currentTask.status) {
        const validation = validateStateTransition(currentTask.status, updates.status);
        if (!validation.isValid) {
            return { success: false, error: validation.error };
        }
    }

    await docRef.update({ ...updates, updatedAt: new Date().toISOString() });
    return { success: true, task: { ...currentTask, ...updates } };
}

async function deleteTask(id) {
    await col().doc(id).delete();
    return { success: true };
}

async function getTaskStats() {
    const tasks = await getTasks();
    return {
        total: tasks.length,
        pending: tasks.filter(t => t.status === 'pending').length,
        inProgress: tasks.filter(t => t.status === 'in_progress').length,
        completed: tasks.filter(t => t.status === 'completed').length,
        overdue: tasks.filter(t => t.dueDate && new Date(t.dueDate) < new Date() && t.status !== 'completed').length
    };
}

async function toggleSubtask(taskId, subtaskIndex) {
    // #66: Use Firestore transaction to prevent race condition on concurrent subtask toggles
    const db = getDb();
    const docRef = db.collection(COL).doc(taskId);
    return db.runTransaction(async (txn) => {
        const snap = await txn.get(docRef);
        if (!snap.exists) return { success: false, error: 'Task not found' };
        const task = snap.data();
        if (task.subtasks && task.subtasks[subtaskIndex]) {
            task.subtasks[subtaskIndex].completed = !task.subtasks[subtaskIndex].completed;
            txn.update(docRef, { subtasks: task.subtasks, updatedAt: new Date().toISOString() });
        }
        return { success: true, task };
    });
}

async function canStartTask(taskId) {
    const db = getDb();
    const taskDoc = await db.collection(COL).doc(taskId).get();
    if (!taskDoc.exists) throw new Error('Task not found');

    const task = taskDoc.data();
    if (!task.dependsOn || task.dependsOn.length === 0) return { canStart: true, blockedBy: [], message: 'All dependencies met' };

    // Check all dependencies are completed
    const incomplete = [];
    for (const depId of task.dependsOn) {
        const depDoc = await db.collection(COL).doc(depId).get();
        if (!depDoc.exists) continue;
        const dep = depDoc.data();
        if (dep.status !== 'completed') {
            incomplete.push({ id: depId, title: dep.title, status: dep.status });
        }
    }

    return {
        canStart: incomplete.length === 0,
        blockedBy: incomplete,
        message: incomplete.length > 0
            ? `Blocked by ${incomplete.length} incomplete task(s): ${incomplete.map(t => t.title).join(', ')}`
            : 'All dependencies met'
    };
}

async function initializeFromJson() {
    const snap = await col().limit(1).get();
    if (snap.empty) console.log('[Tasks-FB] Empty collection, will populate on first use');
    else console.log('[Tasks-FB] Tasks collection has data');
}

module.exports = {
    getTasks,
    getTasksPaginated,
    createTask,
    updateTask,
    deleteTask,
    getTaskStats,
    toggleSubtask,
    canStartTask,
    initializeFromJson,
    validateStateTransition,
    VALID_TRANSITIONS
};
