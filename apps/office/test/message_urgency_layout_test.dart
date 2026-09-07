import 'package:active_office/ui/message_urgency.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'message_urgency_test.dart' show UrgencyOffice;

Future<void> openUrgencySurface(
  WidgetTester tester,
  UrgencyOffice state, {
  required Size viewport,
  double keyboard = 0,
  double textScale = 1,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showOfficeMessageUrgency(context, state, 'r', state.source),
            child: const Text('打开加急'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开加急'));
  await tester.pumpAndSettle();
  if (keyboard > 0) {
    await tester.tap(find.byKey(const ValueKey('urgency-member-search')));
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    await tester.pumpAndSettle();
  }
}

Finder body() => find.byKey(const ValueKey('urgency-scroll-body'));
Finder actions() => find.byKey(const ValueKey('urgency-fixed-actions'));
Finder phoneStatus() => find.byKey(const ValueKey('urgency-phone-status'));

Future<void> reachLastChannel(WidgetTester tester) async {
  final controller = tester.widget<ListView>(body()).controller!;
  for (var attempt = 0; attempt < 8; attempt++) {
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    if (phoneStatus().evaluate().isNotEmpty &&
        controller.position.extentAfter < 1) {
      break;
    }
  }
  final content = tester.getRect(body());
  final phone = tester.getRect(phoneStatus());
  expect(phone.top, greaterThanOrEqualTo(content.top));
  expect(phone.bottom, lessThanOrEqualTo(content.bottom));
  expect(phone.bottom, lessThan(tester.getRect(actions()).top));
  expect(find.byKey(const ValueKey('urgency-scroll-hint')), findsNothing);
  expect(
    tester
        .widget<RadioListTile<String>>(
          find.byKey(const ValueKey('urgency-channel-phone')),
        )
        .enabled,
    isFalse,
  );
}

void main() {
  for (final viewport in [const Size(1079, 709), const Size(390, 700)]) {
    testWidgets(
      'default $viewport makes remaining channels discoverable and fully reachable',
      (tester) async {
        final state = UrgencyOffice();
        addTearDown(state.dispose);
        await openUrgencySurface(tester, state, viewport: viewport);
        final controller = tester.widget<ListView>(body()).controller!;
        final more = controller.position.extentAfter > 12;
        expect(
          find.byKey(const ValueKey('urgency-scroll-hint')),
          more ? findsOneWidget : findsNothing,
        );
        expect(find.byType(Scrollbar), findsOneWidget);
        if (!more) {
          expect(
            tester.getRect(phoneStatus()).bottom,
            lessThanOrEqualTo(tester.getRect(body()).bottom),
          );
        }
        await reachLastChannel(tester);
        expect(
          tester.getRect(actions()).bottom,
          lessThanOrEqualTo(viewport.height),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('打开加急'), findsOneWidget);
        expect(find.byType(OfficeMessageUrgencyComposer), findsNothing);
      },
    );
  }

  for (final textScale in [1.0, 1.6]) {
    testWidgets(
      'keyboard and 50 members at scale $textScale preserve last channel and fixed actions',
      (tester) async {
        final state = UrgencyOffice();
        addTearDown(state.dispose);
        state.members.addAll(
          List.generate(
            48,
            (i) => <String, dynamic>{
              'principal_id': 'colleague-$i',
              'name': '协作同事 $i',
              'kind': i.isEven ? 'human' : 'agent',
            },
          ),
        );
        const viewport = Size(390, 700);
        const keyboard = 300.0;
        await openUrgencySurface(
          tester,
          state,
          viewport: viewport,
          keyboard: keyboard,
          textScale: textScale,
        );
        expect(
          tester.getRect(actions()).bottom,
          lessThanOrEqualTo(viewport.height - keyboard),
        );
        expect(
          find.byKey(const ValueKey('urgency-scroll-hint')),
          findsOneWidget,
        );
        await reachLastChannel(tester);
        expect(
          tester.getRect(actions()).bottom,
          lessThanOrEqualTo(viewport.height - keyboard),
        );
        expect(tester.getRect(body()).height, greaterThan(0));
        expect(
          state.requests.where((request) => request['method'] != 'GET'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
