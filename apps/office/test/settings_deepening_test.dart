import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/settings.dart';
import 'package:active_office/ui/settings_account.dart';
import 'package:active_office/ui/settings_session.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class SettingsFixture extends LayoutOfficeState {
  SettingsFixture() {
    settings = {...settings, 'time_format': '24h', 'revision': 7};
    server = {...settings};
    accountInfo = {'username': 'fixture-user'};
  }
  late Json server;
  int generation = 0, reloads = 0, accountWrites = 0;
  bool conflictOnce = false;
  final writes = <Json>[];
  Completer<Json>? pendingRead;
  @override
  int get identityGeneration => generation;
  void emit() => notifyListeners();
  void switchIdentity({bool same = false}) {
    generation++;
    if (!same) me = {'id': 'another-person', 'name': '另一位同事', 'kind': 'agent'};
    emit();
  }

  @override
  Future<void> saveSettings(Json changes, {int? baseRevision}) async {
    writes.add({...changes, 'base_revision': baseRevision});
    if (conflictOnce) {
      conflictOnce = false;
      server = {...server, 'revision': 8, 'time_format': '12h'};
      throw OfficeException(409, '共同设置版本已变化');
    }
    if (baseRevision != server['revision']) throw OfficeException(409, '版本冲突');
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
    if (path == '/settings') {
      return pendingRead?.future ??
          {
            'settings': {...server},
          };
    }
    throw StateError(path);
  }

  @override
  Future<void> reloadSettings() async {
    reloads++;
    settings = {...server};
    emit();
  }

  @override
  Future<void> setAccount(
    String username,
    String password, {
    String? currentPassword,
  }) async {
    accountWrites++;
  }
}

