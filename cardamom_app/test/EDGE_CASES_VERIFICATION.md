# Edge Cases Verification Guide
## Task 15: Test edge cases (decline/restore, enquiry conversion, iteration cap, draft state)

This document provides a comprehensive guide for verifying all edge cases in the negotiation screen.

---

## 1. Item Decline/Restore Edge Cases

### Test Case 1.1: Decline Item Styling
**Steps:**
1. Open a negotiation with items in draft state
2. Click the decline/remove button (X icon) on an item
3. Confirm the decline action

**Expected Results:**
- ✅ Item text turns grey (`Colors.grey`)
- ✅ Text has line-through decoration (`TextDecoration.lineThrough`)
- ✅ Icon changes from `Icons.close` (red) to `Icons.restore` (orange)
- ✅ Tooltip changes from "Remove" to "Restore"
- ✅ Item background appears greyed out
- ✅ All item fields (grade, type, kgs, price, etc.) show declined styling

**Code Verification Points:**
- `negotiation_screen.dart` lines 1274-1434: Draft editor decline styling
- `negotiation_screen.dart` lines 2449-2598: Panel message decline styling
- `negotiation_screen.dart` lines 4028-4122: Text message decline styling

### Test Case 1.2: Restore Item Functionality
**Steps:**
1. Decline an item (following Test Case 1.1)
2. Click the restore button (restore icon) on the declined item
3. Confirm the restore action

**Expected Results:**
- ✅ Confirmation dialog appears
- ✅ API call to `cancelRequestItem` is made with correct parameters
- ✅ Item status changes from 'DECLINED' to normal
- ✅ Item styling returns to normal (no grey, no line-through)
- ✅ Icon changes back to `Icons.close` (red)
- ✅ Messages are refreshed to show system message
- ✅ Draft state is updated correctly

**Code Verification Points:**
- `negotiation_screen.dart` lines 509-575: `_toggleDecline()` method
- Verify API call includes: `requestId`, `index`, `userRole`, `reason`
- Verify state update: `_currentDraftItems` and `_initialDraftState`

### Test Case 1.3: Declined Items Filtered from Order Conversion
**Steps:**
1. Create a negotiation with multiple items
2. Decline one or more items
3. Attempt to convert to order (confirm or convert enquiry)

**Expected Results:**
- ✅ Declined items are excluded from order conversion
- ✅ Only non-declined items appear in the new order
- ✅ Filter logic: `.where((item) => item['status']?.toString() != 'DECLINED')`

**Code Verification Points:**
- `negotiation_screen.dart` line 1710: Filter in draft editor
- `negotiation_screen.dart` line 3433-3436: Filter in order conversion
- `negotiation_screen.dart` line 2643: Filter in panel actions

---

## 2. Enquiry Price Conversion Edge Cases

### Test Case 2.1: Checkbox Selection for Enquiry Items
**Steps:**
1. Open a negotiation with `requestType == 'ENQUIRE_PRICE'`
2. Login as client (`userRole == 'client'`)
3. View a panel message with items

**Expected Results:**
- ✅ Checkboxes appear in the panel items table
- ✅ Checkboxes are only visible when: `userRole == 'client' && requestType == 'ENQUIRE_PRICE'`
- ✅ Each checkbox corresponds to one item
- ✅ Checkbox state is stored in `_selectedEnquiryIndices` Set

**Code Verification Points:**
- `negotiation_screen.dart` line 2176: `showEnquiryCheckbox` condition
- `negotiation_screen.dart` lines 2397-2471: Checkbox rendering and state management

### Test Case 2.2: Enquiry Conversion with Selected Items
**Steps:**
1. Open an ENQUIRE_PRICE negotiation as client
2. Select specific items using checkboxes (not all items)
3. Click "Convert to Order" button
4. Confirm the conversion

**Expected Results:**
- ✅ Only selected items are included in the conversion
- ✅ `itemsToConvert` contains only items at indices in `_selectedEnquiryIndices`
- ✅ New order request contains only selected items
- ✅ Confirmation message lists only selected items

