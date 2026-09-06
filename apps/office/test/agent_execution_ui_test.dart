import 'package:active_office/office_state.dart';
import 'package:active_office/ui/agent_action_plan.dart';
import 'package:active_office/ui/agent_autonomy.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class AutonomyOffice extends OfficeState {
  AutonomyOffice() {
    connected = true;
    endpoint = 'https://autonomy-fixture.example';
    me = {'id': 'human-test', 'kind': 'human'};
    selectedRoomId = 'room-test';
    detail = {
      'room': {'id': 'room-test', 'revision': 4},
    };
  }
  Json member = {
    'principal_id': 'agent-test',
    'name': '执行同事',
    'kind': 'agent',
    'mode': 'active',
    'autonomy': {
      'enabled': true,
      'max_steps': 4,
      'review_interval_seconds': 300,
      'allowed_operations': ['im_create_task'],
    },
    'autonomy_available_operations': ['im_create_task', 'im_update_task'],
  };
  int? revision;
  Json? saved;
  final participationWrites = <Json>[];
  @override
  Future<Json> configureAgentParticipation(
    String roomId,
    String principalId, {
    required String mode,
    required int baseRevision,
  }) async {
    participationWrites.add({
      'room_id': roomId,
      'principal_id': principalId,
      'mode': mode,
      'base_revision': baseRevision,
    });
    return {
      'member': {...member, 'mode': mode},
      'room_revision': baseRevision + 1,
    };
  }

  @override
  Future<Json> configureAgentAutonomy(
    String roomId,
    String principalId, {
    required int baseRevision,
    required Json autonomy,
  }) async {
    if (baseRevision == 4) throw OfficeException(409, '共同版本已变化');
    revision = baseRevision;
    saved = autonomy;
    return {
      'member': {...member, 'autonomy': autonomy},
      'room_revision': 6,
    };
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async => {
    'room': {'id': 'room-test', 'revision': 5},
    'members': [
      {
        ...member,
        'autonomy': {
          'enabled': false,
          'max_steps': 2,
          'review_interval_seconds': 600,
          'allowed_operations': ['im_create_task'],
        },
      },
    ],
  };
}

void main() {
  testWidgets(
    'Participation switches save actual scoped modes independently of action autonomy',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = AutonomyOffice();
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAgentAutonomy(
                  context,
                  state,
                  state.member,
                  roomId: 'room-test',
                  canEdit: true,
                ),
                child: const Text('人格'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('人格'));
      await tester.pumpAndSettle();
      final active = find.widgetWithText(SwitchListTile, '主动参与');
      await tester.ensureVisible(active);
      await tester.tap(active);
      await tester.pumpAndSettle();
      expect(state.participationWrites.last, {
        'room_id': 'room-test',
        'principal_id': 'agent-test',
        'mode': 'mentions',
        'base_revision': 4,
      });
      expect(tester.widget<SwitchListTile>(active).value, isFalse);
      await tester.tap(find.text('暂停参与'));
      await tester.pumpAndSettle();
      expect(state.participationWrites.last['mode'], 'paused');
      expect(tester.widget<SwitchListTile>(active).onChanged, isNull);
      await tester.tap(find.text('恢复参与（被提及时）'));
      await tester.pumpAndSettle();
      expect(state.participationWrites.last['mode'], 'mentions');
      await tester.tap(active);
      await tester.pumpAndSettle();
      expect(state.participationWrites.last['mode'], 'active');
      expect(state.saved, isNull);
      await tester.tap(find.text('保存主动性策略'));
      await tester.pumpAndSettle();
      expect(state.saved?['enabled'], isTrue);
      expect(state.revision, 8);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'Cancelled turn retains committed receipts and pending document outcomes',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: AgentActionPlan(
                run: {
                  'status': 'cancelled',
                  'result': {'rationale': '我已经完成所有操作'},
                  'action_plan': {
                    'summary': '共同工作计划',
                    'steps': [
                      {
                        'operation_id': 'one',
                        'operation': 'im_create_task',
                        'arguments': {'title': '真实任务'},
                      },
                      {
                        'operation_id': 'two',
                        'operation': 'office_create_event',
                      },
                      {'operation_id': 'three', 'operation': 'im_add_contact'},
                      {
                        'operation_id': 'four',
                        'operation': 'im_create_document',
                      },
                    ],
                  },
                  'action_receipts': [
                    {
                      'operation_id': 'one',
                      'operation': 'im_create_task',
                      'status': 'committed',
                      'resource_id': 'task-real',
                      'after_revision': 1,
                    },
                    {
                      'operation_id': 'two',
                      'operation': 'office_create_event',
                      'status': 'rejected',
                      'error_code': 'revision_conflict',
                    },
                    {
                      'operation_id': 'four',
                      'operation': 'im_create_document',
                      'status': 'applying',
                      'error_code': 'outcome_pending',
                    },
                  ],
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已提交'), findsOneWidget);
      expect(find.text('已拒绝'), findsOneWidget);
      expect(find.text('未执行'), findsOneWidget);
      expect(find.text('提交待确认'), findsOneWidget);
      expect(find.text('共同版本：r1'), findsOneWidget);
      expect(find.text('我已经完成所有操作'), findsNothing);
      expect(find.text('执行'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Autonomy conflict preserves edits and explicitly adopts latest revision',
    (tester) async {
      final state = AutonomyOffice();
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAgentAutonomy(
                  context,
                  state,
                  state.member,
                  roomId: 'room-test',
                  canEdit: true,
                ),
                child: const Text('打开策略'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开策略'));
      await tester.pumpAndSettle();
      expect(find.text('创建共同文档'), findsNothing);
      final interval = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '主动复核间隔（秒）',
      );
      await tester.enterText(interval, '900');
      await tester.tap(find.text('保存主动性策略'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(interval).controller!.text, '900');
      final merge = find.widgetWithText(TextButton, '读取最新策略并保留编辑');
      await tester.ensureVisible(merge);
      await tester.pumpAndSettle();
      await tester.tap(merge);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(interval).controller!.text, '900');
      await tester.tap(find.text('保存主动性策略'));
      await tester.pumpAndSettle();
      expect(state.revision, 5);
      expect(state.saved?['review_interval_seconds'], 900);
      expect(state.saved?['enabled'], true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
