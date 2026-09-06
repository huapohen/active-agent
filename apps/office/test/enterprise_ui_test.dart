import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/enterprise_state.dart';
import 'package:active_office/ui/enterprise.dart';
import 'package:active_office/ui/enterprise_apps.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;

class EnterpriseTestOffice extends OfficeState {
  EnterpriseTestOffice({this.role = 'owner', String kind = 'human'}) {
    endpoint = 'https://enterprise.example';
    me = {'id': 'self', 'name': '管理身份', 'kind': kind};
    connected = true;
    principals = directory;
  }
  final String role;
  final calls = <String>[];
  final writes = <Json>[];
  Map<String, bool> flags(String role) => {
    'access_admin': role != 'member',
    'manage_members': role != 'member',
    'manage_departments': role != 'member',
    'assign_admin': role == 'owner',
    'assign_owner': role == 'owner',
    'view_audit': role != 'member',
    'manage_enterprise': role == 'owner',
    'manage_apps': role != 'member',
  };
  Json get organization => {
    'id': 'enterprise-workspace',
    'name': '协作研究工作空间',
    'initialized': true,
    'revision': 1,
    'created_at': '2026-09-07T01:00:00Z',
    'updated_at': '2026-09-07T02:00:00Z',
  };
  List<Json> get directory => [
    {
      'id': 'self',
      'principal_id': 'self',
      'name': '管理身份',
      'kind': me!['kind'],
      'role': role,
      'status': 'active',
      'revision': 1,
      'department_id': null,
    },
    {
      'id': 'agent-owner',
      'principal_id': 'agent-owner',
      'name': 'Agent 企业所有者',
      'kind': 'agent',
      'role': 'owner',
      'status': 'active',
      'revision': 1,
      'department_id': 'dept-product',
      'department_name': '产品研发',
    },
    {
      'id': 'member-human',
      'principal_id': 'member-human',
      'name': '张同学',
      'kind': 'human',
      'role': 'member',
      'status': 'active',
      'revision': 1,
      'department_id': 'dept-product',
      'department_name': '产品研发',
    },
    {
      'id': 'member-agent',
      'principal_id': 'member-agent',
      'name': '研究 Agent',
      'kind': 'agent',
      'role': 'member',
      'status': 'disabled',
      'revision': 1,
      'department_id': null,
    },
  ];
  final enterpriseApps = <Json>[
    {
      'id': 'docs',
      'name': '协作文档应用',
      'builtin': true,
      'available': true,
      'protected_core': false,
      'description': '共享文档',
      'capabilities': [
        {'id': 'docs.documents', 'name': '文档读写'},
      ],
      'policy': {
        'revision': 1,
        'enabled': true,
        'scope_mode': 'all',
        'allowed_principal_ids': <String>[],
        'allowed_department_ids': <String>[],
        'denied_principal_ids': <String>[],
      },
    },
    {
      'id': 'settings',
      'name': '身份设置核心',
      'builtin': true,
      'available': true,
      'protected_core': true,
      'capabilities': <Json>[],
      'policy': {
        'revision': 1,
        'enabled': true,
        'scope_mode': 'all',
        'allowed_principal_ids': <String>[],
        'allowed_department_ids': <String>[],
        'denied_principal_ids': <String>[],
      },
    },
    {
      'id': 'device',
      'name': '待连接设备应用',
      'builtin': false,
      'available': false,
      'protected_core': false,
      'capabilities': <Json>[],
      'policy': {
        'revision': 1,
        'enabled': true,
        'scope_mode': 'all',
        'allowed_principal_ids': <String>[],
        'allowed_department_ids': <String>[],
        'denied_principal_ids': <String>[],
      },
    },
  ];
  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    calls.add('$method $path');
    if (method != 'GET') writes.add({'path': path, ...?data});
    final uri = Uri.parse(path);
    final summary = <String, dynamic>{
      'enterprise': organization,
      'membership': {
        'principal_id': 'self',
        'role': role,
        'status': 'active',
        'revision': 1,
      },
      'capabilities': flags(role),
    };
    if (path == '/enterprise') return summary;
    if (role == 'member') throw OfficeException(403, '当前角色没有企业管理权限');
    if (uri.path == '/enterprise/admin/apps') return {'apps': enterpriseApps};
    if (method == 'PATCH' && uri.path.startsWith('/enterprise/admin/apps/')) {
      final app = enterpriseApps.firstWhere(
        (app) => app['id'] == uri.pathSegments.last,
      );
      app['policy'] = {...Json.from(app['policy']), ...?data, 'revision': 2};
      return {'app': app};
    }
    if (method == 'POST' && uri.path == '/enterprise/admin/members') {
      return {
        'member': {
          'id': 'new-member',
          'name': data?['name'],
          'kind': data?['kind'],
          'role': 'member',
        },
        'token': 'synthetic-one-time-fixture',
        'duplicate': false,
      };
    }
    if (method == 'POST' && uri.path == '/enterprise/admin/departments') {
      return {
        'department': {
          'id': 'new-department',
          'name': data?['name'],
          'revision': 1,
        },
        'duplicate': false,
      };
    }
    if (uri.path == '/enterprise/admin/overview') {
      return {
        ...summary,
        'counts': {
          'members': 4,
          'active': 3,
          'disabled': 1,
          'humans': 2,
          'agents': 2,
          'departments': 1,
          'owners': 2,
          'admins': 0,
        },
      };
    }
    if (uri.path == '/enterprise/admin/members') {
      final filter = uri.queryParameters['role'];
      final values = filter == null || filter == 'all'
          ? directory
          : directory.where((member) => member['role'] == filter).toList();
      return {
        'members': values,
        'total': values.length,
        'page': 1,
        'page_size': 25,
      };
    }
    if (uri.path == '/enterprise/admin/departments') {
      return {
        'departments': [
          {
            'id': 'dept-product',
            'name': '产品研发',
            'parent_id': null,
            'revision': 1,
            'member_count': 2,
          },
        ],
      };
    }
    if (uri.path == '/enterprise/admin/roles') {
      return {
        'roles': ['owner', 'admin', 'member']
            .map(
              (role) => <String, dynamic>{
                'id': role,
                'name': enterpriseRole(role),
                'capabilities': flags(role),
              },
            )
            .toList(),
      };
    }
    if (uri.path == '/enterprise/admin/audit') {
      return {
        'entries': [
          {
            'id': 'event-1',
            'at': '2026-09-07T01:00:00Z',
            'actor_id': 'agent-owner',
            'actor_kind': 'agent',
            'action': 'member.updated',
            'target_id': 'member-human',
            'target_type': 'member',
            'details': {
              'after': {'name': '张同学', 'role': 'member'},
            },
          },
        ],
        'total': 1,
        'page': 1,
        'page_size': 25,
      };
    }
    throw OfficeException(404, '未找到测试端点');
  }
}

