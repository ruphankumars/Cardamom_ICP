# Task Management "Assign To" Dropdown Test

## Test Objective
Verify that the "Assign To" dropdown in the Task Management screen correctly displays all available users and is functional.

## Prerequisites
1. Backend server is running (`npm start`)
2. At least one user exists in the system (verified: 6 users available)
3. Flutter app is running (`flutter run -d chrome` from `cardamom_app` directory)
4. User is logged in as admin

## Test Cases

### Test Case 1: Users Load on Screen Init
**Steps:**
1. Navigate to Task Allocator page (`/task_management`)
2. Wait for page to load completely

**Expected Result:**
- Users are fetched automatically when screen loads
- No errors in console related to user fetching
- Debug logs show: `✅ Successfully fetched X users` (where X > 0)

**Verification:**
- Check Flutter debug console for success messages
- Verify `_availableUsers` list is populated

### Test Case 2: Dropdown Shows Users When Modal Opens
**Steps:**
1. Navigate to Task Allocator page
2. Click the "+" button (Create New Task)
3. Observe the "Assign To" dropdown

**Expected Result:**
- Dropdown shows "Select a user" hint (not "No users available")
- Dropdown is enabled (not disabled)
- All 6 users from the system are visible in the dropdown
- Each user shows their username

**Verification:**
- Dropdown should list:
  1. admin
  2. navin-espl-sygt
  3. testclient
  4. shobi
  5. test
  6. navin1234

### Test Case 3: Loading State While Fetching Users
**Steps:**
1. Clear app data/cache (to simulate fresh load)
2. Navigate to Task Allocator page
3. Immediately click "+" button before users finish loading

**Expected Result:**
- Shows "Loading users..." message with spinner
- Dropdown is replaced with loading indicator
- Once loaded, dropdown appears with users

### Test Case 4: Users Refresh If Empty When Modal Opens
**Steps:**
1. Navigate to Task Allocator page
2. Simulate empty users list (or wait for edge case)
3. Click "+" button

**Expected Result:**
- If users list is empty, modal triggers refresh
- Debug log shows: `🔄 Users list is empty, refreshing users before opening modal...`
- Users are fetched and dropdown populates

### Test Case 5: User Selection Works
**Steps:**
1. Navigate to Task Allocator page
2. Click "+" button
3. Click on "Assign To" dropdown
4. Select a user (e.g., "admin")

**Expected Result:**
- Dropdown opens showing all users
- Selected user is highlighted
- Selected user's username appears in dropdown
- `selectedUserId` and `selectedUserName` are set correctly

### Test Case 6: Task Creation with Selected User
**Steps:**
1. Navigate to Task Allocator page
2. Click "+" button
3. Fill in task title
4. Select a user from "Assign To" dropdown
5. Set priority and deadline
6. Click "Create Task"

**Expected Result:**
- Task is created successfully
- Task appears in task list
- Task shows correct assignee name
- No errors related to user assignment

### Test Case 7: Edit Task - User Selection Preserved
**Steps:**
1. Create a task with a specific user assigned
2. Click edit icon on the task
3. Observe "Assign To" dropdown

**Expected Result:**
- Dropdown shows the currently assigned user
- User can change assignment
- Dropdown shows all available users

### Test Case 8: Error Handling
**Steps:**
1. Stop the backend server
2. Navigate to Task Allocator page
3. Click "+" button

**Expected Result:**
- Error is caught gracefully
- Snackbar shows: "Failed to load users: [error message]"
- Dropdown shows "No users available"
- Dropdown is disabled
- App doesn't crash

## Code Verification Checklist

✅ **Users fetched on init:**
- `_fetchUsers()` is called in `initState()` (line 30)

✅ **Loading state tracked:**
- `_isLoadingUsers` flag is used (line 24)
- Loading indicator shown when `_isLoadingUsers` is true (lines 166-184)

✅ **Modal refreshes if empty:**
- Check in `_showTaskModal()` if users list is empty (line 116)
- Calls `_fetchUsers()` if empty (line 118)

✅ **Proper response parsing:**
- Checks if response is Map (line 72)
- Extracts users list (line 73)
- Validates users is List (line 74)
- Handles edge cases (lines 78-85)

✅ **Dropdown implementation:**
- Shows loading state when `_isLoadingUsers` is true (lines 166-184)
- Shows "No users available" when list is empty (line 190)
- Shows "Select a user" when users available (line 190)
- Maps users to dropdown items correctly (lines 193-196)
- Handles user selection (lines 197-203)

✅ **Error handling:**
- Try-catch block in `_fetchUsers()` (line 89)
- Error logging with stack trace (lines 90-91)
- User-friendly error message (lines 97-102)
- Sets empty list on error (line 94)

## Backend API Verification

✅ **API Endpoint:** `/api/users`
✅ **Response Format:** `{ success: true, users: [...] }`
✅ **Users Count:** 6 users available
✅ **User Structure:** Each user has `id` and `username` fields

## Test Results

Run the backend API test:
```bash
node test_users_api.js
```

Expected output:
- ✅ Status Code: 200
- ✅ SUCCESS: API returned 6 users
- ✅ User structure is valid

## Manual Testing Steps

1. **Start Backend:**
   ```bash
   npm start
   ```

2. **Start Flutter App:**
   ```bash
   cd cardamom_app
   flutter run -d chrome
   ```

3. **Login:**
   - Use admin credentials
   - Navigate to Task Allocator

4. **Test Dropdown:**
   - Click "Create New Task"
   - Verify dropdown shows all users
   - Select a user
   - Create task
   - Verify task shows correct assignee

## Debugging Tips

If dropdown shows "No users available":

1. **Check Backend:**
   - Verify server is running: `curl http://localhost:3000/api/users`
   - Should return JSON with `success: true` and `users` array

2. **Check Flutter Console:**
   - Look for debug prints:
     - `🔵 Fetching users from: ...`
     - `✅ Users API Response: ...`
     - `✅ Successfully fetched X users`

3. **Check Network Tab:**
   - Open DevTools → Network
   - Look for `/api/users` request
   - Verify response status is 200
   - Verify response body has correct structure

4. **Check State:**
   - Verify `_availableUsers` is not empty
   - Verify `_isLoadingUsers` is false
   - Check for any error messages

## Success Criteria

✅ Backend API returns users correctly
✅ Users are fetched when screen loads
✅ Dropdown shows all users when modal opens
✅ Loading state is shown while fetching
✅ Users can be selected from dropdown
✅ Selected user is saved correctly
✅ Error handling works gracefully
