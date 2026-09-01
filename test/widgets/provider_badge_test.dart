import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cod/widgets/provider_badge.dart';

void main() {
  group('ProviderBadge', () {
    testWidgets('renders provider and short model', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ProviderBadge(providerId: 'claude', modelId: 'claude-sonnet-4-6'),
          ),
        ),
      );
      expect(find.text('claude · sonnet'), findsOneWidget);
    });

    testWidgets('compact mode shows only the model', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ProviderBadge(
              providerId: 'gemini',
              modelId: 'gemini-2.0-flash',
              compact: true,
            ),
          ),
        ),
      );
      expect(find.text('flash'), findsOneWidget);
    });

    testWidgets('unknown provider falls back to grey', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ProviderBadge(providerId: 'unknown', modelId: 'some-model'),
          ),
        ),
      );
      expect(find.text('unknown · some'), findsOneWidget);
    });
  });
}
