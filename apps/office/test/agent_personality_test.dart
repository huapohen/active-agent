import 'package:active_office/office_state.dart';
import 'package:active_office/ui/agent_personality.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class PersonalityOffice extends OfficeState {
  PersonalityOffice({required this.owner}) {
    connected = true;
    endpoint = 'https://personality-fixture.example';
    me = {'id': 'human', 'kind': 'human'};
    selectedRoomId = 'other';
    rooms = [
      {'id': 'other', 'name': '当前打开的群'},
      {'id': 'target', 'name': '共同项目群'},
    ];
    detail = {
      'room': {'id': 'other', 'revision': 3},
    };
  }
  final bool owner;
  final requests = <Json>[];
  final agent = <String, dynamic>{
    'principal_id': 'ordinary-agent',
    'kind': 'agent',
    'name': '普通职业同事',
    'mode': 'active',
    'autonomy': {
      'enabled': false,
      'max_steps': 2,
      'review_interval_seconds': 300,
      'allowed_operations': ['im_create_task'],
    },
    'autonomy_available_operations': ['im_create_task'],
  };

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    requests.add({'path': path, 'method': method, 'data': data});
    if (method == 'PATCH') {
      return {
        'member': {...agent, 'mode': data!['mode']},
        'room_revision': 8,
      };
    }
    return {
      'room': {
        'id': path.endsWith('target') ? 'target' : 'other',
        'revision': 7,
      },
      'members': [
        {
          'principal_id': 'human',
          'kind': 'human',
          'role': owner ? 'owner' : 'member',
        },
        if (path.endsWith('target')) agent,
      ],
    };
  }
}

void main() {
  for (final owner in [true, false]) {
    testWidgets(
      'Personality ${owner ? 'owner' : 'viewer'} selects real shared room without changing IM selection',
      (tester) async {
        final state = PersonalityOffice(owner: owner);
        await tester.pumpWidget(
          MaterialApp(
            theme: officeTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showAgentPersonality(context, state, state.agent),
                  child: const Text('人格入口'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('人格入口'));
        await tester.pumpAndSettle();
        expect(
          find.text('这位 Agent 尚未加入该会话。可以选择其他会话，或先在会话成员中邀请。'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, '打开会话人格配置'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('共同项目群').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开会话人格配置'));
        await tester.pumpAndSettle();
        final active = find.widgetWithText(SwitchListTile, '主动参与');
        expect(
          tester.widget<SwitchListTile>(active).onChanged,
          owner ? isNotNull : isNull,
        );
        if (owner) {
          await tester.ensureVisible(active);
          await tester.pumpAndSettle();
          await tester.tap(active);
          await tester.pumpAndSettle();
          expect(state.requests.last, {
            'path': '/rooms/target/participation',
            'method': 'PATCH',
            'data': {
              'principal_id': 'ordinary-agent',
              'base_revision': 7,
              'mode': 'mentions',
            },
          });
        } else {
          expect(
            state.requests.where((request) => request['method'] == 'PATCH'),
            isEmpty,
          );
        }
        expect(state.selectedRoomId, 'other');
        expect(state.detail!['room']['revision'], 3);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }
}
