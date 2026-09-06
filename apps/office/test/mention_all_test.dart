import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/conversation.dart';
import 'package:active_office/ui/mentions.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'office_state_test.dart' show Service;
import 'office_ui_test.dart' show LayoutOfficeState;

const mentionPeople = <Json>[
  {'id': 'human-1', 'name': '人类同事', 'kind': 'human'},
  {'id': 'agent-1', 'name': 'Agent 同事', 'kind': 'agent'},
];

class MentionOffice extends LayoutOfficeState {
  MentionOffice({super.kind = 'human'}) {
    endpoint = 'https://mention-all-${counter++}.example';
  }
  static int counter = 0;
  int generation = 0, failures = 0;
  final sends = <Json>[];
  Completer<Json>? pendingSend;
  @override
  int get identityGeneration => generation;
  void changeRoom(String id, {bool direct = false}) {
    final room = {'id': id, 'name': id, 'kind': direct ? 'direct' : 'group'};
    if (!rooms.any((room) => room['id'] == id)) rooms.add(room);
    selectedRoomId = id;
    detail = {...?detail, 'room': room, 'messages': <Json>[]};
    notifyListeners();
  }

  void changeIdentity({bool same = false}) {
    generation++;
    if (!same) me = {'id': 'another-person', 'name': '新身份', 'kind': 'agent'};
    notifyListeners();
  }

  @override
  Future<Json> send(
    String content, {
    List<String> mentions = const [],
    bool mentionAll = false,
    String? sourceRoomId,
    String? replyTo,
    String? clientId,
    List<String> attachmentIds = const [],
  }) async {
    sends.add({
      'content': content,
      'mentions': [...mentions],
      'mention_all': mentionAll,
      'source_room_id': sourceRoomId,
      'client_id': clientId,
    });
    if (failures > 0) {
      failures--;
      throw OfficeException(503, '发送结果暂未确认，请重试');
    }
    final pending = pendingSend;
    pendingSend = null;
    return pending == null ? {'id': 'sent'} : pending.future;
  }
}

Future<void> mountConversation(WidgetTester tester, MentionOffice state) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: state,
          builder: (_, _) => OfficeConversation(state: state, mobile: true),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder composer() => find.widgetWithText(TextField, '发送消息，或 @ 工作伙伴共同推进');
Future<void> openMentions(WidgetTester tester) async {
  await tester.tap(find.byTooltip('提及成员'));
  await tester.pumpAndSettle();
}

