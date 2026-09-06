import 'package:active_office/office_state.dart';
import 'package:active_office/ui/app_workbench.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:active_office/ui/workbench_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class WorkbenchFixture extends OfficeState {
  WorkbenchFixture({String kind = 'human'}) {
    endpoint = 'https://workbench-fixture.example';
    me = {'id': 'synthetic-$kind', 'name': '合成同事', 'kind': kind};
    connected = true;
    apps = [
      {
        'id': 'docs',
        'name': '应用文档',
        'route': '/office#docs',
        'available': true,
      },
      {
        'id': 'tasks',
        'name': '应用任务',
        'route': '/office#tasks',
        'available': true,
      },
      {
        'id': 'meetings',
        'name': '应用会议',
        'route': '/office#meetings',
        'available': true,
      },
      for (var i = 0; i < 36; i++)
        {
          'id': 'fixture-$i',
          'name': '应用扩展$i',
          'route': '/office#fixture-$i',
          'available': true,
        },
    ];
  }
  int generation = 0;
  @override
  int get identityGeneration => generation;
  void changed() => notifyListeners();
}

class WorkbenchHarness {
  final key = GlobalKey<OfficeWorkbenchNavigatorState>();
  final pageKeys = <int, GlobalKey>{};
  final navigation = <int, ValueChanged<int>>{};
  final backs = <int, VoidCallback>{};
  final builds = <int>[];
  Widget build(OfficeState state) => MaterialApp(
    theme: officeTheme(),
    home: Scaffold(
      body: OfficeWorkbenchNavigator(
        key: key,
        state: state,
        pageBuilder: (route, back, navigate) {
          builds.add(route);
          navigation[route] = navigate;
          backs[route] = back;
          return Column(
            key: pageKeys.putIfAbsent(route, GlobalKey.new),
            children: [
              Text('真实页面容器 $route'),
              TextField(key: ValueKey('page-input-$route')),
              TextButton(onPressed: back, child: const Text('页面内返回')),
            ],
          );
        },
      ),
    ),
  );
}

Future<void> mountWorkbench(
  WidgetTester tester,
  WorkbenchFixture state,
  WorkbenchHarness harness, {
  Size size = const Size(1512, 982),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    state.dispose();
  });
  await tester.pumpWidget(harness.build(state));
  await tester.pumpAndSettle();
}

Finder searchInput({bool skipOffstage = true}) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == '搜索应用',
  skipOffstage: skipOffstage,
);

