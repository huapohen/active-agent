import 'package:active_office/main.dart';
import 'package:active_office/ui/app_workbench.dart';
import 'package:active_office/ui/calendar.dart';
import 'package:active_office/ui/conversation.dart';
import 'package:active_office/ui/mobile_more_menu.dart';
import 'package:active_office/ui/people.dart';
import 'package:active_office/ui/workbench_navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'profile_navigation_test.dart' show ProfileNavigationOffice;

class InteractionOffice extends ProfileNavigationOffice {
  InteractionOffice({super.kind}) {
    settings = {
      ...settings,
      'desktop_nav': ['messages', 'docs', 'workbench'],
    };
    apps.add({
      'id': 'messages',
      'name': '会话应用',
      'route': '/office#messages',
      'available': true,
    });
  }
  final visibility = <(String, bool)>[];
  int generation = 0;
  @override
  int get identityGeneration => generation;
  @override
  Future<void> setConversationVisible(String roomId, bool visible) async {
    visibility.add((roomId, visible));
  }

  void changeIdentity() {
    generation++;
    notifyListeners();
  }
}

Future<void> mountShell(
  WidgetTester tester,
  InteractionOffice state, {
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(ActiveOfficeApp(state: state));
  await tester.pumpAndSettle();
}

Finder hint(String value, {bool skipOffstage = true}) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == value,
  skipOffstage: skipOffstage,
);
Finder more() => find.widgetWithText(NavigationDestination, '更多');
Finder desktopItem(String id) => find.byWidgetPredicate(
  (widget) => widget is InkWell && widget.key == ValueKey('desktop-nav-$id'),
);
EditableTextState inputState(WidgetTester tester, Finder field) =>
    tester.state<EditableTextState>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> openWorkbench(WidgetTester tester, {required bool desktop}) =>
    tapAndSettle(
      tester,
      desktop
          ? desktopItem('workbench')
          : find.widgetWithText(NavigationDestination, '工作台'),
    );
Future<void> tapWorkbenchApp(WidgetTester tester, String label) async {
  final tile = find
      .descendant(
        of: find.byType(OfficeAppWorkbench),
        matching: find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == label,
        ),
      )
      .first;
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tapAndSettle(tester, tile);
  expect(find.byKey(const ValueKey('workbench-app-toolbar')), findsOneWidget);
}

