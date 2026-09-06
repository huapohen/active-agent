import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/desktop_navigation.dart';
import 'package:active_office/ui/mobile_navigation.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class DesktopNavigationFixture extends OfficeState {
  DesktopNavigationFixture({String kind = 'human', List<String>? navigation}) {
    endpoint = 'https://office.invalid';
    connected = true;
    me = {'id': 'fixture-$kind', 'kind': kind, 'name': '测试身份'};
    settings = {
      'revision': 7,
      'desktop_nav': navigation ?? ['messages', 'docs', 'workbench'],
      'mobile_nav': ['messages', 'agents'],
    };
    server = {...settings};
  }

  late Json server;
  int generation = 0, reads = 0;
  final writes = <Json>[];
  OfficeException? failure;
  Completer<void>? pendingSave;
  Completer<Json>? pendingRead;
  @override
  int get identityGeneration => generation;
  void emit() => notifyListeners();
  void switchIdentity() {
    generation++;
    emit();
  }

  @override
  Future<void> saveSettings(Json changes, {int? baseRevision}) async {
    writes.add({...changes, 'base_revision': baseRevision});
    final generationAtStart = generation;
    await pendingSave?.future;
    if (generationAtStart != generation) throw OfficeException(401, '身份已变化');
    final nextFailure = failure;
    failure = null;
    if (nextFailure != null) throw nextFailure;
    if (baseRevision != server['revision']) {
      throw OfficeException(409, '设置版本已变化');
    }
    server = {
      ...server,
      ...changes,
      'revision': (server['revision'] as int) + 1,
    };
    settings = {...server};
    emit();
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    expect(path, '/settings');
    reads++;
    return pendingRead?.future ??
        {
          'settings': {...server},
        };
  }
}

Future<void> mountNavigation(
  WidgetTester tester,
  DesktopNavigationFixture state, {
  String itemId = 'docs',
  VoidCallback? onOpen,
}) async {
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  final item = itemId == 'settings'
      ? const OfficeNavigationItem('settings', '设置', Icons.settings, 11)
      : officeNavigationItems.firstWhere((item) => item.id == itemId);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () =>
                    showOfficeDesktopNavigationEditor(context, state),
                child: const Text('打开编辑器'),
              ),
              TextButton(
                onPressed: () => showOfficeDesktopNavigationMenu(
                  context,
                  state,
                  item,
                  position: const Offset(120, 90),
                  onOpen: onOpen ?? () {},
                ),
                child: const Text('打开菜单'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

Future<void> scrollTap(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

MenuItemButton menuButton(WidgetTester tester, String label) =>
    tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, label));

List<String> draftOrder(WidgetTester tester) => tester
    .widgetList<Material>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Material &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('desktop-nav-'),
      ),
    )
    .map(
      (widget) => (widget.key! as ValueKey<String>).value.substring(
        'desktop-nav-'.length,
      ),
    )
    .toList();

