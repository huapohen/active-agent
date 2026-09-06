import 'package:active_office/enterprise_state.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/enterprise_organizations.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'enterprise_ui_test.dart' show EnterpriseTestOffice;

class OrganizationsOffice extends EnterpriseTestOffice {
  final organizations = <Json>[
    {
      'id': 'design',
      'name': '设计协作组织',
      'description': '人和 Agent 的共同任职组织',
      'revision': 1,
      'member_count': 2,
    },
  ];
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
    if (path.startsWith('/enterprise/admin/organizations')) {
      calls.add('$method $path');
      if (method != 'GET') writes.add({'path': path, ...?data});
      if (method == 'GET') return {'organizations': organizations};
      if (method == 'POST') {
        final organization = <String, dynamic>{
          'id': 'new-org',
          'name': data!['name'],
          'description': data['description'],
          'revision': 1,
          'member_count': 0,
        };
        organizations.add(organization);
        return {'organization': organization};
      }
      return {'removed': true};
    }
    return super.officeRequest(path, method: method, data: data);
  }
}

void main() {
  test(
    'Member create preserves professional and current organization fields',
    () async {
      final office = OrganizationsOffice();
      final state = EnterpriseState(office);
      await state.load();
      await state.createMember(
        name: 'Agent设计师',
        kind: 'agent',
        clientId: 'stable-create-intent',
        organizationId: 'design',
        profession: '设计师',
        jobTitle: '体验负责人',
      );
      final write = office.writes.firstWhere(
        (w) => w['path'] == '/enterprise/admin/members',
      );
      expect(write['organization_id'], 'design');
      expect(write['profession'], '设计师');
      expect(write['job_title'], '体验负责人');
      expect(write['client_id'], 'stable-create-intent');
      state.dispose();
      office.dispose();
    },
  );
  testWidgets(
    'Organization form creates real record and protects nonempty organization',
    (tester) async {
      final office = OrganizationsOffice();
      final state = EnterpriseState(office);
      await state.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(body: OfficeOrganizations(controller: state)),
        ),
      );
      await tester.pumpAndSettle();
      final delete = find.byWidgetPredicate(
        (w) =>
            w is TextButton &&
            w.child is Text &&
            (w.child as Text).data == '删除空组织',
      );
      expect(tester.widget<TextButton>(delete).onPressed, isNull);
      await tester.tap(find.text('新建组织'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '组织名称',
        ),
        '产品共创组织',
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '组织说明',
        ),
        '来自两类身份的同等协作',
      );
      await tester.tap(find.text('保存组织'));
      await tester.pumpAndSettle();
      expect(find.text('产品共创组织'), findsOneWidget);
      expect(office.writes.last['client_id'], isA<String>());
      expect(office.writes.last['description'], '来自两类身份的同等协作');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      office.dispose();
    },
  );
}
