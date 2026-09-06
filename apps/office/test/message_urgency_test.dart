import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_urgency.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class UrgencyOffice extends OfficeState {
  UrgencyOffice({String id = 'sender', String kind = 'human'}) {
    endpoint = 'https://urgency.invalid';
    me = {'id': id, 'name': id == 'sender' ? '发起者' : '接收人', 'kind': kind};
    selectedRoomId = 'r';
    connected = true;
  }
  int generation = 0;
  @override
  int get identityGeneration => generation;
  void changeIdentity() {
    generation++;
    notifyListeners();
  }

  final requests = <Json>[];
  final creates = <String, Json>{};
  Json source = {
    'id': 'm',
    'room_id': 'r',
    'author_id': 'sender',
    'content': '请确认交付时间',
    'revision': 2,
  };
  List<Json> members = [
    {'principal_id': 'sender', 'name': '发起者', 'kind': 'human'},
    {'principal_id': 'h1', 'name': '林同事', 'kind': 'human'},
    {'principal_id': 'a1', 'name': '机伴', 'kind': 'agent'},
  ];
  bool commitThenFail = false,
      leakOthers = false,
      acknowledged = false,
      pagination = false;
  String sourceStatus = 'current', status = 'pending';
  bool canAck = true;
  Completer<Json>? pendingPost, pendingDetail, pendingReaders;
  OfficeException? ackFailure, readerFailure, sourceFailure, createFailure;
  Json reading = {
    'message_id': 'm',
    'receipt_summary': {'known': true, 'basis': 'explicit_read_ack'},
    'readers': <Json>[
      {
        'principal_id': 'h1',
        'status': 'read',
        'read': true,
        'current_member': true,
        'same_membership': true,
      },
      {
        'principal_id': 'a1',
        'status': 'unread',
        'read': false,
        'current_member': true,
        'same_membership': true,
      },
    ],
  };
  Json copy(Json value) => Json.from(jsonDecode(jsonEncode(value)) as Map);
  Json urgency({String id = 'u1', int seq = 10}) {
    final sender = me!['id'] == 'sender';
    final recipients = [
      for (final member in members.where((m) => m['principal_id'] != 'sender'))
        if (sender || leakOthers || member['principal_id'] == me!['id'])
          {
            'principal_id': member['principal_id'],
            'name': member['name'],
            'kind': member['kind'],
            'status': acknowledged && member['principal_id'] == me!['id']
                ? 'acknowledged'
                : 'pending',
            'acknowledged_at':
                acknowledged && member['principal_id'] == me!['id']
                ? '2026-09-06T00:10:00Z'
                : null,
            'current_member': true,
            'same_membership': true,
          },
    ];
    return {
      'id': id,
      'seq': seq,
      'room_id': 'r',
      'message_id': 'm',
      'message_revision': 2,
      'channel': 'in_app',
      'created_by': 'sender',
      'created_at': '2026-09-06T00:00:00Z',
      'revision': 1,
      'status': acknowledged ? 'acknowledged' : status,
      'source_status': sourceStatus,
      'message': sourceStatus == 'missing' ? null : copy(source),
      'recipients': recipients,
      'counts': {
        'total': 99,
        'pending': 99,
        'acknowledged': 0,
        'unavailable': 0,
      },
      'summary_scope': sender ? 'sender' : 'self',
      'can_ack': !sender && canAck && !acknowledged,
    };
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    requests.add({
      'path': path,
      'method': method,
      'data': data == null ? null : copy(data),
    });
    if (path == '/rooms/r') {
      return {
        'room': {'id': 'r'},
        'members': members.map(copy).toList(),
      };
    }
    if (path == '/rooms/r/messages/m') {
      if (sourceFailure != null) {
        final failure = sourceFailure!;
        sourceFailure = null;
        throw failure;
      }
      return {'message': copy(source)};
    }
    if (path == '/rooms/r/messages/m/readers') {
      expect(method, 'GET');
      if (readerFailure != null) {
        final failure = readerFailure!;
        readerFailure = null;
        throw failure;
      }
      return pendingReaders?.future ?? copy(reading);
    }
    if (path == '/rooms/r/messages/m/urgencies') {
      expect(method, 'POST');
      if (createFailure != null) {
        final failure = createFailure!;
        createFailure = null;
        throw failure;
      }
      if (pendingPost != null) return pendingPost!.future;
      final client = data!['client_id'] as String;
      final duplicate = creates.containsKey(client);
      creates.putIfAbsent(client, () => urgency());
      if (commitThenFail) {
        commitThenFail = false;
        throw OfficeException(503, '响应在提交后中断');
      }
      return {'urgency': copy(creates[client]!), 'duplicate': duplicate};
    }
    if (path.endsWith('/ack')) {
      if (ackFailure != null) {
        final failure = ackFailure!;
        ackFailure = null;
        throw failure;
      }
      expect(method, 'POST');
      expect(data, isEmpty);
      acknowledged = true;
      return {'urgency': urgency()};
    }
    if (path.startsWith('/rooms/r/urgencies?')) {
      final uri = Uri.parse(path);
      expect(uri.queryParameters['limit'], '50');
      if (pagination && uri.queryParameters['before'] == null) {
        return {
          'items': [urgency(id: 'u3', seq: 30)],
          'has_more': true,
          'next_before': 30,
        };
      }
      return {
        'items': [urgency(id: pagination ? 'u2' : 'u1', seq: 20)],
        'has_more': false,
        'next_before': null,
      };
    }
    if (path == '/rooms/r/urgencies/u1') {
      return pendingDetail?.future ?? {'urgency': urgency()};
    }
    throw StateError('Unexpected transport: $method $path');
  }
}

