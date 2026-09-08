import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'profile_mobile_panel_test.dart' show ProfileMobileFixture, mountProfile;

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets(
      'desktop popover remains anchored and actions scroll at $scale',
      (tester) async {
        final state = ProfileMobileFixture(admin: true, kind: 'agent');
        final results = <String?>[];
        await mountProfile(tester, state, results, width: 900, scale: scale);
        final bounds = tester.getRect(
          find.byKey(const ValueKey('desktop-profile-layout')),
        );
        expect(bounds.left, 50);
        expect(bounds.top, 50);
        expect(bounds.width, 318);
        expect(bounds.bottom, lessThanOrEqualTo(862));
        expect(find.text('我的个人名片'), findsOneWidget);
        expect(find.text('Agent 同事'), findsOneWidget);
        expect(find.text('企业管理'), findsOneWidget);
        await tester.ensureVisible(find.text('设置'));
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        expect(results, ['settings']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  }

  testWidgets('desktop old identity cannot dispatch a retained action', (
    tester,
  ) async {
    final state = ProfileMobileFixture(admin: true);
    final results = <String?>[];
    await mountProfile(tester, state, results, width: 900);
    final action = tester
        .widget<InkWell>(
          find
              .ancestor(of: find.text('企业管理'), matching: find.byType(InkWell))
              .first,
        )
        .onTap!;
    state.generation++;
    state.changed();
    await tester.pump();
    action();
    await tester.pump();
    expect(results, isEmpty);
    expect(find.text('工作身份已切换'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
