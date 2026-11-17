import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  for (final kind in ['warning', 'error', 'notice']) {
    testWidgets('$kind stays five seconds then slides out to the right', (
      tester,
    ) async {
      var dismissed = 0;
      final feedback = TalFeedbackController(
        onNoticeDismissed: () => dismissed++,
      );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      if (kind == 'warning') {
        feedback.showWarning(
          context: context,
          title: 'warning',
          message: 'message',
        );
      } else if (kind == 'error') {
        await feedback.showError(
          context: context,
          title: 'error',
          message: 'message',
        );
      } else {
        feedback.showActionNotice(
          context: context,
          title: 'notice',
          message: 'message',
          actionLabel: 'action',
          onAction: () async {},
        );
      }
      final popup = find.byKey(ValueKey('tal-$kind-popup'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      final settled = tester.getRect(popup);
      await tester.pump(const Duration(milliseconds: 4679));
      expect(tester.getRect(popup), settled);
      expect(dismissed, 0);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 130));
      expect(tester.getRect(popup).left, greaterThan(settled.left));
      await tester.pump(const Duration(milliseconds: 130));
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      expect(dismissed, 1);
      feedback.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('replacing a notice restarts its own five-second timer', (
    tester,
  ) async {
    final feedback = TalFeedbackController();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    feedback.showWarning(context: context, title: 'first', message: 'message');
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    feedback.showWarning(context: context, title: 'second', message: 'message');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('second'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tal-warning-popup')), findsNothing);
    feedback.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