Future<void> mount(
  WidgetTester tester,
  Widget child, {
  double width = 550,
}) async {
  tester.view.physicalSize = Size(width, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapVisible(
  WidgetTester tester,
  Finder finder, {
  bool settle = true,
}) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> composer(
  WidgetTester tester,
  UrgencyOffice state, {
  double width = 550,
}) => mount(
  tester,
  OfficeMessageUrgencyComposer(state: state, roomId: 'r', messageId: 'm'),
  width: width,
);
Finder recipient(String id) => find.byKey(ValueKey('urgency-recipient-$id'));
Finder send() => find.byKey(const ValueKey('urgency-send'));

void main() {
  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind author selects actual Human and Agent room members and sends only in-app',
      (tester) async {
        final state = UrgencyOffice(kind: kind);
        addTearDown(state.dispose);
        state.principals = [
          {'id': 'stranger', 'name': '商店陌生人'},
        ];
        await composer(tester, state, width: 390);
        expect(recipient('sender'), findsNothing);
        expect(recipient('stranger'), findsNothing);
        expect(recipient('h1'), findsOneWidget);
        expect(recipient('a1'), findsOneWidget);
        expect(
          tester
              .widget<RadioListTile<String>>(
                find.byKey(const ValueKey('urgency-channel-sms')),
              )
              .enabled,
          isFalse,
        );
        expect(
          tester
              .widget<RadioListTile<String>>(
                find.byKey(const ValueKey('urgency-channel-phone')),
              )
              .enabled,
          isFalse,
        );
        await tapVisible(tester, recipient('h1'));
        await tapVisible(tester, recipient('a1'));
        await tapVisible(tester, send());
        final post = state.requests.singleWhere((r) => r['method'] == 'POST');
        final data = post['data'] as Map;
        expect(data.keys.toSet(), {
          'client_id',
          'base_revision',
          'recipient_ids',
          'channel',
        });
        expect(data['channel'], 'in_app');
        expect(data['base_revision'], 2);
        expect(data['recipient_ids'], ['h1', 'a1']);
        expect((data['client_id'] as String).isNotEmpty, isTrue);
        expect(find.text('加急已发出'), findsOneWidget);
        expect(find.text('0 已确认 · 2 待确认'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'select unread uses actual receipt evidence and current membership',
    (tester) async {
      final state = UrgencyOffice();
      addTearDown(state.dispose);
      for (final id in ['left', 'rejoined', 'new', 'unknown']) {
        state.members.add({'principal_id': id, 'name': id, 'kind': 'human'});
      }
      (state.reading['readers'] as List).addAll(<Json>[
        {
          'principal_id': 'left',
          'status': 'unread',
          'read': false,
          'current_member': false,
          'same_membership': false,
        },
        {
          'principal_id': 'rejoined',
          'status': 'unread',
          'read': false,
          'current_member': true,
          'same_membership': false,
        },
        {
          'principal_id': 'unknown',
          'status': 'unknown',
          'read': false,
          'current_member': true,
          'same_membership': true,
        },
        {
          'principal_id': 'outsider',
          'status': 'unread',
          'read': false,
          'current_member': true,
          'same_membership': true,
        },
      ]);
      await composer(tester, state, width: 390);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('urgency-select-unread')),
      );
      expect(tester.widget<CheckboxListTile>(recipient('a1')).value, isTrue);
      for (final id in ['h1', 'left', 'rejoined', 'new', 'unknown']) {
        expect(tester.widget<CheckboxListTile>(recipient(id)).value, isFalse);
      }
      await tester.drag(find.byType(ListView), const Offset(0, 800));
      await tester.pumpAndSettle();
      expect(find.text('选择接收成员 · 已选 1 人'), findsOneWidget);
      expect(state.requests.where((r) => r['method'] != 'GET'), isEmpty);
      await tapVisible(tester, send());
      expect((state.requests.last['data'] as Map)['recipient_ids'], ['a1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unknown and failed reading never invent unread and can retry', (
    tester,
  ) async {
    final state = UrgencyOffice();
    addTearDown(state.dispose);
    state.reading['receipt_summary'] = {
      'known': false,
      'basis': 'legacy_unknown',
    };
    await composer(tester, state);
    final unread = find.byKey(const ValueKey('urgency-select-unread'));
    await tapVisible(tester, unread);
    expect(find.textContaining('阅读状态未知'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(recipient('a1')).value, isFalse);
    expect(tester.widget<FilledButton>(send()).onPressed, isNull);
    state.readerFailure = OfficeException(503, '暂不可用');
    await tapVisible(tester, unread);
    expect(find.textContaining('未读成员读取失败'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(recipient('a1')).value, isFalse);
    state.reading['receipt_summary'] = {
      'known': true,
      'basis': 'explicit_read_ack',
    };
    await tapVisible(tester, unread);
    expect(tester.widget<CheckboxListTile>(recipient('a1')).value, isTrue);
    expect(state.requests.where((r) => r['method'] != 'GET'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late unread response cannot select recipients in a new identity',
    (tester) async {
      final state = UrgencyOffice()..pendingReaders = Completer<Json>();
      addTearDown(state.dispose);
      await composer(tester, state);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('urgency-select-unread')),
        settle: false,
      );
      state.changeIdentity();
      await tester.pump();
      state.pendingReaders!.complete(state.copy(state.reading));
      await tester.pumpAndSettle();
      expect(recipient('a1'), findsNothing);
      expect(find.text('工作身份或来源会话已变化，请关闭后重新打开加急。'), findsOneWidget);
      expect(state.requests.where((r) => r['method'] != 'GET'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unconfigured channels stay disabled and desktop shortcut sends only selected in-app request',
    (tester) async {
      final state = UrgencyOffice();
      addTearDown(state.dispose);
      await composer(tester, state, width: 1000);
      expect(tester.widget<FilledButton>(send()).onPressed, isNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(state.requests.where((r) => r['method'] == 'POST'), isEmpty);
      await tapVisible(tester, recipient('h1'));
      for (final id in ['sms', 'phone']) {
        final channel = find.byKey(ValueKey('urgency-channel-$id'));
        await tapVisible(tester, channel);
        expect(tester.widget<RadioListTile<String>>(channel).enabled, isFalse);
      }
      await tester.tap(find.byKey(const ValueKey('urgency-member-search')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      final post = state.requests.singleWhere((r) => r['method'] == 'POST');
      expect((post['data'] as Map)['channel'], 'in_app');
      expect((post['data'] as Map)['recipient_ids'], ['h1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('non-author cannot create urgency', (tester) async {
    final state = UrgencyOffice(id: 'h1');
    addTearDown(state.dispose);
    await composer(tester, state);
    expect(find.text('只能为自己发送的消息发起加急'), findsOneWidget);
    expect(tester.widget<FilledButton>(send()).onPressed, isNull);
    expect(state.requests.where((r) => r['method'] == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'withdrawn source cannot create urgency or keep its stale preview',
    (tester) async {
      final state = UrgencyOffice();
      addTearDown(state.dispose);
      state.source['retracted_at'] = '2026-09-06T00:00:01Z';
      await composer(tester, state);
      expect(find.text('来源消息已删除或撤回，不能发起加急'), findsOneWidget);
      expect(find.text('请确认交付时间'), findsNothing);
      expect(tester.widget<FilledButton>(send()).onPressed, isNull);
      expect(state.requests.where((r) => r['method'] == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source or membership change requires reviewing before a new request',
    (tester) async {
      final state = UrgencyOffice();
      addTearDown(state.dispose);
      await composer(tester, state);
      await tapVisible(tester, recipient('h1'));
      state.source['revision'] = 3;
      state.source['content'] = '更新后的确认内容';
      await tapVisible(tester, send());
      expect(find.text('来源消息已更新，请检查新内容后重新发送。'), findsOneWidget);
      expect(state.requests.where((r) => r['method'] == 'POST'), isEmpty);
      state.members.removeWhere((m) => m['principal_id'] == 'h1');
      await tapVisible(tester, send());
      expect(find.text('接收成员已变化，请检查选择后重新发送。'), findsOneWidget);
      expect(tester.widget<FilledButton>(send()).onPressed, isNull);
      expect(state.requests.where((r) => r['method'] == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'uncertain committed send reuses the same client ID and exact recipients after reopening',
    (tester) async {
      final state = UrgencyOffice()..commitThenFail = true;
      addTearDown(state.dispose);
      await composer(tester, state);
      await tapVisible(tester, recipient('a1'));
      await tapVisible(tester, send());
      expect(find.textContaining('发送结果尚未确认'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(recipient('a1')).onChanged,
        isNull,
      );
      final first = state.requests.last['data'];
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await composer(tester, state);
      expect(find.text('重试确认同一次发送'), findsOneWidget);
      await tapVisible(tester, send());
      final posts = state.requests.where((r) => r['method'] == 'POST').toList();
      expect(posts.length, 2);
      expect(posts[1]['data'], first);
      expect(state.creates.length, 1);
      expect(find.text('加急已发出'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity turnover clears recipient drafts and discards late create result',
    (tester) async {
      final state = UrgencyOffice()..pendingPost = Completer<Json>();
      addTearDown(state.dispose);
      await composer(tester, state);
      await tapVisible(tester, recipient('h1'));
      await tapVisible(tester, send(), settle: false);
      state.changeIdentity();
      await tester.pump();
      state.pendingPost!.complete({
        'urgency': state.urgency(),
        'duplicate': false,
      });
      await tester.pumpAndSettle();
      expect(find.text('加急已发出'), findsNothing);
      expect(recipient('h1'), findsNothing);
      expect(find.text('工作身份或来源会话已变化，请关闭后重新打开加急。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [('preflight', 403), ('post', 404)]) {
    testWidgets(
      'denied ${scenario.$1} clears composer source and member draft',
      (tester) async {
        final state = UrgencyOffice();
        addTearDown(state.dispose);
        await composer(tester, state);
        await tapVisible(tester, recipient('h1'));
        final retained = tester.widget<FilledButton>(send()).onPressed!;
        if (scenario.$1 == 'preflight') {
          state.sourceFailure = OfficeException(scenario.$2, '成员访问权限已撤销');
        } else {
          state.createFailure = OfficeException(scenario.$2, '来源消息已不可见');
        }
        await tapVisible(tester, send());
        expect(find.text('请确认交付时间'), findsNothing);
        expect(recipient('h1'), findsNothing);
        expect(recipient('a1'), findsNothing);
        expect(find.text('选择接收成员 · 已选 0 人'), findsOneWidget);
        expect(tester.widget<FilledButton>(send()).onPressed, isNull);
        final calls = state.requests.length;
        retained();
        await tester.pumpAndSettle();
        expect(state.requests.length, calls);
        expect(state.creates, isEmpty);
        await tapVisible(tester, find.text('重新核对来源与成员'));
        expect(recipient('h1'), findsOneWidget);
        expect(tester.widget<CheckboxListTile>(recipient('h1')).value, isFalse);
        expect(tester.widget<FilledButton>(send()).onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind recipient GET never acknowledges; explicit button posts only own ack',
      (tester) async {
        final id = kind == 'agent' ? 'a1' : 'h1';
        final state = UrgencyOffice(id: id, kind: kind);
        addTearDown(state.dispose);
        await mount(
          tester,
          OfficeMessageUrgencyDetail(
            state: state,
            roomId: 'r',
            urgencyId: 'u1',
          ),
        );
        expect(state.requests.map((r) => r['method']), ['GET']);
        expect(find.text('仅展示你的确认状态'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('urgency-acknowledge')),
        );
        expect(state.requests.last, {
          'path': '/rooms/r/urgencies/u1/ack',
          'method': 'POST',
          'data': {},
        });
        expect(find.byKey(const ValueKey('urgency-acknowledge')), findsNothing);
        expect(find.text('已确认'), findsWidgets);
        expect(
          state.requests.any(
            (r) => (r['path'] as String).contains('/personal'),
          ),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'recipient view cannot reveal another target or sender-wide totals',
    (tester) async {
      final state = UrgencyOffice(id: 'h1')..leakOthers = true;
      addTearDown(state.dispose);
      await mount(
        tester,
        OfficeMessageUrgencyDetail(state: state, roomId: 'r', urgencyId: 'u1'),
      );
      expect(find.text('林同事'), findsOneWidget);
      expect(find.text('机伴'), findsNothing);
      expect(find.textContaining('99'), findsNothing);
      expect(find.text('仅展示你的确认状态'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in [
    'changed',
    'missing',
    'hidden',
    'sender_unavailable',
  ]) {
    testWidgets(
      '$invalid request cannot be acknowledged and never renders stale hidden content',
      (tester) async {
        final state = UrgencyOffice(id: 'h1');
        addTearDown(state.dispose);
        if (invalid == 'sender_unavailable') {
          state.status = invalid;
          state.canAck = false;
        } else {
          state.sourceStatus = invalid;
          state.status = 'source_$invalid';
        }
        if (invalid == 'hidden') state.source['hidden'] = true;
        await mount(
          tester,
          OfficeMessageUrgencyDetail(
            state: state,
            roomId: 'r',
            urgencyId: 'u1',
          ),
        );
        expect(find.byKey(const ValueKey('urgency-acknowledge')), findsNothing);
        if (invalid == 'hidden' || invalid == 'missing') {
          expect(find.text('请确认交付时间'), findsNothing);
        }
        expect(state.requests.where((r) => r['method'] == 'POST'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'room urgency list paginates with decreasing sequence and filters sent requests',
    (tester) async {
      final state = UrgencyOffice()..pagination = true;
      addTearDown(state.dispose);
      await mount(
        tester,
        OfficeRoomUrgencies(state: state, roomId: 'r'),
        width: 390,
      );
      expect(find.byKey(const ValueKey('urgency-item-u3')), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('urgency-load-more')));
      expect(find.byKey(const ValueKey('urgency-item-u2')), findsOneWidget);
      expect(
        Uri.parse(state.requests.last['path'] as String)
            .queryParameters['before'],
        '30',
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '我发起的'));
      await tester.pumpAndSettle();
      expect(
        Uri.parse(state.requests.last['path'] as String).queryParameters['box'],
        'sent',
      );
      expect(
        Uri.parse(state.requests.last['path'] as String)
            .queryParameters['before'],
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline disables a visible confirmation; late detail cannot restore old identity',
    (tester) async {
      final state = UrgencyOffice(id: 'h1');
      addTearDown(state.dispose);
      await mount(
        tester,
        OfficeMessageUrgencyDetail(state: state, roomId: 'r', urgencyId: 'u1'),
      );
      state.connected = false;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('urgency-acknowledge')),
            )
            .onPressed,
        isNull,
      );
      state.connected = true;
      state.pendingDetail = Completer<Json>();
      state.notifyListeners();
      await tester.pump();
      state.changeIdentity();
      await tester.pump();
      state.pendingDetail!.complete({'urgency': state.urgency()});
      await tester.pumpAndSettle();
      expect(find.text('请确认交付时间'), findsNothing);
      expect(find.byKey(const ValueKey('urgency-acknowledge')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'authorization denial while acknowledging clears prior detail instead of keeping it visible',
    (tester) async {
      final state = UrgencyOffice(id: 'h1');
      addTearDown(state.dispose);
      await mount(
        tester,
        OfficeMessageUrgencyDetail(state: state, roomId: 'r', urgencyId: 'u1'),
      );
      state.ackFailure = OfficeException(403, '成员资格已变化');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('urgency-acknowledge')),
      );
      expect(find.text('成员资格已变化'), findsOneWidget);
      expect(find.text('请确认交付时间'), findsNothing);
      expect(find.text('林同事'), findsNothing);
      expect(find.byKey(const ValueKey('urgency-acknowledge')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
