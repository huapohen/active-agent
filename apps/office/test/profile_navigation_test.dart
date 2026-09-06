import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/minutes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class ProfileNavigationOffice extends LayoutOfficeState {
  ProfileNavigationOffice({
    bool admin = false,
    super.kind = 'human',
    this.conflict = false,
  }) {
    enterpriseSummary = {
      'enterprise': {'name': '真实协作企业'},
      'membership': {'role': admin ? 'admin' : 'member'},
      'capabilities': {'access_admin': admin},
    };
    settings = {
      ...settings,
      'revision': 7,
      'mobile_nav': ['messages', 'agents', 'docs', 'workbench'],
    };
    accountInfo = {'username': 'test.member'};
    apps.add({
      'id': 'minutes',
      'name': '人机妙记',
      'route': '/office#minutes',
      'available': true,
    });
  }
  bool conflict;
  final writes = <Json>[];
  int minutesReads = 0;
  @override
  Future<void> saveSettings(Json changes, {int? baseRevision}) async {
    writes.add({...changes, 'base_revision': baseRevision});
    if (conflict && baseRevision != 10) throw OfficeException(409, '设置版本冲突');
    settings = {...settings, ...changes, 'revision': (baseRevision ?? 7) + 1};
    notifyListeners();
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path.startsWith('/minutes?')) {
      minutesReads++;
      return {'minutes': <Json>[]};
    }
    if (path == '/settings') {
      return {
        'settings': {
          'revision': 10,
          'mobile_nav': ['mail', 'calendar'],
        },
      };
    }
    throw StateError('Unexpected request: $path');
  }
}

List<String> labels(WidgetTester tester) => tester
    .widget<NavigationBar>(find.byType(NavigationBar))
    .destinations
    .whereType<NavigationDestination>()
    .map((item) => item.label)
    .toList();

void mobile(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'Minutes opens from mobile More and a saved bottom slot while app policy remains authoritative',
    (tester) async {
      mobile(tester);
      final state = ProfileNavigationOffice();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '更多'));
      await tester.pumpAndSettle();
      final minutesTile = find.widgetWithText(ListTile, '人机妙记');
      await tester.ensureVisible(minutesTile);
      await tester.tap(minutesTile);
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMinutes), findsOneWidget);
      expect(state.minutesReads, 1);
      expect(find.text('从一份对话记录开始'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.widgetWithText(NavigationDestination, '更多'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('编辑底栏'));
      await tester.tap(find.text('编辑底栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('移除云文档'));
      await tester.pump();
      final minutesChip = find.widgetWithText(ActionChip, '人机妙记');
      await tester.ensureVisible(minutesChip);
      await tester.tap(minutesChip);
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(labels(tester), ['消息', 'Agent', '工作台', '人机妙记', '更多']);
      expect(state.writes.single['mobile_nav'], [
        'messages',
        'agents',
        'workbench',
        'minutes',
      ]);
      await tester.tap(find.widgetWithText(NavigationDestination, '人机妙记'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMinutes), findsOneWidget);
      expect(state.minutesReads, 2);

      state.unavailableModules.add('minutes');
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMinutes), findsNothing);
      expect(find.text('企业策略已限制此应用'), findsOneWidget);
      expect(state.minutesReads, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('Desktop minutes navigation reaches the independent library', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1512, 982);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = ProfileNavigationOffice();
    state.selectedRoomId = null;
    state.detail = null;
    await tester.pumpWidget(ActiveOfficeApp(state: state));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('人机妙记'));
    await tester.tap(find.text('人机妙记'));
    await tester.pumpAndSettle();
    expect(find.byType(OfficeMinutes), findsOneWidget);
    expect(state.minutesReads, 1);
    expect(find.text('从一份对话记录开始'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'Mobile bottom navigation saves ordered server preferences and keeps all modules reachable',
    (tester) async {
      mobile(tester);
      final state = ProfileNavigationOffice();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑底栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('移除云文档'));
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(ActionChip, '邮箱'));
      await tester.tap(find.widgetWithText(ActionChip, '邮箱'));
      await tester.pump();
      await tester.ensureVisible(find.byTooltip('上移Agent'));
      await tester.tap(find.byTooltip('上移Agent'));
      await tester.pump();
      expect(find.widgetWithText(ActionChip, '企业管理'), findsNothing);
      expect(
        tester
            .widget<ActionChip>(find.widgetWithText(ActionChip, '日历'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(state.writes.single, {
        'mobile_nav': ['agents', 'messages', 'workbench', 'mail'],
        'base_revision': 7,
      });
      expect(labels(tester), ['Agent', '消息', '工作台', '邮箱', '更多']);
      expect(find.widgetWithText(ListTile, '云文档'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      expect(labels(tester), ['Agent', '消息', '工作台', '邮箱', '更多']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'Navigation conflict preserves choices and requires explicit latest revision adoption',
    (tester) async {
      mobile(tester);
      final state = ProfileNavigationOffice(conflict: true);
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑底栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('上移Agent'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(labels(tester), ['消息', 'Agent', '云文档', '工作台', '更多']);
      await tester.ensureVisible(find.text('读取最新设置'));
      await tester.tap(find.text('读取最新设置'));
      await tester.pumpAndSettle();
      expect(find.text('服务器底栏：邮箱 / 日历'), findsOneWidget);
      expect(state.writes.length, 1);
      await tester.ensureVisible(find.text('保留我的排序继续编辑'));
      await tester.tap(find.text('保留我的排序继续编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(state.writes.last, {
        'mobile_nav': ['agents', 'messages', 'docs', 'workbench'],
        'base_revision': 10,
      });
      expect(labels(tester).first, 'Agent');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  for (final admin in [false, true]) {
    testWidgets(
      '${admin ? 'Agent admin desktop' : 'Human member mobile'} avatar opens real identity and settings with actual authority',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = admin
            ? const Size(1512, 982)
            : const Size(390, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = ProfileNavigationOffice(
          admin: admin,
          kind: admin ? 'agent' : 'human',
        );
        await tester.pumpWidget(ActiveOfficeApp(state: state));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('我的与设置').first);
        await tester.pumpAndSettle();
        expect(find.text('我的'), findsOneWidget);
        expect(find.text('真实协作企业'), findsOneWidget);
        expect(find.text('账号：test.member'), findsOneWidget);
        expect(find.text('企业管理'), admin ? findsOneWidget : findsNothing);
        expect(find.text('编辑手机底栏'), findsNothing);
        expect(find.text('个人设置'), findsNothing);
        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        if (!admin) {
          expect(find.byType(NavigationBar), findsNothing);
          await tester.tap(find.text('通用'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('返回设置'));
          await tester.pumpAndSettle();
          expect(find.text('账号安全中心'), findsOneWidget);
        }
        await tester.tap(find.text('通用').first);
        await tester.pumpAndSettle();
        expect(find.text('文字大小'), findsOneWidget);
        await tester.ensureVisible(find.text('编辑底栏'));
        await tester.tap(find.text('编辑底栏'));
        await tester.pumpAndSettle();
        expect(find.text('保存'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }
}