Future<void> selectAllAndAgent(WidgetTester tester) async {
  await openMentions(tester);
  await tester.tap(find.byKey(const ValueKey('mention-all-choice')));
  await tester.tap(find.byKey(const ValueKey('mention-person-agent-demo')));
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

Future<void> sendComposer(WidgetTester tester) async {
  await tester.ensureVisible(find.text('发送'));
  await tester.tap(find.text('发送'));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'old drafts retain explicit IDs without guessing an everyone mention',
    () {
      final old = OfficeMentionSelection.fromDraft({
        'mentions': ['human-1', 'agent-1'],
      }, group: true);
      expect(old.selectedIds, ['human-1', 'agent-1']);
      expect(old.mentionAll, false);
      final group = OfficeMentionSelection.fromDraft({
        'mentions': ['agent-1'],
        'mention_all': true,
      }, group: true);
      expect(group.mentionAll, true);
      expect(group.selectedIds, ['agent-1']);
      expect(
        OfficeMentionSelection.fromDraft({
          'mentions': ['agent-1'],
          'mention_all': true,
        }, group: false).mentionAll,
        false,
      );
    },
  );

  for (final group in [true, false]) {
    testWidgets(
      '${group ? 'group' : 'direct'} picker separates explicit members from mentionAll',
      (tester) async {
        OfficeMentionSelection? selection;
        await tester.pumpWidget(
          MaterialApp(
            theme: officeTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    selection = await showDialog<OfficeMentionSelection>(
                      context: context,
                      builder: (_) => OfficeMentionPicker(
                        people: mentionPeople,
                        selected: const ['human-1', 'agent-1'],
                        mentionAll: !group,
                        mobile: true,
                        group: group,
                      ),
                    );
                  },
                  child: const Text('选择'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('选择'));
        await tester.pumpAndSettle();
        if (group) {
          expect(
            tester
                .widget<CheckboxListTile>(
                  find.byKey(const ValueKey('mention-all-choice')),
                )
                .value,
            false,
          );
          await tester.tap(find.byKey(const ValueKey('mention-all-choice')));
        } else {
          expect(
            find.byKey(const ValueKey('mention-all-choice')),
            findsNothing,
          );
        }
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(selection?.selectedIds, ['human-1', 'agent-1']);
        expect(selection?.mentionAll, group);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final kind in ['human', 'agent']) {
    test(
      '$kind sends mention_all separately and retries identical intent with one client ID',
      () async {
        final service = Service(kind)..loseFirstSend = true;
        final office = OfficeState(client: MockClient(service.call));
        await office.connect(
          'https://mentions-fixture.example',
          'private-test-identity',
        );
        await expectLater(
          office.send('共同交付', mentions: ['peer'], mentionAll: true),
          throwsA(isA<OfficeException>()),
        );
        await office.send('共同交付', mentions: ['peer'], mentionAll: true);
        expect(service.bodies[0]['client_id'], service.bodies[1]['client_id']);
        expect(service.bodies[1]['mention_all'], true);
        expect(service.bodies[1]['mentions'], ['peer']);
        await office.send('共同交付', mentions: ['peer'], mentionAll: false);
        expect(service.bodies.last['mention_all'], false);
        expect(
          service.bodies.last['client_id'],
          isNot(service.bodies.first['client_id']),
        );
        office.disconnect();
        office.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 130));
      },
    );
  }

  test('native send rejects everyone in direct rooms and keeps explicit source room', () async {
    final service = Service('human');
    final office = OfficeState(client: MockClient(service.call));
    await office.connect(
      'https://source-room-fixture.example',
      'private-test-identity',
    );
    office.detail!['room'] = {'id': 'room-1', 'kind': 'direct'};
    await expectLater(
      office.send('单聊消息', mentionAll: true),
      throwsA(
        isA<OfficeException>().having(
          (error) => error.code,
          'code',
          'group_required',
        ),
      ),
    );
    expect(service.bodies, isEmpty);
    office.selectedRoomId = 'different-selection';
    office.detail = null;
    await office.send(
      '原群发送',
      mentions: ['peer'],
      mentionAll: true,
      sourceRoomId: 'room-1',
    );
    expect(service.bodies.single['mention_all'], true);
    office.disconnect();
    office.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 130));
  });

  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind composer preserves everyone plus explicit Agent across failed retries',
      (tester) async {
        final state = MentionOffice(kind: kind)..failures = 2;
        await mountConversation(tester, state);
        await selectAllAndAgent(tester);
        expect(
          find.byKey(const ValueKey('composer-mention-all')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('composer-mention-agent-demo')),
          findsOneWidget,
        );
        await tester.enterText(composer(), '请大家核对，Agent 请明确跟进');
        await sendComposer(tester);
        await sendComposer(tester);
        expect(state.sends[0]['client_id'], state.sends[1]['client_id']);
        expect(state.sends[1]['mention_all'], true);
        expect(state.sends[1]['mentions'], ['agent-demo']);
        final chip = find.byKey(const ValueKey('composer-mention-all'));
        await tester.tap(
          find.descendant(of: chip, matching: find.byIcon(Icons.close)),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('composer-mention-agent-demo')),
          findsOneWidget,
        );
        await sendComposer(tester);
        expect(state.sends.last['mention_all'], false);
        expect(state.sends.last['mentions'], ['agent-demo']);
        expect(
          state.sends.last['client_id'],
          isNot(state.sends.first['client_id']),
        );
        expect(
          state.sends.every((send) => send['source_room_id'] == 'room-demo'),
          true,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'room change preserves independent drafts and invalidates an open mention picker',
    (tester) async {
      final state = MentionOffice();
      await mountConversation(tester, state);
      await selectAllAndAgent(tester);
      await tester.enterText(composer(), '原群草稿');
      state.changeRoom('room-b');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-mention-all')), findsNothing);
      await tester.enterText(composer(), '新群草稿');
      await openMentions(tester);
      state.changeRoom('room-demo');
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMentionPicker), findsNothing);
      expect(find.text('会话已变化'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('原群草稿'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-mention-all')),
        findsOneWidget,
      );
      state.changeRoom('room-b');
      await tester.pumpAndSettle();
      expect(find.text('新群草稿'), findsOneWidget);
      expect(find.byKey(const ValueKey('composer-mention-all')), findsNothing);
    },
  );

  testWidgets(
    'identity generation change locks picker and never adopts old selection',
    (tester) async {
      final state = MentionOffice();
      await mountConversation(tester, state);
      await openMentions(tester);
      await tester.tap(find.byKey(const ValueKey('mention-all-choice')));
      state.changeIdentity(same: true);
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMentionPicker), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-mention-all')), findsNothing);
      expect(state.sends, isEmpty);
    },
  );

  testWidgets(
    'late send acknowledgement clears only unchanged source draft and preserves destination',
    (tester) async {
      final state = MentionOffice();
      final pending = Completer<Json>();
      state.pendingSend = pending;
      await mountConversation(tester, state);
      await selectAllAndAgent(tester);
      await tester.enterText(composer(), '原群待确认');
      await tester.tap(find.text('发送'));
      await tester.pump();
      state.changeRoom('room-b');
      await tester.pumpAndSettle();
      await tester.enterText(composer(), '新群正在编辑');
      pending.complete({'id': 'sent'});
      await tester.pumpAndSettle();
      expect(find.text('新群正在编辑'), findsOneWidget);
      expect(state.sends.single['source_room_id'], 'room-demo');
      state.changeRoom('room-demo');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);
      expect(find.byKey(const ValueKey('composer-mention-all')), findsNothing);
    },
  );

  testWidgets(
    'late send from a previous identity cannot clear the new identity draft',
    (tester) async {
      final state = MentionOffice();
      final pending = Completer<Json>();
      state.pendingSend = pending;
      await mountConversation(tester, state);
      await selectAllAndAgent(tester);
      await tester.enterText(composer(), '旧身份的群体提及');
      await tester.tap(find.text('发送'));
      await tester.pump();
      state.changeIdentity();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-mention-all')), findsNothing);
      await tester.enterText(composer(), '新身份自己的草稿');
      pending.complete({'id': 'old-identity-message'});
      await tester.pumpAndSettle();
      expect(find.text('新身份自己的草稿'), findsOneWidget);
      expect(state.sends.single['mention_all'], true);
      expect(find.byKey(const ValueKey('composer-mention-all')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'message bubbles use explicit flag and never infer everyone from all IDs',
    (tester) async {
      final state = MentionOffice();
      final source = Map<String, dynamic>.from(
        (state.detail!['messages'] as List).single,
      );
      state.detail!['messages'] = [
        {
          ...source,
          'id': 'legacy',
          'mentions': ['me', 'agent-demo'],
        },
        {
          ...source,
          'id': 'everyone',
          'mention_all': true,
          'mention_all_ids': ['me', 'agent-demo'],
          'mentions': ['agent-demo'],
        },
      ];
      await mountConversation(tester, state);
      expect(
        find.byKey(const ValueKey('message-mention-all-legacy')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('message-mention-all-everyone')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('message-mention-everyone-agent-demo')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('message-mention-legacy-me')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