void main() {
  test('ordinary member controller never loads administrator data', () async {
    final office = EnterpriseTestOffice(role: 'member');
    final enterprise = EnterpriseState(office);
    await enterprise.load();
    expect(enterprise.can('access_admin'), false);
    expect(office.calls, ['GET /enterprise']);
    expect(enterprise.members, isEmpty);
    enterprise.dispose();
    office.dispose();
  });
  test(
    'enterprise creates reuse intent ids and never retain member credentials',
    () async {
      final office = EnterpriseTestOffice();
      final enterprise = EnterpriseState(office);
      await enterprise.load();
      final result = await enterprise.createMember(
        name: '新同事',
        kind: 'agent',
        clientId: 'member-intent',
      );
      await enterprise.saveDepartment(
        name: '研究组',
        clientId: 'department-intent',
      );
      expect(office.writes[0]['client_id'], 'member-intent');
      expect(office.writes[1]['client_id'], 'department-intent');
      expect(result['token'], isNotEmpty);
      expect(
        enterprise.members.any((member) => member.containsKey('token')),
        false,
      );
      enterprise.dispose();
      office.dispose();
    },
  );
  for (final size in [
    const Size(390, 844),
    const Size(943, 665),
    const Size(1512, 982),
  ]) {
    testWidgets('Enterprise console responsive management ${size.width}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final office = EnterpriseTestOffice(kind: 'agent');
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(body: OfficeEnterprise(state: office)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('协作研究工作空间'), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final label in ['成员与组织', '部门管理', '角色与权限', '管理日志', '企业应用']) {
        final tab = find.text(label).first;
        await tester.ensureVisible(tab);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
      }
      final roleTab = find.text('角色与权限').first;
      await tester.ensureVisible(roleTab);
      await tester.tap(roleTab);
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看详情').first);
      await tester.pumpAndSettle();
      expect(find.text('权限范围'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭角色详情'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      office.dispose();
    });
  }
  testWidgets('ordinary agent cannot see management controls', (tester) async {
    final office = EnterpriseTestOffice(role: 'member', kind: 'agent');
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Scaffold(body: OfficeEnterprise(state: office)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前身份没有企业管理权限'), findsOneWidget);
    expect(find.text('添加成员'), findsNothing);
    expect(find.text('编辑企业信息'), findsNothing);
    expect(office.calls, ['GET /enterprise']);
    await tester.pumpWidget(const SizedBox.shrink());
    office.dispose();
  });
  testWidgets(
    'Enterprise policy saves real Agent scope and protects core apps',
    (tester) async {
      final office = EnterpriseTestOffice(kind: 'agent');
      final enterprise = EnterpriseState(office);
      await enterprise.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(body: OfficeEnterpriseApps(controller: enterprise)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已登记，尚未连接'), findsOneWidget);
      await tester.tap(find.text('配置').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('指定范围'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择人或 Agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agent 企业所有者'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存企业策略'));
      await tester.pumpAndSettle();
      expect(office.writes.last['allowed_principal_ids'], ['agent-owner']);
      expect(office.writes.last['scope_mode'], 'restricted');
      expect(office.writes.last['base_revision'], 1);
      await tester.tap(find.text('查看详情').first);
      await tester.pumpAndSettle();
      expect(find.text('保存企业策略'), findsNothing);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      enterprise.dispose();
      office.dispose();
    },
  );
}