**Code Verification Points:**
- `negotiation_screen.dart` lines 3308-3319: Selection filtering logic
- `negotiation_screen.dart` lines 3374-3377: Confirmation message with selected items

### Test Case 2.3: Enquiry Conversion with No Selection (All Items)
**Steps:**
1. Open an ENQUIRE_PRICE negotiation as client
2. Do NOT select any checkboxes (leave all unchecked)
3. Click "Convert to Order" button
4. Confirm the conversion

**Expected Results:**
- ✅ All items are included in the conversion (default behavior)
- ✅ When `_selectedEnquiryIndices.isEmpty`, `itemsToConvert = sourceItems`
- ✅ New order request contains all items from the enquiry

**Code Verification Points:**
- `negotiation_screen.dart` lines 3316-3319: Default to all items when no selection

---

## 3. Iteration Cap Edge Cases

### Test Case 3.1: Iteration Cap Detection
**Steps:**
1. Create a negotiation with multiple panel messages
2. Count the number of PANEL type messages
3. Check `_hasReachedIterationCap()` result

**Expected Results:**
- ✅ Returns `true` when `panelCount >= 4`
- ✅ Returns `false` when `panelCount < 4`
- ✅ Counts only messages where `messageType == 'PANEL'`

**Code Verification Points:**
- `negotiation_screen.dart` lines 2134-2137: `_hasReachedIterationCap()` method

### Test Case 3.2: Iteration Cap Warning Display
**Steps:**
1. Create a negotiation with 4 or more panel messages
2. Login as client
3. Open the draft editor (should be in CLIENT_DRAFT status)

**Expected Results:**
- ✅ Warning container appears in draft editor
- ✅ Warning message: "Further bargaining is closed after two rounds. Please confirm or cancel."
- ✅ Warning styled with danger color (`AppTheme.danger`)
- ✅ Warning only appears when: `userRole == 'client' && iterationsLocked == true`

**Code Verification Points:**
- `negotiation_screen.dart` lines 1154-1169: Warning display logic
- `negotiation_screen.dart` lines 1686-1688: Warning in draft editor

### Test Case 3.3: Client Blocked from Countering at Cap
**Steps:**
1. Create a negotiation with 4+ panel messages (iteration cap reached)
2. Login as client
3. Attempt to send a counter-offer

**Expected Results:**
- ✅ Counter button should be disabled or hidden
- ✅ Only "Confirm" and "Cancel" actions available
- ✅ UI prevents further negotiation rounds
- ✅ Warning message is visible

**Code Verification Points:**
- `negotiation_screen.dart` line 2720: `iterationsLocked` check
- `negotiation_screen.dart` line 2759: Counter button disabled when locked

---

## 4. Draft State Auto-Open Edge Cases (Task 14)

### Test Case 4.1: Auto-Open in ADMIN_DRAFT Status
**Steps:**
1. Create a negotiation that enters ADMIN_DRAFT status
2. Login as admin
3. Refresh the page or navigate to the negotiation

**Expected Results:**
- ✅ Draft editor automatically opens
- ✅ `_hasAutoOpenedDraft` flag is set to `true`
- ✅ Auto-scroll to bottom occurs after ~500ms delay
- ✅ Draft editor is visible and ready for editing

**Code Verification Points:**
- `negotiation_screen.dart` lines 977-994: Auto-open logic for ADMIN_DRAFT
- `negotiation_screen.dart` line 194: `_hasAutoOpenedDraft` flag
- `negotiation_screen.dart` line 989: `_scrollToBottom()` call

### Test Case 4.2: Auto-Open in CLIENT_DRAFT Status
**Steps:**
1. Create a negotiation that enters CLIENT_DRAFT status
2. Login as client
3. Refresh the page or navigate to the negotiation

**Expected Results:**
- ✅ Draft editor automatically opens for client
- ✅ Similar auto-open behavior as admin draft
- ✅ Draft editor is visible and ready for editing

**Code Verification Points:**
- `negotiation_screen.dart` lines 970-973: Draft editor conditions
- `negotiation_screen.dart` line 971: `isClientEditTurn` check

