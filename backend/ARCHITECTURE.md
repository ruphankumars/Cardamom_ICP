# Cardamom Backend Architecture (Post Phase 7 Cleanup)

## Overview

The Cardamom backend uses a **hybrid architecture** combining Firebase Firestore for transactional data and Google Sheets for computational workloads. This document explains why certain modules use each backend.

---

## Architecture Decision: Why Hybrid?

### Firestore Strengths
✅ **Real-time subscriptions** - Instant UI updates
✅ **Scalability** - Handles high transaction volume
✅ **Querying** - Complex filters and indexes
✅ **Cost** - Pay per operation, not per file

### Google Sheets Strengths
✅ **Matrix computations** - Grade segregation formulas
✅ **Historical analysis** - Time-series calculations
✅ **Visual debugging** - See data in spreadsheet
✅ **Zero migration cost** - Existing business logic preserved

---

## Module Architecture Map

### 🔥 Firestore Modules (Fully Migrated)

These modules now use Firestore exclusively:

| Module | Collection | Purpose |
|--------|------------|---------|
| **Users** | `users` | User authentication and profiles |
| **Orders** | `orders`, `cart_orders`, `packed_orders` | Order lifecycle management |
| **Approval Requests** | `approval_requests` | Edit/delete approval workflow |
| **Client Requests** | `client_requests` | Customer quotation requests |
| **Tasks** | `tasks` | Internal task management |
| **Workers & Attendance** | `attendance_records` | Employee check-in/check-out |
| **Expenses** | `expenses` | Daily expense tracking |
| **Gate Passes** | `gatepasses` | Entry/exit authorization |

**Implementation**: `backend/firebase/*_fb.js`

---

### 📊 Google Sheets Modules (Strategic Keep)

These modules remain on Sheets due to computational complexity or dependencies:

| Module | Sheet(s) | Reason to Keep |
|--------|----------|----------------|
| **Stock Calculator** | `live_stock`, `computed_stock`, `virtual_stock`, `net_stock` | Core inventory computation engine. Grade segregation matrix calculations. **100+ hours to migrate**. |
| **Analytics** | Reads: `net_stock`, `cart`, `packed` | Stock forecasting, client scoring. Depends on Sheets stock results. |
| **Dashboard** | Reads: `net_stock`, `cart`, `packed` | Real-time summary snapshot. Depends on Sheets stock data. |
| **AI Brain** | Reads: All analytics sheets | Daily intelligence briefing. Aggregates Sheets-based analytics. |
| **Predictive Analytics** | Reads: `packed`, `cart` | Demand trend analysis. Requires historical Sheets data. |
| **Pricing Intelligence** | Depends on analytics modules | Market pricing recommendations. Downstream of analytics pipeline. |
| **Audit Log** | `audit_trail` | Historical append-only logging. Works well on Sheets. |
| **Integrity Check** | Validates order consistency across sheets | Ensures data integrity between systems. |
| **Admin Tools** | Recalc menu for stock delta pointer | Stock engine management utilities. |
| **Dropdowns** | `DropdownData` | Static reference data for UI dropdowns. Low volume, read-only. |

**Implementation**: `backend/*.js`

---

### 🔄 Hybrid Modules (Firestore + Sheets Bridge)

These modules read from Firestore and sync to Sheets for computation:

| Module | Firestore Collection | Sheets Target | Purpose |
|--------|---------------------|---------------|---------|
| **Stock Calc (Firestore)** | `stock_adjustments` | `stock_adjustments` sheet | Stores manual adjustments in Firestore, syncs to Sheets before computation runs. |
| **Merge Glue (Firestore)** | `orders`, `cart_orders`, `packed_orders` | `sale_order` sheet | Reads order quantities from Firestore, aggregates by grade, writes daily sales plan to Sheets for stock calc. |

**Implementation**: `backend/firebase/stockCalc_fb.js`, `backend/firebase/mergeGlue_fb.js`

**Why Hybrid Works**:
- Firestore provides transactional integrity for orders and adjustments
- Sheets provides computational power for inventory matrix calculations
- Bridge modules sync data between systems

---

## Data Flow Architecture

```
┌─────────────────┐
│  Flutter App    │
│  (User Input)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Firestore     │  ← Orders, Tasks, Users, Expenses, etc.
│  (CRUD Layer)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Merge Glue_FB  │  ← Reads Firestore orders
│  (Aggregator)   │     Aggregates quantities by grade
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Google Sheets  │  ← sale_order, stock_adjustments
│  (Compute)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Stock Calc    │  ← Matrix computations
│  (Engine)       │     Grade segregation
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Sheets Results │  ← net_stock, virtual_stock, etc.
│  (Output)       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Analytics     │  ← Forecasts, insights, AI briefing
│  (Consumers)    │
└─────────────────┘
```

