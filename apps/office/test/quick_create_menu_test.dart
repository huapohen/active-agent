import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:active_office/ui/office_theme.dart';
import 'package:active_office/ui/quick_create_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required FutureOr<void> Function(String) selected,
    bool Function(String)? available,
    Object? scope,
    GlobalKey? capture,
    List<OfficeQuickCreateAction> actions = officeQuickCreateActions,
    Size size = const Size(402, 874),
    double textScale = 1,
    bool reduceMotion = false,
    EdgeInsets safeInsets = EdgeInsets.zero,
    bool nestedSafeArea = false,
    double? anchorLeft,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: capture == null
              ? officeTheme()
              : officeTheme().copyWith(
                  textTheme: officeTheme().textTheme.apply(
                    fontFamily: 'PingFang SC',
                  ),
                ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: reduceMotion,
              padding: safeInsets,
              viewPadding: safeInsets,
            ),
            child: child!,
          ),
          home: Scaffold(
            backgroundColor: Colors.white,
            body: SafeArea(
              top: nestedSafeArea,
              bottom: nestedSafeArea,
              left: nestedSafeArea,
              right: nestedSafeArea,
              child: Stack(
                children: [
                  Positioned(
                    top: 58,
                    left: anchorLeft,
                    right: anchorLeft == null ? 10 : null,
                    child: OfficeQuickCreateMenu(
                      onSelected: selected,
                      isModuleAvailable: available,
                      scopeKey: scope,
                      actions: actions,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'safe area long menu stays below its button and scrolls inside the mobile reference width',
    (tester) async {
      final selected = <String>[];
      await mount(
        tester,
        selected: selected.add,
        safeInsets: const EdgeInsets.only(top: 59, bottom: 34),
        nestedSafeArea: true,
      );
      final button = tester.getRect(find.byType(IconButton));
      await tester.tap(find.byTooltip('新建与添加'));
      await tester.pumpAndSettle();
      final first = tester.getRect(
        find.byKey(const ValueKey('quick-create-scan')),
      );
      expect(first.top, closeTo(button.bottom + 12, .1));
      expect(first.width, 180);
      final menu = find
          .ancestor(
            of: find.byKey(const ValueKey('quick-create-scan')),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.getBottomRight(menu).dy, lessThanOrEqualTo(874 - 34 - 8));
      final last = find.byKey(const ValueKey('quick-create-mail'));
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(menu).dy, closeTo(button.bottom + 8, .1));
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(selected, ['mail']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '402px menu stays below +, aligns right, and gives every existing action a 24px icon',
    (tester) async {
      final selected = <String>[];
      await mount(tester, selected: selected.add);
      final button = tester.getRect(find.byType(IconButton));
      await tester.tap(find.byTooltip('新建与添加'));
      await tester.pumpAndSettle();
      final rows = find.byType(PopupMenuItem<String>);
      expect(rows, findsNWidgets(16));
      final first = tester.getRect(
        find.byKey(const ValueKey('quick-create-scan')),
      );
      expect(first.width, 180);
      expect(first.height, 50);
      expect(first.top, greaterThanOrEqualTo(button.bottom + 8));
      expect(first.top, lessThanOrEqualTo(button.bottom + 13));
      expect(first.right, closeTo(button.right, .1));
      for (final action in officeQuickCreateActions) {
        final row = find.byKey(ValueKey('quick-create-${action.id}'));
        final icons = tester.widgetList<Icon>(
          find.descendant(of: row, matching: find.byType(Icon)),
        );
        expect(icons.single.size, 24);
        final text = tester.widget<Text>(
          find.descendant(of: row, matching: find.text(action.label)),
        );
        expect(text.style?.fontSize, 17);
      }
      await tester.tap(find.byKey(const ValueKey('quick-create-group')));
      await tester.pumpAndSettle();
      expect(selected, ['group']);
      expect(find.byType(PopupMenuItem<String>), findsNothing);
    },
  );

  testWidgets(
    'unimplemented and policy-denied entries explain status without invoking native callbacks',
    (tester) async {
      final selected = <String>[];
      await mount(
        tester,
        selected: selected.add,
        available: (id) => id != 'im',
      );
      await tester.tap(find.byTooltip('新建与添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quick-create-scan')));
      await tester.pumpAndSettle();
      expect(find.text('扫一扫尚未接入，当前不能识别二维码或添加扫码结果。'), findsOneWidget);
      expect(selected, isEmpty);
      await tester.tap(find.byTooltip('新建与添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quick-create-group')));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening at narrow width and 130 percent supports scrolling to the last real action',
    (tester) async {
      final selected = <String>[];
      await mount(
        tester,
        selected: selected.add,
        size: const Size(320, 568),
        textScale: 1.3,
      );
      final button = tester.getRect(find.byType(IconButton));
      await tester.tap(find.byTooltip('新建与添加'));
      await tester.pumpAndSettle();
      final first = tester.getRect(
        find.byKey(const ValueKey('quick-create-scan')),
      );
      expect(first.top, greaterThanOrEqualTo(button.bottom + 8));
      await tester.ensureVisible(
        find.byKey(const ValueKey('quick-create-mail')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quick-create-mail')));
      await tester.pumpAndSettle();
      expect(selected, ['mail']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selection retained across a scope change never dispatches with the new identity',
    (tester) async {
      final selected = <String>[];
      await mount(tester, selected: selected.add, scope: 'old');
      await tester.tap(find.byTooltip('新建与添加'));
      await tester.pumpAndSettle();
      await mount(tester, selected: selected.add, scope: 'new');
      await tester.tap(find.byKey(const ValueKey('quick-create-group')));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
    },
  );

  testWidgets(
    'desktop menu has icons from the first frame and is fully visible and clickable by 120ms',
    (tester) async {
      final selected = <String>[];
      await mount(
        tester,
        selected: selected.add,
        size: const Size(1512, 982),
        anchorLeft: 180,
      );
      final button = tester.getRect(find.byType(IconButton));
      await tester.tap(find.byTooltip('新建与添加'));
      await tester.pump();
      expect(find.byKey(const ValueKey('quick-create-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-create-scan')), findsNothing);
      expect(selected, isEmpty);
      for (final action in officeQuickCreateActions.where(
        (a) => a.id != 'scan',
      )) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('quick-create-${action.id}')),
            matching: find.byIcon(action.icon),
          ),
          findsOneWidget,
        );
      }
      await tester.pump(const Duration(milliseconds: 120));
      final first = tester.getRect(
        find.byKey(const ValueKey('quick-create-group')),
      );
      expect(first.top, closeTo(button.top + 4, .1));
      expect(first.left, closeTo(button.right + 8, .1));
      final last = find.byKey(const ValueKey('quick-create-mail'));
      final fades = tester.widgetList<FadeTransition>(
        find.ancestor(of: last, matching: find.byType(FadeTransition)),
      );
      expect(fades, isNotEmpty);
      for (final fade in fades) {
        expect(fade.opacity.value, closeTo(1, .001));
      }
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      await tester.pump(const Duration(milliseconds: 120));
      expect(selected, ['mail']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduce motion shows the complete menu on its first frame', (
    tester,
  ) async {
    final selected = <String>[];
    await mount(
      tester,
      selected: selected.add,
      size: const Size(1512, 982),
      reduceMotion: true,
    );
    await tester.tap(find.byTooltip('新建与添加'));
    await tester.pump();
    final last = find.byKey(const ValueKey('quick-create-mail'));
    for (final fade in tester.widgetList<FadeTransition>(
      find.ancestor(of: last, matching: find.byType(FadeTransition)),
    )) {
      expect(fade.opacity.value, closeTo(1, .001));
    }
    expect(last.hitTestable(), findsOneWidget);
    await tester.tap(last);
    await tester.pump();
    expect(selected, ['mail']);
  });

  testWidgets(
    'desktop side popup flips left near the screen edge and scrolls without dropping below its trigger',
    (tester) async {
      final selected = <String>[];
      await mount(
        tester,
        selected: selected.add,
        size: const Size(1000, 500),
        anchorLeft: 910,
      );
      final button = tester.getRect(find.byType(IconButton));
      await tester.tap(find.byTooltip('新建与添加'));
      await tester.pumpAndSettle();
      final first = tester.getRect(
        find.byKey(const ValueKey('quick-create-group')),
      );
      expect(first.top, closeTo(button.top + 4, .1));
      expect(first.right, closeTo(button.left - 8, .1));
      expect(first.width, 240);
      final menu = find
          .ancestor(
            of: find.byKey(const ValueKey('quick-create-group')),
            matching: find.byType(Material),
          )
          .first;
      final last = find.byKey(const ValueKey('quick-create-mail'));
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(menu).dy, closeTo(button.top, .1));
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(selected, ['mail']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opening never waits for an earlier asynchronous action', (
    tester,
  ) async {
    final work = Completer<void>();
    final selected = <String>[];
    await mount(
      tester,
      selected: (action) {
        selected.add(action);
        return work.future;
      },
      size: const Size(1512, 982),
    );
    await tester.tap(find.byTooltip('新建与添加'));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    await tester.tap(find.byKey(const ValueKey('quick-create-group')));
    await tester.pumpAndSettle();
    expect(selected, ['group']);
    expect(work.isCompleted, isFalse);
    await tester.tap(find.byTooltip('新建与添加'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      find.byKey(const ValueKey('quick-create-group')).hitTestable(),
      findsOneWidget,
    );
    expect(selected, ['group']);
    work.complete();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reference popup capture uses actual icons and 100 percent type',
    (tester) async {
      final output = Platform.environment['RENJI_QUICK_MENU_CAPTURE'];
      if (output == null) return;
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        await tester.runAsync(() async {
          final fontPath = Platform.environment['RENJI_QUICK_MENU_FONT'];
          if (fontPath != null) {
            final font = FontLoader('PingFang SC')
              ..addFont(
                Future.value(
                  ByteData.sublistView(File(fontPath).readAsBytesSync()),
                ),
              );
            await font.load();
          }
          final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
            ..addFont(
              rootBundle.load(
                'packages/cupertino_icons/assets/CupertinoIcons.ttf',
              ),
            );
          await icons.load();
          final material = FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await material.load();
        });
        final capture = GlobalKey();
        await mount(tester, selected: (_) {}, capture: capture);
        await tester.tap(find.byTooltip('新建与添加'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(output).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      } finally {
        debugDisableShadows = oldShadows;
      }
    },
  );
}
