import 'dart:async';

import 'package:active_office/enterprise_state.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/enterprise.dart';
import 'package:active_office/ui/enterprise_directory.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'enterprise_ui_test.dart' show EnterpriseTestOffice;

final directoryDepartments = <Json>[
  {
    'id': 'leaf',
    'name': '体验设计',
    'parent_id': 'dept-product',
    'member_count': 1,
    'revision': 1,
  },
  {
    'id': 'other',
    'name': '运营支持',
    'parent_id': null,
    'member_count': 0,
    'revision': 1,
  },
  {
    'id': 'root',
    'name': '协作总部',
    'parent_id': null,
    'member_count': 1,
    'revision': 1,
  },
  {
    'id': 'dept-product',
    'name': '产品研发',
    'parent_id': 'root',
    'member_count': 2,
    'revision': 1,
  },
];

class DirectoryOffice extends EnterpriseTestOffice {
  DirectoryOffice({super.role, super.kind}) {
    records = super.directory
        .map(
          (member) => <String, dynamic>{
            ...member,
            'department_id': member['id'] == 'member-agent'
                ? 'leaf'
                : member['id'] == 'self'
                ? 'root'
                : 'dept-product',
            'organization_id': member['id'] == 'self' ? 'ops' : 'design',
            'profession': '产品设计',
            'job_title': '协作成员',
            'source_organization_name': '来源实验室',
            'created_at': '2026-09-06T08:00:00Z',
          },
        )
        .toList();
  }
  late List<Json> records;
  final organizations = <Json>[
    {'id': 'design', 'name': '设计共创组织', 'revision': 1, 'member_count': 3},
    {'id': 'ops', 'name': '运营协作组织', 'revision': 1, 'member_count': 1},
  ];
  Completer<Json>? pendingMembers, pendingDetail;
  final patches = <Json>[];
  bool wrongDetail = false;
  Json member(String id) => records.firstWhere((value) => value['id'] == id);
  Json project(Json member) => {
    ...member,
    'department_name': directoryDepartments
        .where((d) => d['id'] == member['department_id'])
        .firstOrNull?['name'],
    'organization_name': organizations
        .where((o) => o['id'] == member['organization_id'])
        .firstOrNull?['name'],
  };
  void switchIdentity() {
    me = {'id': 'another', 'name': '另一个身份', 'kind': 'agent'};
    notifyListeners();
  }

  @override
  Map<String, bool> flags(String role) => {
    ...super.flags(role),
    'manage_organizations': role != 'member',
  };
  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    final uri = Uri.parse(path);
    if (uri.path == '/enterprise/admin/organizations') {
      calls.add('$method $path');
      return {'organizations': organizations};
    }
    if (uri.path == '/enterprise/admin/departments') {
      calls.add('$method $path');
      return {'departments': directoryDepartments};
    }
    if (uri.path == '/enterprise/admin/members' && method == 'GET') {
      calls.add('$method $path');
      if (pendingMembers != null) {
        final pending = pendingMembers!;
        pendingMembers = null;
        return pending.future;
      }
      final p = uri.queryParameters;
      final query = (p['q'] ?? '').toLowerCase();
      final filtered = records
          .map(project)
          .where(
            (m) =>
                (p['status'] == null ||
                    p['status'] == 'all' ||
                    p['status'] == m['status']) &&
                (p['role'] == null ||
                    p['role'] == 'all' ||
                    p['role'] == m['role']) &&
                (p['department_id'] == null ||
                    p['department_id'] == m['department_id']) &&
                (p['organization_id'] == null ||
                    p['organization_id'] == m['organization_id']) &&
                [
                  'id',
                  'name',
                  'kind',
                  'profession',
                  'job_title',
                  'department_name',
                  'organization_name',
                ].any((key) => '${m[key] ?? ''}'.toLowerCase().contains(query)),
          )
          .toList();
      final page = int.parse(p['page'] ?? '1');
      return {
        'members': filtered.skip((page - 1) * 25).take(25).toList(),
        'total': filtered.length,
        'page': page,
      };
    }
    if (uri.path.startsWith('/enterprise/admin/members/')) {
      calls.add('$method $path');
      final current = member(uri.pathSegments.last);
      if (method == 'GET') {
        if (pendingDetail != null) {
          final pending = pendingDetail!;
          pendingDetail = null;
          return pending.future;
        }
        return {'member': project(wrongDetail ? member('self') : current)};
      }
      if (method == 'PATCH') {
        patches.add(Json.from(data!));
        if (current['revision'] != data['base_revision']) {
          throw OfficeException(409, '成员版本冲突');
        }
        current.addAll({...data, 'revision': (current['revision'] as int) + 1});
        return {'member': project(current)};
      }
      throw StateError('Unexpected member method $method');
    }
    return super.officeRequest(path, method: method, data: data);
  }
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
Finder dropdown(String label) => find.byWidgetPredicate(
  (w) =>
      w is DropdownButtonFormField<String> && w.decoration.labelText == label,
);

