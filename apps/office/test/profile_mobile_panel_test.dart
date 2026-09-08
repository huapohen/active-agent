import 'package:active_office/office_state.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:active_office/ui/profile_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ProfileMobileFixture extends OfficeState {
  ProfileMobileFixture({bool admin = false, String kind = 'human'}) {
    endpoint = 'https://profile-fixture.example';
    me = {'id': 'profile-$kind', 'name': '合成资料长名称用于检查窄屏布局', 'kind': kind};
    enterpriseSummary = {
      'enterprise': {'name': '当前已登录的合成工作空间名称'},
      'membership': {'role': admin ? 'admin' : 'member'},
      'capabilities': {'access_admin': admin},
    };
  }
  int generation = 0;
  @override
  int get identityGeneration => generation;
  bool get listening => hasListeners;
  void changed() => notifyListeners();
}

Future<void> mountProfile(
  WidgetTester tester,
  ProfileMobileFixture state,
  List<String?> results, {
  double width = 402,
  double scale = 1,
  double safeTop = 44,
}) async {
  tester.view.physicalSize = Size(width, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          padding: EdgeInsets.only(top: safeTop, bottom: 34),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showOfficeProfileMenu(
                context,
                state,
                anchor: const Rect.fromLTWH(10, 50, 40, 40),
              );
              results.add(result);
            },
            child: const Text('打开个人面板'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开个人面板'));
  await tester.pumpAndSettle();
}

Finder actionInk(String label) => find
    .ancestor(of: find.text(label).last, matching: find.byType(InkWell))
    .first;

void main() {
  testWidgets('profile matches the mobile reference panel geometry', (
    tester,
  ) async {
    final state = ProfileMobileFixture(admin: true);
    state.me = {...state.me!, 'name': '测试员'};
    state.enterpriseSummary = {
      ...state.enterpriseSummary,
      'enterprise': {'name': '合成协作科技有限公司'},
      'membership': {'role': 'admin', 'status': 'active'},
    };
    final results = <String?>[];
    await mountProfile(tester, state, results, safeTop: 62);
    final panel = tester.getRect(
      find.byKey(const ValueKey('mobile-profile-layout')),
    );
    final rail = tester.getRect(
      find.byKey(const ValueKey('mobile-profile-account-rail')),
    );
    final avatar = tester.getRect(
      find.byKey(const ValueKey('mobile-profile-avatar')),
    );
    // Measured from the visible display in reference 8.png and the later
    // native capture, normalized to a 402-point mobile display.
    expect(panel.width, closeTo(352, 2));
    expect(rail.width, closeTo(99, 2));
    expect(avatar.left, closeTo(115, 2));
    expect(avatar.top, closeTo(78, 2));
    expect(avatar.size, const Size(70, 70));
    final card = tester.getRect(actionInk('我的个人名片'));
    final wallet = tester.getRect(actionInk('钱包'));
    expect(card.center.dy, closeTo(289, 5));
    expect(wallet.center.dy - card.center.dy, closeTo(57, 2));
    expect(find.text('企业管理员 · 正常'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  for (final width in [320.0, 402.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'mobile profile $width width and $scale scale has two columns and scrollable actions',
        (tester) async {
          final state = ProfileMobileFixture(admin: true);
          final results = <String?>[];
          await mountProfile(
            tester,
            state,
            results,
            width: width,
            scale: scale,
          );
          expect(
            find.byKey(const ValueKey('mobile-profile-layout')),
            findsOneWidget,
          );
          expect(find.text('当前已登录的合成工作空间名称'), findsNWidgets(2));
          expect(find.text('企业管理员'), findsOneWidget);
          expect(find.text('已认证'), findsNothing);
          expect(find.text('输入你的个性签名...'), findsNothing);
          expect(find.text('登录更多账号'), findsNWidgets(2));
          expect(tester.takeException(), isNull);
          final rail = tester.getRect(find.text('登录更多账号').first);
          final identity = tester.getRect(find.text(state.me!['name']));
          expect(rail.right, lessThan(identity.left));
          await tester.ensureVisible(find.text('设置'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('退出当前身份'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('退出当前身份'));
          await tester.pumpAndSettle();
          expect(results, ['logout']);
          await tester.pumpWidget(const SizedBox());
          state.dispose();
        },
      );
    }
  }

  for (final entry in {
    '我的个人名片': 'card',
    '+ 状态': 'status',
    '收藏': 'favorites',
    '登录更多账号': 'switch',
    '帮助与客服': 'help',
    'Agent 同事': 'agents',
    '登录设备': 'account',
    '设置': 'settings',
    '企业管理': 'enterprise',
  }.entries) {
    testWidgets('mobile ${entry.key} returns ${entry.value} action', (
      tester,
    ) async {
      final state = ProfileMobileFixture(admin: true);
      final results = <String?>[];
      await mountProfile(tester, state, results);
      final target = find.text(entry.key).last;
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(results, [entry.value]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets(
    'current workspace and account rail return real actions; wallet stays unavailable',
    (tester) async {
      final state = ProfileMobileFixture();
      final results = <String?>[];
      await mountProfile(tester, state, results);
      expect(find.text('企业管理'), findsNothing);
      expect(find.text('普通成员'), findsOneWidget);
      await tester.tap(find.text('钱包'));
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(find.text('未接入'), findsOneWidget);
      await tester.tap(find.text('当前已登录的合成工作空间名称').first);
      await tester.pumpAndSettle();
      expect(results, ['workspace']);
      await tester.tap(find.text('打开个人面板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('登录更多账号').first);
      await tester.pumpAndSettle();
      expect(results, ['workspace', 'switch']);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  for (final turnover in ['principal', 'endpoint', 'generation']) {
    testWidgets('$turnover turnover invalidates old profile and stale action', (
      tester,
    ) async {
      final state = ProfileMobileFixture(admin: true, kind: 'agent');
      final results = <String?>[];
      await mountProfile(tester, state, results);
      final staleTap = tester.widget<InkWell>(actionInk('设置')).onTap!;
      final original = Map<String, dynamic>.from(state.me!);
      switch (turnover) {
        case 'principal':
          state.me = {'id': 'other', 'name': '新身份', 'kind': 'human'};
        case 'endpoint':
          state.endpoint = 'https://other-fixture.example';
        case 'generation':
          state.generation++;
      }
      state.changed();
      staleTap();
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(find.text(original['name']), findsNothing);
      expect(find.text('当前已登录的合成工作空间名称'), findsNothing);
      expect(find.text('工作身份已切换'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('工作身份已切换')).dy,
        greaterThanOrEqualTo(44),
      );
      state.me = original;
      state.changed();
      await tester.pumpAndSettle();
      expect(find.text('工作身份已切换'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets(
    'revoked admin access cannot dispatch a stale enterprise action',
    (tester) async {
      final state = ProfileMobileFixture(admin: true);
      final results = <String?>[];
      await mountProfile(tester, state, results);
      final staleTap = tester.widget<InkWell>(actionInk('企业管理')).onTap!;
      state.enterpriseSummary = {
        ...state.enterpriseSummary,
        'capabilities': {'access_admin': false},
      };
      state.changed();
      staleTap();
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(find.text('企业管理'), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile-profile-layout')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('设置'));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(results, ['settings']);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'disabled or revoked membership cannot expose enterprise admin entry',
    (tester) async {
      final state = ProfileMobileFixture(admin: true);
      final results = <String?>[];
      await mountProfile(tester, state, results);
      expect(state.canManageEnterprise, isTrue);
      for (final status in ['disabled', 'revoked']) {
        state.enterpriseSummary = {
          ...state.enterpriseSummary,
          'membership': {
            ...Map<String, dynamic>.from(
              state.enterpriseSummary['membership'] as Map,
            ),
            'status': status,
          },
        };
        state.changed();
        await tester.pumpAndSettle();
        expect(state.canManageEnterprise, isFalse);
        expect(find.text('企业管理'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'replacing OfficeState invalidates panel and unbinds the old listener',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final first = ProfileMobileFixture(admin: true);
      final second = ProfileMobileFixture();
      second.me = {...second.me!, 'name': '替换后的工作身份'};
      Widget page(OfficeState state) => MaterialApp(
        home: Scaffold(body: OfficeProfilePanel(state: state)),
      );
      await tester.pumpWidget(page(first));
      await tester.pumpWidget(page(second));
      await tester.pumpAndSettle();
      expect(find.text('工作身份已切换'), findsOneWidget);
      expect(find.text('替换后的工作身份'), findsNothing);
      expect(first.listening, isFalse);
      first.changed();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(second.listening, isFalse);
      first.dispose();
      second.dispose();
    },
  );
}