void main() {
  test('desktop navigation has twelve defaults and rejects duplicates, invalid and enterprise IDs', () {
    final state = DesktopNavigationFixture();
    addTearDown(state.dispose);
    state.settings = {};
    expect(
      officeDesktopNavigation(state).map((item) => item.id),
      defaultOfficeDesktopNavigation,
    );
    state.settings['desktop_nav'] = [
      'docs',
      'docs',
      'enterprise',
      42,
      'unknown',
      'messages',
    ];
    state.enterpriseSummary = {
      'capabilities': {'access_admin': true},
    };
    expect(officeDesktopNavigation(state).map((item) => item.id), [
      'docs',
      'messages',
    ]);
    expect(officeDesktopNavigation(state, []).length, 12);
  });

  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind edits desktop navigation using the same revision and leaves mobile preferences alone',
      (tester) async {
        final state = DesktopNavigationFixture(kind: kind);
        await mountNavigation(tester, state);
        await tapText(tester, '打开编辑器');
        await tester.tap(find.byTooltip('上移云文档'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('移除工作台'));
        await tester.pumpAndSettle();
        await scrollTap(tester, find.widgetWithText(ActionChip, '任务'));
        await tapText(tester, '保存');
        expect(state.writes.single, {
          'desktop_nav': ['docs', 'messages', 'tasks'],
          'base_revision': 7,
        });
        expect(state.settings['mobile_nav'], ['messages', 'agents']);
        expect(find.text('编辑导航栏'), findsNothing);
      },
    );
  }

  testWidgets(
    'menu open callback does not write settings and fixed settings cannot move or disappear',
    (tester) async {
      final state = DesktopNavigationFixture();
      var opened = 0;
      await mountNavigation(
        tester,
        state,
        itemId: 'settings',
        onOpen: () => opened++,
      );
      await tapText(tester, '打开菜单');
      for (final label in ['上移', '下移', '从导航栏移除']) {
        expect(menuButton(tester, label).onPressed, isNull);
      }
      expect(menuButton(tester, '编辑导航栏').onPressed, isNotNull);
      await tapText(tester, '打开');
      expect(opened, 1);
      expect(state.writes, isEmpty);
    },
  );

  testWidgets(
    'failed menu action retries its opening intent rather than moving a second time',
    (tester) async {
      final state = DesktopNavigationFixture()
        ..failure = OfficeException(503, '连接暂时失败');
      await mountNavigation(tester, state);
      await tapText(tester, '打开菜单');
      await tapText(tester, '上移');
      expect(find.text('连接暂时失败'), findsOneWidget);
      expect(state.settings['desktop_nav'], ['messages', 'docs', 'workbench']);
      await tapText(tester, '上移');
      expect(state.writes, [
        {
          'desktop_nav': ['docs', 'messages', 'workbench'],
          'base_revision': 7,
        },
        {
          'desktop_nav': ['docs', 'messages', 'workbench'],
          'base_revision': 7,
        },
      ]);
      expect(find.text('从导航栏移除'), findsNothing);
    },
  );

  testWidgets(
    'menu keeps opening revision on external change and transfers failed intent to conflict editor',
    (tester) async {
      final state = DesktopNavigationFixture();
      await mountNavigation(tester, state);
      await tapText(tester, '打开菜单');
      state.server = {
        ...state.server,
        'revision': 8,
        'desktop_nav': ['mail', 'messages'],
      };
      state.settings = {...state.server};
      state.emit();
      await tester.pumpAndSettle();
      await tapText(tester, '从导航栏移除');
      expect(state.writes.single, {
        'desktop_nav': ['messages', 'workbench'],
        'base_revision': 7,
      });
      expect(menuButton(tester, '上移').onPressed, isNull);
      await tapText(tester, '编辑导航栏');
      expect(draftOrder(tester), ['messages', 'workbench']);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
            .onPressed,
        isNull,
      );
      await scrollTap(tester, find.text('读取最新设置'));
      expect(state.reads, 1);
      expect(find.text('服务器导航栏：邮箱 / 消息'), findsOneWidget);
      await scrollTap(tester, find.text('保留我的导航继续编辑'));
      expect(state.writes.length, 1);
      await tapText(tester, '保存');
      expect(state.writes.last, {
        'desktop_nav': ['messages', 'workbench'],
        'base_revision': 8,
      });
    },
  );

  testWidgets(
    'editor adopts remote draft explicitly and only writes after save',
    (tester) async {
      final state = DesktopNavigationFixture();
      await mountNavigation(tester, state);
      await tapText(tester, '打开编辑器');
      await tester.tap(find.byTooltip('上移云文档'));
      state.server = {
        ...state.server,
        'revision': 9,
        'desktop_nav': ['mail'],
      };
      await tester.pumpAndSettle();
      await tapText(tester, '保存');
      await scrollTap(tester, find.text('读取最新设置'));
      await scrollTap(tester, find.text('采用服务器导航继续编辑'));
      expect(state.writes.length, 1);
      await tapText(tester, '保存');
      expect(state.writes.last, {
        'desktop_nav': ['mail'],
        'base_revision': 9,
      });
    },
  );

  testWidgets(
    'offline editor keeps a reorder draft and disables writes until reconnect',
    (tester) async {
      final state = DesktopNavigationFixture();
      await mountNavigation(tester, state);
      await tapText(tester, '打开编辑器');
      await tester.tap(find.byTooltip('上移云文档'));
      state.connected = false;
      state.emit();
      await tester.pumpAndSettle();
      expect(draftOrder(tester), ['docs', 'messages', 'workbench']);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('草稿已保留'), findsOneWidget);
      state.connected = true;
      state.emit();
      await tester.pumpAndSettle();
      await tapText(tester, '保存');
      expect(state.writes.single, {
        'desktop_nav': ['docs', 'messages', 'workbench'],
        'base_revision': 7,
      });
    },
  );

  testWidgets('menu disables writes offline and cannot remove its last item', (
    tester,
  ) async {
    final state = DesktopNavigationFixture(navigation: ['docs']);
    await mountNavigation(tester, state);
    await tapText(tester, '打开菜单');
    for (final label in ['上移', '下移', '从导航栏移除']) {
      expect(menuButton(tester, label).onPressed, isNull);
    }
    state.connected = false;
    state.emit();
    await tester.pumpAndSettle();
    expect(menuButton(tester, '打开').onPressed, isNotNull);
    expect(menuButton(tester, '编辑导航栏').onPressed, isNotNull);
    expect(state.writes, isEmpty);
  });

  testWidgets(
    'menu permanently locks on same-ID identity turnover and cannot open old route',
    (tester) async {
      final state = DesktopNavigationFixture();
      var opened = 0;
      await mountNavigation(tester, state, onOpen: () => opened++);
      await tapText(tester, '打开菜单');
      state.switchIdentity();
      state.switchIdentity();
      await tester.pumpAndSettle();
      expect(find.text('导航栏操作已锁定'), findsOneWidget);
      expect(find.text('打开'), findsNothing);
      expect(find.text('从导航栏移除'), findsNothing);
      expect(state.writes, isEmpty);
      expect(opened, 0);
    },
  );

  testWidgets(
    'late conflict read cannot restore an editor after identity change',
    (tester) async {
      final state = DesktopNavigationFixture()
        ..failure = OfficeException(409, '设置版本已变化');
      await mountNavigation(tester, state);
      await tapText(tester, '打开编辑器');
      await tapText(tester, '保存');
      state.pendingRead = Completer<Json>();
      await scrollTap(tester, find.text('读取最新设置'));
      state.switchIdentity();
      await tester.pumpAndSettle();
      state.pendingRead!.complete({
        'settings': {
          'revision': 99,
          'desktop_nav': ['mail'],
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('导航栏操作已锁定'), findsOneWidget);
      expect(find.textContaining('服务器导航栏'), findsNothing);
      expect(find.text('保存'), findsNothing);
      expect(state.writes.length, 1);
    },
  );

  testWidgets(
    'closing a pending editor does not pop the underlying screen when save finishes',
    (tester) async {
      final state = DesktopNavigationFixture()..pendingSave = Completer<void>();
      await mountNavigation(tester, state);
      await tapText(tester, '打开编辑器');
      await tapText(tester, '保存');
      await tester.tap(find.byTooltip('取消导航栏编辑'));
      await tester.pumpAndSettle();
      state.pendingSave!.complete();
      await tester.pumpAndSettle();
      expect(find.text('打开编辑器'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restore defaults remains local until explicit save and enterprise is never offered',
    (tester) async {
      final state = DesktopNavigationFixture(navigation: ['docs']);
      state.enterpriseSummary = {
        'capabilities': {'access_admin': true},
      };
      await mountNavigation(tester, state);
      await tapText(tester, '打开编辑器');
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '移除云文档',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('企业管理'), findsNothing);
      await scrollTap(tester, find.text('恢复默认导航栏'));
      expect(state.writes, isEmpty);
      await tapText(tester, '保存');
      expect(state.writes.single, {
        'desktop_nav': defaultOfficeDesktopNavigation,
        'base_revision': 7,
      });
    },
  );
}