Future<void> selectOption(
  WidgetTester tester,
  String label,
  String value,
) async {
  final control = dropdown(label).last;
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
  final option = find.text(value).last;
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

Future<EnterpriseState> mountDirectory(
  WidgetTester tester,
  DirectoryOffice office,
  Size size,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final state = EnterpriseState(office);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: OfficeEnterprise(state: office, controller: state),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('成员与组织').first);
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    office.dispose();
  });
  return state;
}

void main() {
  test('Organization filter is server-side, survives pagination/search, and rejects stale results', () async {
    final office = DirectoryOffice(kind: 'agent');
    office.records.addAll(
      List.generate(
        28,
        (i) => {
          ...office.member('member-human'),
          'id': 'extra-$i',
          'principal_id': 'extra-$i',
          'name': '设计同事 $i',
        },
      ),
    );
    final state = EnterpriseState(office);
    await state.load();
    await state.loadMembers(page: 1, organization: 'design');
    expect(state.memberTotal, 31);
    expect(state.members.length, 25);
    await state.loadMembers(page: 2);
    expect(state.memberPage, 2);
    expect(state.members.length, 6);
    expect(state.memberOrganization, 'design');
    await state.loadMembers(
      page: 1,
      query: '设计同事',
      status: 'active',
      role: 'member',
      department: 'dept-product',
    );
    expect(state.memberTotal, 28);
    final query = Uri.parse(office.calls.last.substring(4)).queryParameters;
    expect(query, containsPair('organization_id', 'design'));
    expect(query, containsPair('department_id', 'dept-product'));
    final pending = office.pendingMembers = Completer<Json>();
    final old = state.loadMembers(page: 1, query: '旧请求');
    await state.loadMembers(page: 1, query: '设计同事 27');
    pending.complete({
      'members': [office.project(office.member('self'))],
      'total': 99,
      'page': 7,
    });
    await old;
    expect(state.memberTotal, 1);
    expect(state.members.single['id'], 'extra-27');
    expect(state.memberPage, 1);
    await state.loadMembers(
      page: 1,
      query: '',
      role: 'all',
      status: 'all',
      clearDepartment: true,
      clearOrganization: true,
    );
    expect(state.memberOrganization, isNull);
    expect(state.memberTotal, 32);
    state.dispose();
    office.dispose();
  });

  test(
    'Member detail rejects mismatched principal and delayed identity response',
    () async {
      final office = DirectoryOffice();
      final state = EnterpriseState(office);
      await state.load();
      office.wrongDetail = true;
      await expectLater(
        state.readMember('member-human'),
        throwsA(isA<OfficeException>().having((e) => e.status, 'status', 502)),
      );
      office.wrongDetail = false;
      final pending = office.pendingDetail = Completer<Json>();
      final read = state.readMember('member-human');
      office.switchIdentity();
      pending.complete({
        'member': office.project(office.member('member-human')),
      });
      await expectLater(
        read,
        throwsA(isA<OfficeException>().having((e) => e.status, 'status', 401)),
      );
      state.dispose();
      office.dispose();
    },
  );

  for (final width in [390.0, 1512.0]) {
    testWidgets(
      'Recursive department search retains ancestry and direct counts $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: officeTheme(),
            home: Scaffold(
              body: EnterpriseDepartmentBrowser(
                departments: directoryDepartments,
                onSelected: (id) => selected = id,
              ),
            ),
          ),
        );
        expect(find.text('1 位直属成员'), findsNWidgets(2));
        final rootX = tester.getTopLeft(find.text('协作总部')).dx;
        final midX = tester.getTopLeft(find.text('产品研发')).dx;
        final leafX = tester.getTopLeft(find.text('体验设计')).dx;
        expect(midX, greaterThan(rootX));
        expect(leafX, greaterThan(midX));
        await tester.tap(find.byTooltip('收起协作总部'));
        await tester.pumpAndSettle();
        expect(find.text('体验设计'), findsNothing);
        await tester.enterText(find.byType(TextField), '体验');
        await tester.pumpAndSettle();
        expect(find.text('协作总部'), findsOneWidget);
        expect(find.text('产品研发'), findsOneWidget);
        expect(find.text('体验设计'), findsOneWidget);
        expect(find.text('运营支持'), findsNothing);
        await tester.tap(find.text('体验设计'));
        expect(selected, 'leaf');
        await tester.enterText(find.byType(TextField), '无匹配');
        await tester.pumpAndSettle();
        expect(find.text('没有匹配的部门'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    for (final targetKind in ['human', 'agent']) {
      testWidgets(
        'Fresh $targetKind detail and equal organization/role editing $width',
        (tester) async {
          final office = DirectoryOffice(
            kind: targetKind == 'human' ? 'agent' : 'human',
          );
          await mountDirectory(tester, office, Size(width, 982));
          final id = 'member-$targetKind';
          final member = office.member(id),
              oldName = office.member(id)['name'] as String;
          member.addAll({
            'name': '最新$targetKind成员',
            'profession': '协作研究',
            'job_title': '方案负责人',
          });
          await tester.ensureVisible(find.text(oldName).first);
          await tester.tap(find.text(oldName).first);
          await tester.pumpAndSettle();
          expect(office.calls, contains('GET /enterprise/admin/members/$id'));
          expect(find.text('最新$targetKind成员'), findsOneWidget);
          expect(
            find.text(
              targetKind == 'agent' ? '协作总部 / 产品研发 / 体验设计' : '协作总部 / 产品研发',
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('编辑成员资料'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field('成员名称')).controller!.text,
            '最新$targetKind成员',
          );
          expect(
            tester.widget<TextField>(field('职业')).controller!.text,
            '协作研究',
          );
          await selectOption(tester, '任职组织', '运营协作组织');
          await selectOption(tester, '管理角色', '企业所有者');
          await selectOption(tester, '所属部门', '协作总部');
          await tester.tap(find.text('保存变更'));
          await tester.pumpAndSettle();
          expect(office.patches.single, containsPair('organization_id', 'ops'));
          expect(office.patches.single, containsPair('role', 'owner'));
          expect(office.patches.single, containsPair('department_id', 'root'));
          expect(office.patches.single, containsPair('base_revision', 1));
          expect(office.member(id)['kind'], targetKind);
          expect(find.text('成员详情'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Mobile organization filter and department navigation use real combined requests',
    (tester) async {
      final office = DirectoryOffice();
      final state = await mountDirectory(tester, office, const Size(390, 844));
      await selectOption(tester, '任职组织', '设计共创组织');
      expect(state.memberTotal, 3);
      expect(state.memberOrganization, 'design');
      await selectOption(tester, '账号状态', '正常');
      expect(state.memberTotal, 2);
      final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '搜索姓名、成员 ID、职业或组织',
      );
      await tester.enterText(search, '张');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(state.memberTotal, 1);
      await tester.tap(find.byTooltip('返回企业管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('部门管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('体验设计'));
      await tester.pumpAndSettle();
      expect(state.memberDepartment, 'leaf');
      expect(state.memberOrganization, isNull);
      expect(state.memberStatus, 'all');
      expect(state.memberQuery, '');
      expect(state.members.single['id'], 'member-agent');
      expect(tester.widget<TextField>(search).controller!.text, '');
      expect(find.text('共 1 位成员 · 仅展示部门直属成员'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Member CAS preserves draft through explicit latest revision adoption with mobile keyboard',
    (tester) async {
      final office = DirectoryOffice(kind: 'agent');
      await mountDirectory(tester, office, const Size(390, 844));
      await tester.ensureVisible(find.text('张同学'));
      await tester.tap(find.text('张同学'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑成员资料'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('成员名称'));
      await tester.enterText(field('成员名称'), '保留的人工成员草稿');
      await tester.ensureVisible(field('职业'));
      await tester.enterText(field('职业'), '交互设计');
      await selectOption(tester, '任职组织', '运营协作组织');
      await selectOption(tester, '管理角色', '企业管理员');
      await selectOption(tester, '所属部门', '体验设计');
      office.member('member-human').addAll({'name': '服务端另一份修改', 'revision': 2});
      await tester.tap(find.text('保存变更'));
      await tester.pumpAndSettle();
      expect(office.patches.single['base_revision'], 1);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存变更'))
            .onPressed,
        isNull,
      );
      final reload = find.text('读取最新成员资料');
      await tester.ensureVisible(reload);
      await tester.tap(reload);
      await tester.pumpAndSettle();
      expect(find.textContaining('最新版本 2：服务端另一份修改'), findsOneWidget);
      await tester.ensureVisible(find.text('保留输入并采用最新版本'));
      await tester.tap(find.text('保留输入并采用最新版本'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('成员名称')).controller!.text,
        '保留的人工成员草稿',
      );
      expect(tester.widget<TextField>(field('职业')).controller!.text, '交互设计');
      await tester.tap(find.text('保存变更'));
      await tester.pumpAndSettle();
      expect(office.patches.length, 2);
      final first = Json.from(office.patches.first)..remove('base_revision');
      final second = Json.from(office.patches.last)..remove('base_revision');
      expect(second, first);
      expect(office.patches.last['base_revision'], 2);
      expect(office.member('member-human')['name'], '保留的人工成员草稿');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Identity switch hides private detail and draft controls; admin cannot edit owner',
    (tester) async {
      final office = DirectoryOffice(role: 'admin', kind: 'agent');
      await mountDirectory(tester, office, const Size(390, 844));
      await tester.ensureVisible(find.text('Agent 企业所有者'));
      await tester.tap(find.text('Agent 企业所有者'));
      await tester.pumpAndSettle();
      expect(find.text('编辑成员资料'), findsNothing);
      await tester.tap(find.byTooltip('关闭成员详情'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('张同学'));
      await tester.tap(find.text('张同学'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑成员资料'));
      await tester.pumpAndSettle();
      await tester.enterText(field('成员名称'), '旧身份私有草稿');
      office.switchIdentity();
      await tester.pumpAndSettle();
      expect(find.text('旧身份私有草稿'), findsNothing);
      expect(find.text('保存变更'), findsNothing);
      expect(find.text('成员管理不可用'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('编辑成员资料'), findsNothing);
      expect(find.text('来源实验室'), findsNothing);
      expect(find.text('当前身份或企业权限已变化，请重新打开企业管理。'), findsOneWidget);
      expect(office.patches, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