---

## Feature Flags (Phase 7 Simplified)

After Phase 7 cleanup, feature flags are minimal:

```bash
# Hybrid Stock Module
FB_STOCK=true  # Use Firestore for stock adjustments (hybrid mode)

# Future Migrations (not implemented)
FB_ANALYTICS=false  # Reserved for future analytics migration

# Emergency Rollback
FB_ALL=false  # Reverts all to Sheets (use only if Firestore fails)
```

**Deprecated Flags** (no longer needed):
- `FB_USERS`, `FB_APPROVALS`, `FB_CLIENT_REQUESTS`, `FB_ORDERS`
- `FB_TASKS`, `FB_ATTENDANCE`, `FB_EXPENSES`, `FB_GATEPASSES`

These modules are now **Firestore-only** by default in `server.js`.

---

## Migration History

### Phase 4 (Completed)
✅ Users → Firestore
✅ Approval Requests → Firestore
✅ Orders → Firestore
✅ Client Requests → Firestore

### Phase 5 (Hybrid)
🔄 Stock Adjustments → Firestore storage + Sheets computation
🔄 Order Aggregation → Firestore read + Sheets write

### Phase 6 (Completed)
✅ Tasks → Firestore
✅ Workers & Attendance → Firestore
✅ Expenses → Firestore
✅ Gate Passes → Firestore

### Phase 7 (Cleanup)
🧹 Removed deprecated Sheets modules (`backend/deprecated/`)
🧹 Simplified feature flags (only `FB_STOCK` remains active)
🧹 Updated `server.js` to use Firestore imports directly
📚 Created this architecture documentation

---

## Deprecated Modules (Backup)

Legacy Sheets modules have been moved to `backend/deprecated/` for rollback safety:

- `users.js` → replaced by `firebase/users_fb.js`
- `approval_requests.js` → replaced by `firebase/approval_requests_fb.js`
- `clientRequests.js` → replaced by `firebase/client_requests_fb.js`
- `orderBook.js` → replaced by `firebase/orderBook_fb.js`
- `taskManager.js` → replaced by `firebase/taskManager_fb.js`
- `workersAttendance.js` → replaced by `firebase/workersAttendance_fb.js`
- `expenses.js` → replaced by `firebase/expenses_fb.js`
- `gatepasses.js` → replaced by `firebase/gatepasses_fb.js`

**Rollback Plan**: If Firestore fails, restore files from `deprecated/` and set `FB_ALL=false`.

---

## Out of Scope (Future Phases)

These migrations require significant effort and are **NOT** planned:

❌ **Stock Calculation Engine → Firestore** (100+ hours)
   - Complex matrix mathematics
   - Grade segregation algorithms
   - Delta pointer tracking
   - **Recommendation**: Keep on Sheets indefinitely

❌ **Analytics Pipeline → Firestore** (50+ hours)
   - Time-series computations
   - Historical data dependencies
   - **Recommendation**: Migrate if Sheets becomes a performance bottleneck

❌ **Audit Logging → Firestore** (10+ hours)
   - Append-only logging works well on Sheets
   - **Recommendation**: Migrate only if query performance needed

❌ **Dropdowns → Firestore** (5+ hours)
   - Low-volume static data
   - **Recommendation**: Keep on Sheets for simplicity

---

## Performance Considerations

### Firestore Optimizations
- ✅ Indexes configured for common queries
- ✅ Batch writes for bulk operations
- ✅ Real-time listeners only where needed

### Sheets Optimizations
- ✅ 10-second cache for stock calculations
- ✅ Batch updates for client requests
- ✅ Minimal API calls (quota-conscious)

---

## Monitoring & Observability

### Firestore Metrics
- Collection sizes (Firestore Console)
- Read/write operations (Usage tab)
- Query performance (Firestore dashboard)

### Sheets Metrics
- API quota usage (Google Cloud Console)
- Cache hit rates (server logs: `[CACHE]` prefix)
- Calculation times (server logs: `[StockCalc]` prefix)

---

## Conclusion

The hybrid architecture is **stable, performant, and cost-effective**. Firestore handles transactional workloads excellently, while Sheets powers the computational engine. This separation of concerns allows each system to operate in its strength zone.

**No further migration is recommended** unless specific performance issues arise.

---

**Last Updated**: Phase 7 Cleanup (February 2026)
**Maintainer**: Cardamom Development Team
