# Running Edge Cases Tests

## Overview

This guide explains how to run and verify the edge cases tests for the negotiation screen.

## Test Files

1. **negotiation_edge_cases_test.dart** - Automated unit/widget tests (requires Flutter test framework setup)
2. **EDGE_CASES_VERIFICATION.md** - Manual testing guide with detailed test cases
3. **Verification Helpers** - Methods added to `negotiation_screen.dart` for programmatic verification

## Running Automated Tests

### Prerequisites

```bash
cd cardamom_app
flutter pub get
```

### Run All Edge Case Tests

```bash
flutter test test/negotiation_edge_cases_test.dart
```

### Run Specific Test Groups

```bash
# Test decline/restore functionality
flutter test test/negotiation_edge_cases_test.dart --name "Item Decline/Restore"

# Test enquiry conversion
flutter test test/negotiation_edge_cases_test.dart --name "Enquiry Price Conversion"

# Test iteration cap
flutter test test/negotiation_edge_cases_test.dart --name "Iteration Cap"

# Test draft auto-open
flutter test test/negotiation_edge_cases_test.dart --name "Draft State Auto-Open"

# Test rapid actions
flutter test test/negotiation_edge_cases_test.dart --name "Multiple Rapid Actions"
```

## Using Verification Helpers

The negotiation screen now includes verification helper methods that can be called programmatically or through debug tools.

### Available Methods

1. **verifyDeclineRestoreFunctionality()** - Verifies decline/restore edge cases
2. **verifyEnquiryConversionFunctionality()** - Verifies enquiry conversion edge cases
3. **verifyIterationCapFunctionality()** - Verifies iteration cap edge cases
4. **verifyDraftAutoOpenFunctionality()** - Verifies draft auto-open edge cases
5. **verifyRapidActionsState()** - Verifies rapid actions state management
6. **verifyAllEdgeCases()** - Comprehensive verification of all edge cases

### Using in Flutter DevTools

1. Open the app in debug mode
2. Navigate to a negotiation screen
3. Open Flutter DevTools
4. In the console, you can call these methods on the negotiation screen instance

### Using in Code

Add a debug button or menu item that calls these methods:

```dart
// Example: Add to debug menu
void _runEdgeCaseVerification() {
  final results = verifyAllEdgeCases();
  debugPrint('Edge Cases Verification Results:');
  debugPrint(jsonEncode(results));
  
  // Show results in a dialog
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Edge Cases Verification'),
      content: SingleChildScrollView(
        child: Text(
          const JsonEncoder.withIndent('  ').convert(results),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
```

## Manual Testing

Follow the detailed test cases in **EDGE_CASES_VERIFICATION.md**:

1. Open the verification guide
2. Go through each test case systematically
3. Check off items in the checklist as you complete them
4. Document any issues found

## Expected Test Results

### Decline/Restore
- ✅ Declined items show grey text with line-through
- ✅ Restore button appears for declined items
- ✅ Declined items are filtered from order conversion
- ✅ State updates correctly after decline/restore

### Enquiry Conversion
- ✅ Checkboxes appear for client in ENQUIRE_PRICE requests
- ✅ Selected items are correctly included in conversion
- ✅ All items included when no selection made
- ✅ Conversion creates new order request correctly

### Iteration Cap
- ✅ Cap detected correctly (>= 4 panels)
- ✅ Warning message appears for client
- ✅ Client cannot counter when cap reached
- ✅ Only confirm/cancel available at cap

### Draft Auto-Open
- ✅ Draft editor auto-opens in ADMIN_DRAFT
- ✅ Draft editor auto-opens in CLIENT_DRAFT
- ✅ Draft state persists across refreshes
- ✅ Auto-open flag resets on status change

### Rapid Actions
- ✅ Rapid decline/restore handled correctly
- ✅ Rapid draft edits don't cause conflicts
- ✅ Duplicate sends prevented
- ✅ State remains consistent during rapid changes

## Troubleshooting

### Tests Not Running

1. Ensure Flutter is properly installed: `flutter doctor`
2. Ensure dependencies are installed: `flutter pub get`
3. Check that test files are in the correct location

### Verification Helpers Not Available

1. Ensure you're using the latest version of `negotiation_screen.dart`
2. Check that the methods are properly added (lines 4147-4250)
3. Ensure the screen is properly initialized before calling methods

### Manual Tests Failing

1. Check browser/app console for errors
2. Verify API endpoints are working
3. Ensure test data is set up correctly
4. Check network tab for failed API calls

## Reporting Issues

When reporting issues found during testing:

1. Note the test case number from EDGE_CASES_VERIFICATION.md
2. Describe the expected vs actual behavior
3. Include screenshots if applicable
4. Note the environment (browser, device, OS)
5. Include console errors or logs
6. Note the verification helper results if used

## Next Steps

After completing all tests:

1. Review all test results
2. Fix any issues found
3. Update the test checklist
4. Document any deviations from expected behavior
5. Update PROGRESS_REPORT.md with test completion status