Future<void> mountSettings(
  WidgetTester tester,
  SettingsFixture state, {
  double width = 390,
  int tab = -1,
  VoidCallback? groups,
  VoidCallback? close,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: OfficeSettings(
          state: state,
          initialTab: tab,
          onClose: close,
          onMessageGroups: groups,
          onNavigation: () {},
          onOpenModule: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapSetting(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'mobile general opens real conversation and font preview subpages',
    (tester) async {
      final state = SettingsFixture();
      await mountSettings(tester, state);
      expect(find.text('账号安全中心'), findsOneWidget);
      await tapSetting(tester, find.text('通用'));
      await tapSetting(tester, find.text('会话显示模式'));
      expect(find.text('共同文档已经更新。'), findsNWidgets(2));
      await tapSetting(tester, find.text('消息气泡左对齐'));
      expect(state.writes.single, {
        'message_alignment': 'left',
        'base_revision': 7,
      });
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapSetting(tester, find.text('字体大小'));
      await tapSetting(tester, find.text('130%'));
      final preview = tester.widget<Text>(find.text('一起把工作做好'));
      expect(preview.textScaler!.scale(14), closeTo(18.2, .01));
      expect(state.writes.last, {'text_scale': 1.3, 'base_revision': 8});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'time format persists and settings conflict has explicit reload/adoption recovery',
    (tester) async {
      final state = SettingsFixture()..conflictOnce = true;
      await mountSettings(tester, state, tab: 1);
      final clock = find.byKey(const ValueKey('settings-time-format'));
      await tapSetting(tester, clock);
      expect(state.writes.single, {'time_format': '12h', 'base_revision': 7});
      await tapSetting(tester, find.text('读取最新设置'));
      expect(find.textContaining('最新设置：'), findsOneWidget);
      await tapSetting(tester, find.text('采用最新设置，重新选择'));
      expect(state.reloads, 1);
      expect(state.writes.length, 1);
      await tester.scrollUntilVisible(
        clock,
        -180,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(clock);
      await tester.pumpAndSettle();
      expect(state.writes.last, {'time_format': '24h', 'base_revision': 8});
    },
  );

  testWidgets(
    'desktop displays previews, category names and closes via callback',
    (tester) async {
      var closed = 0;
      final state = SettingsFixture();
      await mountSettings(
        tester,
        state,
        width: 1180,
        tab: 1,
        close: () => closed++,
      );
      expect(find.byKey(const ValueKey('settings-category-0')), findsOneWidget);
      expect(find.text('浅色 · 当前使用'), findsOneWidget);
      await tapSetting(tester, find.text('消息气泡左右分布'));
      expect(state.writes.single['message_alignment'], 'split');
      await tester.tap(find.byTooltip('关闭设置'));
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'efficiency message groups has a real entry and unavailable rows do not save',
    (tester) async {
      var groups = 0;
      final state = SettingsFixture();
      await mountSettings(tester, state, tab: 3, groups: () => groups++);
      await tapSetting(tester, find.text('消息分组'));
      expect(groups, 1);
      await tapSetting(tester, find.text('语音消息自动转文字'));
      expect(find.text('语音消息自动转写服务尚未接入。'), findsOneWidget);
      expect(state.writes, isEmpty);
    },
  );

  for (final entry in [
    (6, '新文档默认访问权限'),
    (7, '全天日程提醒'),
    (8, '邮件签名'),
    (9, '默认麦克风'),
    (10, '每日任务提醒'),
  ]) {
    testWidgets(
      'business settings ${entry.$1} has specific unavailable options without false switches',
      (tester) async {
        final state = SettingsFixture();
        await mountSettings(tester, state, tab: entry.$1);
        await tapSetting(tester, find.text(entry.$2));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(Switch), findsNothing);
        expect(state.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('settings session rejects late reads after identity generation changes including same principal', () async {
    final state = SettingsFixture();
    final session = OfficeSettingsSession(state);
    final pending = Completer<Json>();
    state.pendingRead = pending;
    final reading = session.readLatest();
    state.switchIdentity(same: true);
    pending.complete({
      'settings': {'private_field': 'old-snapshot', 'revision': 80},
    });
    await reading;
    expect(session.valid, false);
    expect(session.latest, isNull);
    expect(session.values, isEmpty);
    await session.save({'time_format': '12h'});
    expect(state.writes, isEmpty);
    session.dispose();
    state.dispose();
  });

  test('settings offline state preserves values, pauses saves and recovers same identity', () async {
    final state = SettingsFixture();
    final session = OfficeSettingsSession(state);
    state.connected = false;
    state.emit();
    expect(session.valid, true);
    expect(session.values['time_format'], '24h');
    await session.save({'time_format': '12h'});
    expect(state.writes, isEmpty);
    state.connected = true;
    state.emit();
    await session.save({'time_format': '12h'});
    expect(state.writes.single['time_format'], '12h');
    session.dispose();
    state.dispose();
  });

  for (final identityChange in ['principal', 'endpoint', 'generation']) {
    testWidgets(
      'account editor clears passwords and permanently locks on $identityChange change',
      (tester) async {
        final state = SettingsFixture();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: officeTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showOfficeAccountEditor(context, state),
                  child: const Text('账号编辑'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('账号编辑'));
        await tester.pumpAndSettle();
        final fields = tester
            .widgetList<TextFormField>(find.byType(TextFormField))
            .toList();
        final controllers = fields.map((field) => field.controller!).toList();
        for (final controller in controllers.skip(1)) {
          controller.text = 'synthetic-password';
        }
        if (identityChange == 'principal') state.switchIdentity();
        if (identityChange == 'generation') state.switchIdentity(same: true);
        if (identityChange == 'endpoint') {
          state.endpoint = 'https://another.example';
          state.emit();
        }
        await tester.pumpAndSettle();
        expect(
          controllers.every((controller) => controller.text.isEmpty),
          true,
        );
        expect(find.byType(TextFormField), findsNothing);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        expect(state.accountWrites, 0);
      },
    );
  }

  testWidgets(
    'temporary offline keeps password draft but disables account save until reconnection',
    (tester) async {
      final state = SettingsFixture();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showOfficeAccountEditor(context, state),
                child: const Text('账号编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('账号编辑'));
      await tester.pumpAndSettle();
      final controllers = tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .map((field) => field.controller!)
          .toList();
      for (final controller in controllers.skip(1)) {
        controller.text = 'synthetic-password';
      }
      state.connected = false;
      state.emit();
      await tester.pumpAndSettle();
      expect(controllers.last.text, 'synthetic-password');
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      state.connected = true;
      state.emit();
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(state.accountWrites, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