### Test Case 4.3: Draft State Persistence
**Steps:**
1. Open a negotiation in draft state
2. Make some edits to items
3. Refresh the page
4. Check if draft state is preserved

**Expected Results:**
- ✅ `_initialDraftState` is set when draft is loaded
- ✅ `_currentDraftItems` maintains state across refreshes
- ✅ Dirty check (`_isDraftDirty()`) works correctly
- ✅ Edits are preserved after refresh

**Code Verification Points:**
- `negotiation_screen.dart` line 167: `_initialDraftState` variable
- `negotiation_screen.dart` lines 688-704: Dirty check logic
- `negotiation_screen.dart` lines 447, 493, 553: State initialization

### Test Case 4.4: Auto-Open Flag Reset on Status Change
**Steps:**
1. Open a negotiation in ADMIN_DRAFT status (auto-opens)
2. Send the panel (status changes to ADMIN_SENT)
3. Wait for client response (status changes to CLIENT_DRAFT)
4. Admin refreshes page

**Expected Results:**
- ✅ When status changes from ADMIN_DRAFT to another status:
  * `_hasAutoOpenedDraft` is reset to `false`
  * `_lastDraftStatus` is updated
- ✅ Next time draft state is entered, auto-open works again

**Code Verification Points:**
- `negotiation_screen.dart` lines 995-999: Flag reset logic
- `negotiation_screen.dart` line 981: Status change detection

---

## 5. Multiple Rapid Actions Edge Cases

### Test Case 5.1: Rapid Decline/Restore Actions
**Steps:**
1. Open a negotiation with multiple items
2. Rapidly click decline/restore on different items (5+ clicks in quick succession)
3. Observe state updates

**Expected Results:**
- ✅ Each API call completes before next one starts (or is queued)
- ✅ State updates are sequential, not concurrent
- ✅ No race conditions in state management
- ✅ UI reflects correct state after each action
- ✅ No duplicate API calls

**Code Verification Points:**
- `negotiation_screen.dart` lines 509-575: `_toggleDecline()` method
- Verify `await` statements prevent concurrent execution
- Check for proper error handling

### Test Case 5.2: Rapid Draft Edits
**Steps:**
1. Open a negotiation in draft state
2. Rapidly edit multiple fields (price, kgs, notes) on different items
3. Observe state updates

**Expected Results:**
- ✅ Each edit is applied correctly
- ✅ `setState()` calls are batched appropriately
- ✅ No data loss or corruption
- ✅ Dirty check works correctly after rapid edits
- ✅ UI updates smoothly without flickering

**Code Verification Points:**
- `negotiation_screen.dart` lines 577-650: `_updateDraftItem()` method
- Verify state updates are atomic
- Check for proper state management

### Test Case 5.3: Rapid Message Sends Prevention
**Steps:**
1. Open a negotiation
2. Click send button multiple times rapidly
3. Observe behavior

**Expected Results:**
- ✅ If send action is in progress, button should be disabled
- ✅ Subsequent taps are ignored
- ✅ Loading state prevents duplicate submissions
- ✅ Only one message is sent
- ✅ No duplicate API calls

**Code Verification Points:**
- Check for loading states in send methods
- Verify button disabled states
- Check for duplicate prevention logic

### Test Case 5.4: State Consistency During Rapid Status Changes
**Steps:**
1. Create a negotiation that changes status rapidly
2. Simulate: ADMIN_DRAFT -> ADMIN_SENT -> CLIENT_DRAFT -> CLIENT_SENT
3. Observe UI updates

**Expected Results:**
- ✅ UI updates correctly for each status
- ✅ Draft editor shows/hides appropriately
- ✅ No stale state or UI glitches
- ✅ Auto-open flag resets correctly
- ✅ All state variables are consistent

**Code Verification Points:**
- `negotiation_screen.dart` lines 302-315: Status change handling
- Verify all state resets on status change
- Check for proper cleanup

---

## 6. Integration Edge Cases

### Test Case 6.1: Decline + Enquiry Conversion Interaction
**Steps:**
1. Open an ENQUIRE_PRICE negotiation as client
2. Decline some items
3. Select remaining items using checkboxes
4. Convert to order

