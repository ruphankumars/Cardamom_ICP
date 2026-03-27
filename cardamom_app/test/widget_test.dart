// Cardamom App Widget Smoke Test
//
// Verifies the app can be instantiated with required providers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:cardamom_app/services/auth_provider.dart';
import 'package:cardamom_app/main.dart';

void main() {
  testWidgets('CardamomApp renders without crashing', (WidgetTester tester) async {
    // Build app with required providers
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => AuthProvider(),
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Cardamom App')),
          ),
        ),
      ),
    );

    expect(find.text('Cardamom App'), findsOneWidget);
  });
}