Future<void> finishWorkbench(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  test('native route parsing covers existing app routes and keeps unknown/external paths unsupported', () {
    final expected = {
      'messages': 0,
      'agents': 1,
      'contacts': 2,
      'documents': 3,
      'docs': 3,
      'tasks': 4,
      'workbench': 5,
      'meetings': 6,
      'calendar': 7,
      'mail': 8,
      'attendance': 9,
      'approvals': 10,
      'approval': 10,
      'settings': 11,
      'enterprise': 13,
      'minutes': 14,
    };
    for (final entry in expected.entries) {
      expect(officeWorkbenchRoute('/office#${entry.key}'), entry.value);
      expect(officeWorkbenchRoute('/office/${entry.key}'), entry.value);
      expect(officeWorkbenchRoute(entry.key), entry.value);
    }
    expect(officeWorkbenchRoute('/office#unknown'), isNull);
    expect(officeWorkbenchRoute('https://external.example/#docs'), isNull);
    expect(officeWorkbenchRoute('//external.example/docs'), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1512, 982)]) {
    for (final kind in ['human', 'agent']) {
      testWidgets(
        '${size.width.toInt()}px $kind workbench search and scroll survive app back and close',
        (tester) async {
          final state = WorkbenchFixture(kind: kind),
              harness = WorkbenchHarness();
          await mountWorkbench(tester, state, harness, size: size);
          await tester.enterText(searchInput(), '应用');
          await tester.pumpAndSettle();
          final home = find.byType(OfficeAppWorkbench);
          final scroll = tester.state<ScrollableState>(
            find.descendant(of: home, matching: find.byType(Scrollable)).first,
          );
          scroll.position.jumpTo(100);
          await tester.pumpAndSettle();
          final position = scroll.position.pixels;
          final oldHome = tester.state(home);
          await tester.tap(find.text('应用文档'));
          await tester.pumpAndSettle();
          expect(find.text('真实页面容器 3'), findsOneWidget);
          expect(find.byType(OfficeAppWorkbench), findsNothing);
          expect(
            tester.state(find.byType(OfficeAppWorkbench, skipOffstage: false)),
            same(oldHome),
          );
          expect(find.byTooltip('返回工作台'), findsOneWidget);
          expect(find.byTooltip('关闭应用并返回工作台'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('workbench-app-back')));
          await tester.pumpAndSettle();
          expect(scroll.position.pixels, closeTo(position, 1));
          scroll.position.jumpTo(0);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(searchInput()).controller?.text ??
                tester
                    .state<EditableTextState>(
                      find.descendant(
                        of: searchInput(),
                        matching: find.byType(EditableText),
                      ),
                    )
                    .widget
                    .controller
                    .text,
            '应用',
          );
          expect(tester.state(home), same(oldHome));
          scroll.position.jumpTo(position);
          await tester.pumpAndSettle();
          await tester.tap(find.text('应用文档'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('workbench-app-close')));
          await tester.pumpAndSettle();
          expect(tester.state(home), same(oldHome));
          expect(scroll.position.pixels, closeTo(position, 1));
          await finishWorkbench(tester);
        },
      );
    }
  }

  testWidgets(
    'nested application back, duplicate route, close and platform back retain correct unique page state',
    (tester) async {
      final state = WorkbenchFixture(), harness = WorkbenchHarness();
      await mountWorkbench(tester, state, harness);
      harness.key.currentState!.navigate(3);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('page-input-3')),
        '文档草稿',
      );
      final editor = tester.state<EditableTextState>(
        find.byType(EditableText).last,
      );
      harness.navigation[3]!(4);
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回应用文档'), findsOneWidget);
      final hiddenCallback = harness.navigation[3]!;
      hiddenCallback(6);
      await tester.pumpAndSettle();
      expect(find.text('真实页面容器 4'), findsOneWidget);
      harness.navigation[4]!(3);
      await tester.pumpAndSettle();
      expect(find.text('真实页面容器 4'), findsNothing);
      expect(find.text('文档草稿'), findsOneWidget);
      expect(
        tester.state<EditableTextState>(find.byType(EditableText).last),
        same(editor),
      );
      harness.navigation[3]!(3);
      await tester.pumpAndSettle();
      expect(
        find.byKey(harness.pageKeys[3]!, skipOffstage: false),
        findsOneWidget,
      );
      harness.navigation[3]!(4);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('真实页面容器 3'), findsOneWidget);
      harness.navigation[3]!(6);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workbench-app-close')));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeAppWorkbench), findsOneWidget);
      expect(
        find.byKey(harness.pageKeys[3]!, skipOffstage: false),
        findsNothing,
      );
      hiddenCallback(6);
      await tester.pumpAndSettle();
      expect(find.byType(OfficeAppWorkbench), findsOneWidget);
      await finishWorkbench(tester);
    },
  );

  testWidgets(
    'unknown and unavailable pages remain returnable and do not construct protected pages',
    (tester) async {
      final state = WorkbenchFixture(), harness = WorkbenchHarness();
      await mountWorkbench(tester, state, harness);
      harness.key.currentState!.openApp('/office#fixture-0');
      await tester.pumpAndSettle();
      expect(find.text('暂不支持打开此应用'), findsOneWidget);
      expect(harness.builds, isEmpty);
      await tester.tap(find.byKey(const ValueKey('workbench-app-close')));
      await tester.pumpAndSettle();
      for (final route in [6, 4, 13]) {
        state.unavailableModules.add('meetings');
        state.apps[1]['available'] = false;
        harness.key.currentState!.navigate(route);
        await tester.pumpAndSettle();
        expect(find.text('此应用暂不可用'), findsOneWidget);
        expect(harness.builds, isEmpty);
        await tester.tap(find.byKey(const ValueKey('workbench-app-back')));
        await tester.pumpAndSettle();
        expect(find.byType(OfficeAppWorkbench), findsOneWidget);
      }
      await finishWorkbench(tester);
    },
  );

  for (final change in ['principal', 'generation', 'endpoint', 'state']) {
    testWidgets(
      '$change change clears private stack and query and rejects stale callbacks',
      (tester) async {
        final state = WorkbenchFixture(), harness = WorkbenchHarness();
        await mountWorkbench(tester, state, harness);
        await tester.enterText(searchInput(), '应用文档');
        await tester.pumpAndSettle();
        harness.key.currentState!.navigate(3);
        await tester.pumpAndSettle();
        final oldNavigation = harness.navigation[3]!,
            oldBack = harness.backs[3]!;
        if (change == 'state') {
          final next = WorkbenchFixture();
          addTearDown(next.dispose);
          await tester.pumpWidget(harness.build(next));
        } else {
          if (change == 'principal') {
            state.me = {'id': 'synthetic-agent', 'kind': 'agent'};
          }
          if (change == 'generation') state.generation++;
          if (change == 'endpoint') {
            state.endpoint = 'https://other-fixture.example';
          }
          state.changed();
        }
        await tester.pumpAndSettle();
        expect(find.byType(OfficeAppWorkbench), findsOneWidget);
        expect(find.text('真实页面容器 3'), findsNothing);
        final editable = tester.widget<EditableText>(
          find.descendant(
            of: searchInput(),
            matching: find.byType(EditableText),
          ),
        );
        expect(editable.controller.text, isEmpty);
        oldNavigation(6);
        oldBack();
        await tester.pumpAndSettle();
        expect(find.byType(OfficeAppWorkbench), findsOneWidget);
        await finishWorkbench(tester);
      },
    );
  }

  testWidgets(
    'temporary offline and reconnect keep application draft and allow local back',
    (tester) async {
      final state = WorkbenchFixture(), harness = WorkbenchHarness();
      await mountWorkbench(tester, state, harness);
      harness.key.currentState!.navigate(6);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('page-input-6')),
        '会议页面草稿',
      );
      state.connected = false;
      state.changed();
      await tester.pumpAndSettle();
      expect(find.text('会议页面草稿'), findsOneWidget);
      state.connected = true;
      state.changed();
      await tester.pumpAndSettle();
      expect(find.text('会议页面草稿'), findsOneWidget);
      harness.backs[6]!();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeAppWorkbench), findsOneWidget);
      expect(state.meetings, isEmpty);
      await finishWorkbench(tester);
    },
  );
}
