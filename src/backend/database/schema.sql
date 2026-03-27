-- ============================================================================
-- Cardamom ICP — SQLite Schema
--
-- One table per Firestore collection. Uses JSON blob storage per row to mirror
-- Firestore's schemaless document model and minimize migration risk.
--
-- Each row stores: id (document ID), data (JSON blob), timestamps.
-- Fields are queried via json_extract(data, '$.fieldName').
-- ============================================================================

-- ============================================================================
-- Core Business Collections
-- ============================================================================

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS cart_orders (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS packed_orders (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS client_requests (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- Subcollection: client_requests/{id}/messages — flattened with parentId
CREATE TABLE IF NOT EXISTS client_request_messages (
    id TEXT PRIMARY KEY,
    parentId TEXT NOT NULL,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS rejected_offers (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS approval_requests (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Stock & Inventory Collections
-- ============================================================================

CREATE TABLE IF NOT EXISTS live_stock_entries (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS stock_adjustments (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS net_stock_cache (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sale_order_summary (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Documents & Dispatch
-- ============================================================================

CREATE TABLE IF NOT EXISTS dispatch_documents (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS transport_documents (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS daily_transport_assignments (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Operations
-- ============================================================================

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS workers (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS attendance (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS expenses (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS expense_items (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS gate_passes (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Configuration & Metadata
-- ============================================================================

CREATE TABLE IF NOT EXISTS settings (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS dropdown_data (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS client_contacts (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS clients (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Financial
-- ============================================================================

CREATE TABLE IF NOT EXISTS offer_prices (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS client_name_mappings (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS packedBoxes (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Communications & Notifications
-- ============================================================================

CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS whatsapp_send_logs (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Counters & Sequences
-- ============================================================================

CREATE TABLE IF NOT EXISTS counters (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS lot_counters (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- History & Audit
-- ============================================================================

CREATE TABLE IF NOT EXISTS order_edit_history (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS unarchive_requests (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL DEFAULT '{}',
    _createdAt TEXT DEFAULT (datetime('now')),
    _updatedAt TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Indexes — for frequently queried JSON fields
-- ============================================================================

-- Users
CREATE INDEX IF NOT EXISTS idx_users_username ON users(json_extract(data, '$.username'));
CREATE INDEX IF NOT EXISTS idx_users_role ON users(json_extract(data, '$.role'));

-- Orders
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_orders_client ON orders(json_extract(data, '$.clientName'));
CREATE INDEX IF NOT EXISTS idx_orders_date ON orders(json_extract(data, '$.date'));

-- Cart & Packed orders
CREATE INDEX IF NOT EXISTS idx_cart_orders_client ON cart_orders(json_extract(data, '$.clientName'));
CREATE INDEX IF NOT EXISTS idx_packed_orders_client ON packed_orders(json_extract(data, '$.clientName'));

-- Tasks
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_tasks_assigned ON tasks(json_extract(data, '$.assignedTo'));

-- Attendance
CREATE INDEX IF NOT EXISTS idx_attendance_worker ON attendance(json_extract(data, '$.workerId'));
CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance(json_extract(data, '$.date'));

-- Expenses
CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(json_extract(data, '$.date'));

-- Gate passes
CREATE INDEX IF NOT EXISTS idx_gate_passes_status ON gate_passes(json_extract(data, '$.status'));

-- Dispatch documents
CREATE INDEX IF NOT EXISTS idx_dispatch_docs_status ON dispatch_documents(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_dispatch_docs_date ON dispatch_documents(json_extract(data, '$.date'));

-- Approval requests
CREATE INDEX IF NOT EXISTS idx_approval_status ON approval_requests(json_extract(data, '$.status'));

-- Notifications
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(json_extract(data, '$.userId'));
CREATE INDEX IF NOT EXISTS idx_notifications_read ON notifications(json_extract(data, '$.read'));

-- Client requests
CREATE INDEX IF NOT EXISTS idx_client_requests_status ON client_requests(json_extract(data, '$.status'));
CREATE INDEX IF NOT EXISTS idx_client_request_messages_parent ON client_request_messages(parentId);