Future<void> finish(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind toggles mobile More without replacing the room search controller',
      (tester) async {
        final state = InteractionOffice(kind: kind);
        await mountShell(tester, state);
        await tester.enterText(hint('搜索会话'), '保留的查找');
        await tester.pumpAndSettle();
        final before = inputState(tester, hint('搜索会话'));
        final controller = before.widget.controller;
        expect(find.byType(OfficeConversation), findsNothing);
        await tapAndSettle(tester, more());
        expect(find.byType(OfficeMobileMoreMenu), findsOneWidget);
        expect(inputState(tester, hint('搜索会话')), same(before));
        expect(
          inputState(tester, hint('搜索会话')).widget.controller,
          same(controller),
        );
        await tapAndSettle(tester, more());
        expect(find.byType(OfficeMobileMoreMenu), findsNothing);
        expect(inputState(tester, hint('搜索会话')), same(before));
        expect(controller.text, '保留的查找');
        expect(state.writes, isEmpty);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'mobile More dismisses by barrier, close, Escape and system back while retaining its page',
    (tester) async {
      final state = InteractionOffice();
      await mountShell(tester, state);
      await tester.enterText(hint('搜索会话'), '协作');
      await tester.pumpAndSettle();
      final before = inputState(tester, hint('搜索会话'));
      for (final action in ['barrier', 'close', 'escape', 'back']) {
        await tapAndSettle(tester, more());
        expect(
          find.byType(OfficeMobileMoreMenu),
          findsOneWidget,
          reason: action,
        );
        switch (action) {
          case 'barrier':
            final rect = tester.getRect(find.byType(OfficeMobileMoreMenu));
            await tester.tapAt(rect.topLeft + const Offset(12, 12));
          case 'close':
            await tester.tap(find.byTooltip('关闭更多菜单'));
          case 'escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          case 'back':
            await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(find.byType(OfficeMobileMoreMenu), findsNothing, reason: action);
        expect(inputState(tester, hint('搜索会话')), same(before), reason: action);
        expect(before.widget.controller.text, '协作', reason: action);
      }
      await finish(tester);
    },
  );

  testWidgets(
    'another mobile bottom destination closes More and opens the selected real module',
    (tester) async {
      final state = InteractionOffice();
      await mountShell(tester, state);
      await tapAndSettle(tester, more());
      await tapAndSettle(
        tester,
        find.widgetWithText(NavigationDestination, 'Agent'),
      );
      expect(find.byType(OfficeMobileMoreMenu), findsNothing);
      expect(find.byType(OfficePeople), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      expect(state.writes, isEmpty);
      await finish(tester);
    },
  );

  testWidgets(
    'same-ID identity turnover closes More and reopening captures a fresh identity',
    (tester) async {
      final state = InteractionOffice();
      await mountShell(tester, state);
      await tapAndSettle(tester, more());
      final oldKey = tester
          .widget<OfficeMobileMoreMenu>(find.byType(OfficeMobileMoreMenu))
          .key;
      state.changeIdentity();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMobileMoreMenu), findsNothing);
      await tapAndSettle(tester, more());
      expect(
        tester
            .widget<OfficeMobileMoreMenu>(find.byType(OfficeMobileMoreMenu))
            .key,
        isNot(oldKey),
      );
      await tapAndSettle(tester, more());
      await finish(tester);
    },
  );

  testWidgets(
    'short mobile More scrolls to its final entry while its close button stays reachable',
    (tester) async {
      final state = InteractionOffice();
      await mountShell(tester, state, size: const Size(390, 400));
      await tapAndSettle(tester, more());
      final menu = find.byType(OfficeMobileMoreMenu);
      final scrollable = find
          .descendant(of: menu, matching: find.byType(Scrollable))
          .first;
      final scroll = tester.state<ScrollableState>(scrollable);
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      final settings = find.descendant(
        of: menu,
        matching: find.widgetWithText(ListTile, '设置'),
      );
      await tester.scrollUntilVisible(settings, 160, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(0));
      expect(settings.hitTestable(), findsOneWidget);
      expect(find.byTooltip('关闭更多菜单').hitTestable(), findsOneWidget);
      await tapAndSettle(tester, find.byTooltip('关闭更多菜单'));
      expect(find.byType(OfficeMobileMoreMenu), findsNothing);
      await finish(tester);
    },
  );

  for (final gesture in ['secondary', 'longPress']) {
    testWidgets(
      'desktop $gesture opens the actual sidebar menu without primary navigation',
      (tester) async {
        final state = InteractionOffice();
        await mountShell(tester, state, size: const Size(1512, 982));
        final conversation = tester.state(find.byType(OfficeConversation));
        final item = desktopItem('docs');
        if (gesture == 'secondary') {
          await tester.tap(item, buttons: kSecondaryMouseButton);
        } else {
          await tester.longPress(item);
        }
        await tester.pumpAndSettle();
        expect(find.widgetWithText(MenuItemButton, '打开'), findsOneWidget);
        expect(find.widgetWithText(MenuItemButton, '从导航栏移除'), findsOneWidget);
        expect(
          tester.state(find.byType(OfficeConversation)),
          same(conversation),
        );
        expect(state.writes, isEmpty);
        await tapAndSettle(
          tester,
          find.widgetWithText(MenuItemButton, '从导航栏移除'),
        );
        expect(state.writes.single, {
          'desktop_nav': ['messages', 'workbench'],
          'base_revision': 7,
        });
        expect(state.settings['mobile_nav'], [
          'messages',
          'agents',
          'docs',
          'workbench',
        ]);
        expect(desktopItem('docs'), findsNothing);
        expect(
          tester.state(find.byType(OfficeConversation)),
          same(conversation),
        );
        await tapAndSettle(
          tester,
          find.byKey(const ValueKey('desktop-navigation-editor')),
        );
        expect(find.text('编辑导航栏'), findsOneWidget);
        expect(find.widgetWithText(ActionChip, '云文档'), findsOneWidget);
        await tapAndSettle(tester, find.byTooltip('取消导航栏编辑'));
        await finish(tester);
      },
    );
  }

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? 'desktop' : 'mobile'} real workbench calendar returns and closes to the same search controller',
      (tester) async {
        final state = InteractionOffice();
        await mountShell(
          tester,
          state,
          size: desktop ? const Size(1512, 982) : const Size(390, 844),
        );
        await openWorkbench(tester, desktop: desktop);
        await tester.enterText(hint('搜索应用'), '日历');
        await tester.pumpAndSettle();
        final home = tester.state(find.byType(OfficeAppWorkbench));
        final search = inputState(tester, hint('搜索应用'));
        final controller = search.widget.controller;
        for (final control in ['workbench-app-back', 'workbench-app-close']) {
          await tapWorkbenchApp(tester, '日历');
          expect(find.byType(OfficeCalendar), findsOneWidget);
          expect(find.byTooltip('返回工作台'), findsOneWidget);
          expect(find.byTooltip('关闭应用并返回工作台'), findsOneWidget);
          expect(
            tester.state(find.byType(OfficeAppWorkbench, skipOffstage: false)),
            same(home),
          );
          if (!desktop) {
            expect(
              tester
                  .widget<NavigationBar>(find.byType(NavigationBar))
                  .selectedIndex,
              3,
            );
          }
          await tapAndSettle(tester, find.byKey(ValueKey(control)));
          expect(find.byType(OfficeCalendar), findsNothing);
          expect(tester.state(find.byType(OfficeAppWorkbench)), same(home));
          expect(inputState(tester, hint('搜索应用')), same(search));
          expect(search.widget.controller, same(controller));
          expect(controller.text, '日历');
        }
        expect(state.writes, isEmpty);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'system back dismisses mobile More without popping the retained workbench application',
    (tester) async {
      final state = InteractionOffice();
      await mountShell(tester, state);
      await openWorkbench(tester, desktop: false);
      await tapWorkbenchApp(tester, '日历');
      final calendar = tester.state(find.byType(OfficeCalendar));
      await tapAndSettle(tester, more());
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMobileMoreMenu), findsNothing);
      expect(tester.state(find.byType(OfficeCalendar)), same(calendar));
      expect(
        find.byKey(const ValueKey('workbench-app-toolbar')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeCalendar), findsNothing);
      expect(find.byType(OfficeAppWorkbench), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'retained workbench conversation pauses visibility while hidden and under mobile More',
    (tester) async {
      final state = InteractionOffice();
      await mountShell(tester, state);
      await openWorkbench(tester, desktop: false);
      await tester.enterText(hint('搜索应用'), '会话应用');
      await tester.pumpAndSettle();
      await tapWorkbenchApp(tester, '会话应用');
      final conversation = tester.state(find.byType(OfficeConversation));
      expect(state.visibility.last, ('room-demo', true));
      state.visibility.clear();
      final navigator = tester.state<OfficeWorkbenchNavigatorState>(
        find.byType(OfficeWorkbenchNavigator),
      );
      // Put the shell's actual calendar over its retained actual conversation.
      navigator.navigate(7);
      await tester.pumpAndSettle();
      expect(find.byType(OfficeCalendar), findsOneWidget);
      expect(find.byType(OfficeConversation), findsNothing);
      expect(
        tester.state(find.byType(OfficeConversation, skipOffstage: false)),
        same(conversation),
      );
      expect(state.visibility, [('room-demo', false)]);
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(state.visibility, [('room-demo', false)]);
      await tapAndSettle(
        tester,
        find.byKey(const ValueKey('workbench-app-back')),
      );
      expect(state.visibility.last, ('room-demo', true));
      state.visibility.clear();
      await tapAndSettle(tester, more());
      expect(state.visibility, [('room-demo', false)]);
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(state.visibility, [('room-demo', false)]);
      await tapAndSettle(tester, more());
      expect(tester.state(find.byType(OfficeConversation)), same(conversation));
      expect(state.visibility, [('room-demo', false), ('room-demo', true)]);
      await finish(tester);
    },
  );
}
