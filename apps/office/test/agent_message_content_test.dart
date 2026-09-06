import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/agent_message_content.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

const appendix =
    '\n\n[服务端动作回执]\nim_create_document: committed · canonical-long-resource-uuid · r1';
const content = '共同方案已整理，请继续评审。$appendix';
Json message() => {
  'id': 'message-receipt',
  'turn_id': 'turn-receipt',
  'author_id': 'agent-demo',
  'author': {'id': 'agent-demo', 'name': '协作 Agent', 'kind': 'agent'},
  'content': content,
};
Json run() => {
  'id': 'turn-receipt',
  'principal_id': 'agent-demo',
  'status': 'replied',
  'result': {
    'content': content,
    'action_summary': [
      {
        'operation_id': 'op-1',
        'operation': 'im_create_document',
        'status': 'committed',
        'resource_id': 'canonical-long-resource-uuid',
        'after_revision': 1,
        'error_code': null,
      },
    ],
  },
  'action_plan': {
    'summary': '创建共同文档',
    'steps': [
      {
        'key': 'doc',
        'operation_id': 'op-1',
        'operation': 'im_create_document',
        'arguments': {'title': '共同方案'},
      },
    ],
  },
  'action_receipts': [
    {
      'operation_id': 'op-1',
      'operation': 'im_create_document',
      'status': 'committed',
      'resource_id': 'canonical-long-resource-uuid',
      'after_revision': 1,
      'error_code': null,
      'turn_id': 'turn-receipt',
      'principal_id': 'agent-demo',
    },
  ],
};

Widget surface(
  Json message,
  List<Json> runs, {
  void Function(String)? onRecords,
}) => MaterialApp(
  theme: officeTheme(),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 270,
        child: AgentMessageContent(
          message: message,
          runs: runs,
          onRecords: onRecords ?? (_) {},
        ),
      ),
    ),
  ),
);

class ReceiptOfficeState extends LayoutOfficeState {
  ReceiptOfficeState() {
    detail!['messages'] = [
      {...message(), 'seq': 1, 'at': '2026-09-06T08:00:00Z'},
    ];
    detail!['runs'] = [run()];
  }
  String? requestedRun;
  @override
  Future<Json> getRun(String id) async {
    requestedRun = id;
    return run();
  }
}

void main() {
  testWidgets(
    'Verified appendix folds while body and actual record link remain visible',
    (tester) async {
      String? opened;
      await tester.pumpWidget(
        surface(message(), [run()], onRecords: (id) => opened = id),
      );
      expect(find.text('共同方案已整理，请继续评审。'), findsOneWidget);
      expect(find.text('已提交 1 个动作'), findsOneWidget);
      expect(find.textContaining('canonical-long-resource-uuid'), findsNothing);
      await tester.tap(find.text('查看工作记录'));
      expect(opened, 'turn-receipt');
      await tester.tap(find.text('执行原文'));
      await tester.pump();
      expect(
        find.textContaining('canonical-long-resource-uuid'),
        findsOneWidget,
      );
      await tester.tap(find.text('收起执行原文'));
      await tester.pump();
      expect(find.textContaining('canonical-long-resource-uuid'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'User markers, unknown or mismatched turns and edited results keep original text',
    (tester) async {
      final cases = <Json>[
        {
          ...message(),
          'author': {'kind': 'human'},
        },
        {...message()}..remove('turn_id'),
        {...message(), 'turn_id': 'unknown-turn'},
        {...message(), 'author_id': 'different-agent'},
        {...message(), 'content': '用户编辑过的正文$appendix'},
      ];
      for (final item in cases) {
        await tester.pumpWidget(surface(item, [run()]));
        expect(find.text(item['content']), findsOneWidget);
        expect(find.text('查看工作记录'), findsNothing);
        expect(find.text('已提交 1 个动作'), findsNothing);
      }
    },
  );

  testWidgets(
    'Bound result without matching receipts never claims committed actions',
    (tester) async {
      final missing = run()..remove('action_receipts');
      await tester.pumpWidget(surface(message(), [missing]));
      expect(find.text('执行明细'), findsOneWidget);
      expect(find.text('已提交 1 个动作'), findsNothing);
      final wrong = run();
      (wrong['action_receipts'] as List).first['principal_id'] =
          'another-agent';
      await tester.pumpWidget(surface(message(), [wrong]));
      expect(find.text('执行明细'), findsOneWidget);
      expect(find.text('已提交 1 个动作'), findsNothing);
    },
  );

  testWidgets(
    'Unconfirmed receipt stays pending and model-authored marker remains in body',
    (tester) async {
      final pendingRun = run();
      final result = pendingRun['result'] as Map;
      final text =
          '模型引用[服务端动作回执]仍是普通文字。\n\n[服务端动作回执]\nim_create_document: applying';
      result['content'] = text;
      for (final receipt in [
        ...result['action_summary'] as List,
        ...pendingRun['action_receipts'] as List,
      ]) {
        receipt['status'] = 'applying';
        receipt['resource_id'] = null;
        receipt['after_revision'] = null;
      }
      await tester.pumpWidget(
        surface({...message(), 'content': text}, [pendingRun]),
      );
      expect(find.text('模型引用[服务端动作回执]仍是普通文字。'), findsOneWidget);
      expect(find.text('1 个提交待确认'), findsOneWidget);
      expect(find.textContaining('已提交'), findsNothing);
    },
  );

  testWidgets(
    'Mobile message opens existing run dialog with authoritative receipts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = ReceiptOfficeState();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('协作测试项目').last);
      await tester.pumpAndSettle();
      expect(find.text('已提交 1 个动作'), findsOneWidget);
      expect(find.textContaining('canonical-long-resource-uuid'), findsNothing);
      await tester.tap(find.text('查看工作记录'));
      await tester.pumpAndSettle();
      expect(state.requestedRun, 'turn-receipt');
      expect(find.text('工作记录与共同依据'), findsOneWidget);
      expect(find.text('行动计划与执行回执'), findsOneWidget);
      expect(find.text('已提交'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
