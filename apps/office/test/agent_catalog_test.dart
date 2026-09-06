import 'package:active_office/office_state.dart';
import 'package:active_office/ui/agent_catalog.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:active_office/ui/professional_identity.dart';
import 'package:active_office/ui/companion_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class CatalogOffice extends OfficeState {
  CatalogOffice() {
    catalog = [
      {
        'id': 'developer',
        'name': '代码伙伴',
        'description': '共同实现产品',
        'category_id': 'engineering',
        'category_name': '工程研发',
        'profession': '软件工程师',
        'job_title': '客户端工程师',
        'organization_name': '专业协作目录',
        'skills': ['Flutter'],
        'tags': ['研发'],
        'instructions': '以可运行成果交付',
      },
      {
        'id': 'finance',
        'name': '财务伙伴',
        'description': '核对账目',
        'category_id': 'finance',
        'category_name': '财务运营',
        'profession': '会计',
        'job_title': '财务分析师',
        'organization_name': '财务目录',
        'skills': ['核算'],
      },
      {'id': 'legacy', 'name': '早期伙伴', 'description': '旧目录兼容条目'},
    ];
  }
  String? installed;
  @override
  Future<Json> installAgent(String templateId) async {
    installed = templateId;
    return {'id': 'actual-principal', 'kind': 'agent'};
  }
}

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'Mobile' : 'Desktop'} companion shows actual runtime boundaries before installation',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final template = mobile ? 'mobile-companion' : 'desktop-companion';
        final state = CatalogOffice()
          ..catalog = [
            {
              'id': template,
              'name': mobile ? '手机机伴' : '电脑机伴',
              'description': '共同办公与设备协作',
              'device_capabilities': {
                'schema_version': 1,
                'template_only': true,
                'installation_grants_device_access': false,
                'input_policy': 'isolated_session_only',
                'supported_modes': [
                  {
                    'id': 'native_collaboration',
                    'label': '原生办公协作',
                    'status': 'member_permissions_required',
                    'description': '共享文档与任务继续使用成员权限。',
                  },
                  {
                    'id': mobile
                        ? 'isolated_android_device'
                        : 'isolated_browser',
                    'label': mobile ? '独立Android设备' : '独立浏览器',
                    'status': 'runtime_required',
                    'description': '独立会话可在后台推进。',
                  },
                ],
                'unsupported_modes': [
                  {
                    'id': 'shared_desktop_focus',
                    'label': '共用桌面焦点',
                    'reason': '普通同一桌面跨App操作会抢焦点。',
                  },
                  {
                    'id': 'ios_cross_app',
                    'label': 'iOS跨App控制',
                    'reason': '普通iOS App不支持任意跨App控制。',
                  },
                ],
                'runtime_requirements': ['连接专用运行环境，并取得实际设备授权。'],
              },
            },
          ];
        await tester.pumpWidget(
          MaterialApp(
            theme: officeTheme(),
            home: Scaffold(
              body: AgentCatalog(state: state, onInstalled: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CompanionAvatar), findsOneWidget);
        expect(find.text('找到 1 位 Agent · 目录共 1 位'), findsOneWidget);
        final boundaries = find.text('iOS跨App控制');
        await tester.ensureVisible(boundaries);
        await tester.pumpAndSettle();
        expect(find.text('普通iOS App不支持任意跨App控制。'), findsOneWidget);
        expect(find.text('普通同一桌面跨App操作会抢焦点。'), findsOneWidget);
        expect(
          find.text('${mobile ? '独立Android设备' : '独立浏览器'} · 需接入运行环境'),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('查看接入要求'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('查看接入要求'));
        await tester.pumpAndSettle();
        expect(find.text('连接专用运行环境，并取得实际设备授权。'), findsOneWidget);
        expect(state.installed, isNull);
        await tester.ensureVisible(find.text('添加好友'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加好友'));
        await tester.pumpAndSettle();
        expect(state.installed, template);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }

  testWidgets(
    'Catalog filters real professions and installs matching template',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = CatalogOffice();
      var completed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: AgentCatalog(
              state: state,
              onInstalled: () => completed = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('找到 3 位 Agent · 目录共 3 位'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '客户端工程师');
      await tester.pumpAndSettle();
      expect(find.text('找到 1 位 Agent · 目录共 3 位'), findsOneWidget);
      expect(find.text('职位：客户端工程师'), findsOneWidget);
      expect(find.text('来源组织：专业协作目录'), findsOneWidget);
      expect(find.text('财务伙伴'), findsNothing);
      await tester.tap(find.text('添加好友'));
      await tester.pumpAndSettle();
      expect(state.installed, 'developer');
      expect(completed, isTrue);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('财务运营').last);
      await tester.pumpAndSettle();
      expect(find.text('找到 1 位 Agent · 目录共 3 位'), findsOneWidget);
      expect(find.text('财务伙伴'), findsOneWidget);
      expect(find.text('代码伙伴'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('Mobile catalog supports entries without professional fields', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = CatalogOffice()
      ..catalog = [
        {'id': 'legacy', 'name': '早期伙伴', 'description': '旧目录兼容条目'},
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: AgentCatalog(state: state, onInstalled: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('早期伙伴'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'Human and Agent use same current organization and source labels',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final kind in ['human', 'agent'])
                  ProfessionalIdentity(
                    person: {
                      'kind': kind,
                      'profession': '设计师',
                      'job_title': '体验负责人',
                      'organization_name': '当前企业设计组',
                      'source_organization_name': '专业目录',
                      'department_name': '设计部',
                    },
                  ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('任职组织：当前企业设计组'), findsNWidgets(2));
      expect(find.text('来源组织：专业目录'), findsNWidgets(2));
      expect(find.text('职位：体验负责人'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