**Expected Results:**
- ✅ Declined items do not appear in conversion
- ✅ Checkbox selection excludes declined items
- ✅ Conversion includes only non-declined, selected items
- ✅ No errors or conflicts

**Code Verification Points:**
- `negotiation_screen.dart` lines 3308-3319: Selection and filtering logic
- Verify both filters work together

### Test Case 6.2: Iteration Cap + Draft State Interaction
**Steps:**
1. Create a negotiation with 4+ panels (cap reached)
2. Status is CLIENT_DRAFT
3. Login as client
4. Observe draft editor

**Expected Results:**
- ✅ Warning message appears
- ✅ Draft editor still auto-opens
- ✅ Client can only confirm or cancel, not counter
- ✅ Both features work together without conflicts

**Code Verification Points:**
- `negotiation_screen.dart` lines 1154-1169: Warning display
- `negotiation_screen.dart` lines 970-999: Auto-open logic
- Verify both conditions work simultaneously

### Test Case 6.3: Draft State + Rapid Actions Interaction
**Steps:**
1. Open a negotiation in ADMIN_DRAFT (auto-opens)
2. Immediately start rapidly editing items
3. Observe behavior

**Expected Results:**
- ✅ Auto-open completes first
- ✅ Edits are applied correctly after auto-open
- ✅ No conflicts between auto-open and manual edits
- ✅ State remains consistent

**Code Verification Points:**
- `negotiation_screen.dart` lines 977-994: Auto-open timing
- `negotiation_screen.dart` lines 577-650: Edit handling
- Verify timing doesn't conflict

---

## Test Execution Checklist

Use this checklist to track test execution:

- [ ] Test Case 1.1: Decline Item Styling
- [ ] Test Case 1.2: Restore Item Functionality
- [ ] Test Case 1.3: Declined Items Filtered from Order Conversion
- [ ] Test Case 2.1: Checkbox Selection for Enquiry Items
- [ ] Test Case 2.2: Enquiry Conversion with Selected Items
- [ ] Test Case 2.3: Enquiry Conversion with No Selection (All Items)
- [ ] Test Case 3.1: Iteration Cap Detection
- [ ] Test Case 3.2: Iteration Cap Warning Display
- [ ] Test Case 3.3: Client Blocked from Countering at Cap
- [ ] Test Case 4.1: Auto-Open in ADMIN_DRAFT Status
- [ ] Test Case 4.2: Auto-Open in CLIENT_DRAFT Status
- [ ] Test Case 4.3: Draft State Persistence
- [ ] Test Case 4.4: Auto-Open Flag Reset on Status Change
- [ ] Test Case 5.1: Rapid Decline/Restore Actions
- [ ] Test Case 5.2: Rapid Draft Edits
- [ ] Test Case 5.3: Rapid Message Sends Prevention
- [ ] Test Case 5.4: State Consistency During Rapid Status Changes
- [ ] Test Case 6.1: Decline + Enquiry Conversion Interaction
- [ ] Test Case 6.2: Iteration Cap + Draft State Interaction
- [ ] Test Case 6.3: Draft State + Rapid Actions Interaction

---

## Notes

- All tests should be performed in both admin and client roles where applicable
- Test with various numbers of items (1, 2, 5, 10+)
- Test with different negotiation statuses
- Verify API calls are made correctly (check network tab)
- Verify state updates are reflected in UI immediately
- Check for console errors during all tests
- Verify styling matches CSS specifications (Task 10)

---

## Issues Found

Document any issues found during testing:

1. **Issue**: [Description]
   - **Location**: [File/Line]
   - **Severity**: [High/Medium/Low]
   - **Status**: [Open/Fixed]

---

## Test Results Summary

**Date**: [Date]
**Tester**: [Name]
**Environment**: [Development/Staging/Production]

**Results**:
- Total Test Cases: 18
- Passed: [X]
- Failed: [X]
- Blocked: [X]

**Overall Status**: [Pass/Fail/Partial]
