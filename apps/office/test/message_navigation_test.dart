import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'read_receipts_test.dart' show ReceiptOfficeState, ReceiptService;

/// Reuse real login, room windows and receipt transport. Only the new message
/// endpoints are added; OfficeState navigation/mutations are never stubbed.
class NavigationService extends ReceiptService {
  final requests = <Json>[];
  final mutations = <Json>[];
  final hidden = <String>{};
  final missing = <String>{};
  Completer<http.Response>? holdDirect, holdMutation;
  int? failNextMutation;

  Json message(String room, String id) => {
    'id': id,
    'seq': int.parse(id.split('-').last),
    'author_id': 'other',
    'author': {'id': 'other', 'kind': 'human'},
    'content': hidden.contains(id) ? '' : 'Synthetic target $id',
    'revision': 7,
    if (hidden.contains(id)) 'hidden': true,
  };

  @override
  Future<http.Response> call(http.Request request) async {
    final owner = request.headers['authorization']!.replaceFirst(
      'Bearer receipt-',
      '',
    );
    final path = request.url.path.replaceFirst('/api/im', '');
    requests.add({
      'owner': owner,
      'path': path,
      'method': request.method,
      'query': request.url.queryParameters,
    });
    final match = RegExp(
      r'^/rooms/(room-[ab])/messages/([^/]+)(?:/(preferences|forwarding|forward))?$',
    ).firstMatch(path);
    if (match == null) return super.call(request);
    final room = match[1]!, id = match[2]!;
    if (match[3] != null) {
      expect(request.method, match[3] == 'forward' ? 'POST' : 'PATCH');
      final body = Json.from(jsonDecode(request.body));
      mutations.add({
        'owner': owner,
        'room': room,
        'id': id,
        'kind': match[3],
        'body': body,
      });
      final failure = failNextMutation;
      failNextMutation = null;
      if (failure != null) {
        return json({
          'code': failure == 409 ? 'conflict' : 'author_required',
        }, failure);
      }
      final pending = holdMutation;
      holdMutation = null;
      if (pending != null) return pending.future;
      return json({'message': message(room, id)});
    }
    expect(request.method, 'GET');
    final pending = holdDirect;
    holdDirect = null;
    if (pending != null) return pending.future;
    if (missing.contains(id)) return json({'code': 'not_found'}, 404);
    return json({'message': message(room, id), 'reply_parent': null});
  }
}

class NavigationOfficeState extends ReceiptOfficeState {
  NavigationOfficeState(super.service);
  final refreshOwners = <String>[];
  final businessRefreshOwners = <String>[];
  Completer<void>? holdNextRefresh;

  @override
  Future<void> refresh() async {
    refreshOwners.add(me?['id']?.toString() ?? '');
    final held = holdNextRefresh;
    holdNextRefresh = null;
    if (held != null) await held.future;
    await super.refresh();
  }

  @override
  Future<void> refreshBusiness() async {
    businessRefreshOwners.add(me?['id']?.toString() ?? '');
    await super.refreshBusiness();
  }
}

void main() {
  late NavigationService service;
  late NavigationOfficeState state;

  setUp(() {
    service = NavigationService();
    state = NavigationOfficeState(service);
  });
  tearDown(() async {
    state.dispose();
    service.releasePolls();
    await Future<void>.delayed(Duration.zero);
  });

  Future<void> connect([String owner = 'alice']) async {
    await state.connect('https://receipt-fixture.example', 'receipt-$owner');
    await service.until(() => service.polls.any((poll) => poll.owner == owner));
  }

  test('message link opens its target as the first row and anchor without acknowledging unrelated unread messages', () async {
    await connect();
    await state.setConversationVisible('room-a', true);
    final oldSelection = state.conversationSelection;
    final generation = state.identityGeneration;
    service.messageRequests.clear();
    await state.focusMessage('room-b', 'room-b-message-3');

    expect(state.selectedRoomId, 'room-b');
    final messages = (state.detail!['messages'] as List).cast<Json>();
    expect(messages.map((message) => message['seq']), [3, 4, 5]);
    expect(messages.first['id'], 'room-b-message-3');
    expect(state.conversationWindow!.anchorSeq, 3);
    expect(state.conversationWindow!.startAtUnread, isFalse);
    expect(state.conversationWindow!.hasMoreBefore, isTrue);
    expect(service.messageRequests, [
      {'owner': 'alice', 'room': 'room-b', 'after': '2', 'limit': '100'},
    ]);
    expect(service.receipts, isEmpty);
    await state.reportVisibleMessageSequences(
      'room-a',
      [1, 2],
      selection: oldSelection,
      identityGeneration: generation,
    );
    expect(service.receipts, isEmpty);
    await state.setConversationVisible('room-b', true);
    expect(service.receipts, isEmpty);
    await state.reportVisibleMessageSequences(
      'room-b',
      [3],
      selection: state.conversationSelection,
      identityGeneration: state.identityGeneration,
    );
    expect(service.receipts.single, {
      'owner': 'alice',
      'room': 'room-b',
      'seq': 3,
    });
  });

  test('message-link loading clears the old visible window before the target response can arrive', () async {
    await connect();
    await state.setConversationVisible('room-a', true);
    final oldSelection = state.conversationSelection;
    final generation = state.identityGeneration;
    final held = Completer<http.Response>();
    service.holdDirect = held;
    final navigation = state.focusMessage('room-b', 'room-b-message-4');
    await service.until(
      () => service.requests.any(
        (request) =>
            request['path'] == '/rooms/room-b/messages/room-b-message-4',
      ),
    );
    expect(state.selectedRoomId, 'room-b');
    expect(state.detail, isNull);
    expect(state.loadingMessageWindow, isTrue);
    await state.reportVisibleMessageSequences(
      'room-a',
      [2],
      selection: oldSelection,
      identityGeneration: generation,
    );
    expect(service.receipts, isEmpty);
    held.complete(
      service.json({'message': service.message('room-b', 'room-b-message-4')}),
    );
    await navigation;
    expect(state.loadingMessageWindow, isFalse);
    expect((state.detail!['messages'] as List).first['id'], 'room-b-message-4');
  });

  test('a target disappearing between lookup and history fetch never opens the next message under its anchor', () async {
    await connect();
    for (final page in <List<Json>>[
      [],
      [service.message('room-b', 'room-b-message-4')],
      [
        {...service.message('room-b', 'room-b-message-3'), 'hidden': true},
      ],
    ]) {
      final held = Completer<http.Response>();
      service.holdNextPage = held;
      final requestCount = service.messageRequests.length;
      final navigation = state.focusMessage('room-b', 'room-b-message-3');
      final rejected = expectLater(
        navigation,
        throwsA(
          isA<OfficeException>().having((error) => error.status, 'status', 404),
        ),
      );
      await service.until(() => service.messageRequests.length > requestCount);
      held.complete(service.json({'messages': page, 'has_more_before': true}));
      await rejected;
      expect(state.detail, isNull);
      expect(state.conversationWindow, isNull);
      expect(state.loadingMessageWindow, isFalse);
      expect(service.receipts, isEmpty);
    }
  });

  test('hidden and missing message links fail explicitly without a replacement window or read acknowledgement', () async {
    await connect();
    service.messageRequests.clear();
    service.hidden.add('room-b-message-3');
    await expectLater(
      state.focusMessage('room-b', 'room-b-message-3'),
      throwsA(
        isA<OfficeException>()
            .having((error) => error.status, 'status', 404)
            .having(
              (error) => error.message,
              'recovery explanation',
              contains('恢复'),
            ),
      ),
    );
    expect(state.detail, isNull);
    expect(state.conversationWindow, isNull);
    expect(state.loadingMessageWindow, isFalse);
    expect(service.messageRequests, isEmpty);
    service.missing.add('room-b-message-4');
    await expectLater(
      state.focusMessage('room-b', 'room-b-message-4'),
      throwsA(
        isA<OfficeException>()
            .having((error) => error.status, 'status', 404)
            .having((error) => error.code, 'code', 'not_found'),
      ),
    );
    expect(state.detail, isNull);
    expect(state.loadingMessageWindow, isFalse);
    expect(service.receipts, isEmpty);
  });

  test('a late message lookup cannot replace a newly logged-in identity or request its old page with new credentials', () async {
    await connect();
    final held = Completer<http.Response>();
    service.holdDirect = held;
    final navigation = state.focusMessage('room-b', 'room-b-message-3');
    await service.until(() => service.holdDirect == null);
    await connect('bob');
    final selection = state.conversationSelection;
    final window = state.conversationWindow;
    service.messageRequests.clear();
    held.complete(
      service.json({'message': service.message('room-b', 'room-b-message-3')}),
    );
    await navigation;
    expect(state.me!['id'], 'bob');
    expect(state.selectedRoomId, 'room-a');
    expect(state.conversationSelection, selection);
    expect(state.conversationWindow, same(window));
    expect(service.messageRequests, isEmpty);
    expect(service.receipts, isEmpty);
  });

  test('a late forward-window response is discarded after identity changes, including A to B to A', () async {
    await connect();
    final held = Completer<http.Response>();
    service.holdNextPage = held;
    final navigation = state.focusMessage('room-b', 'room-b-message-3');
    await service.until(
      () => service.messageRequests.any(
        (request) => request['room'] == 'room-b' && request['after'] == '2',
      ),
    );
    await connect('bob');
    await connect('alice');
    final currentWindow = state.conversationWindow;
    held.complete(
      service.json({
        'messages': [service.message('room-b', 'room-b-message-3')],
        'anchor_seq': 3,
        'has_more_before': true,
        'has_more_after': true,
      }),
    );
    await navigation;
    expect(state.me!['id'], 'alice');
    expect(state.selectedRoomId, 'room-a');
    expect(state.conversationWindow, same(currentWindow));
    expect(state.loadingMessageWindow, isFalse);
    expect(service.receipts, isEmpty);
  });

  test('a later navigation wins over an earlier linked-message lookup within the same identity', () async {
    await connect();
    final held = Completer<http.Response>();
    service.holdDirect = held;
    final earlier = state.focusMessage('room-b', 'room-b-message-3');
    await service.until(() => service.holdDirect == null);
    await state.focusMessage('room-a', 'room-a-message-2');
    final current = state.conversationWindow;
    held.complete(
      service.json({'message': service.message('room-b', 'room-b-message-3')}),
    );
    await earlier;
    expect(state.selectedRoomId, 'room-a');
    expect(state.conversationWindow, same(current));
    expect(state.conversationWindow!.anchorSeq, 2);
    expect(service.receipts, isEmpty);
  });

  test('personal message controls send explicit mark and hide/restore PATCH intentions to the source room only', () async {
    await connect();
    await state.setMessagePersonal('room-b', 'room-b-message-3', marked: true);
    await state.setMessagePersonal('room-b', 'room-b-message-3', marked: false);
    await state.setMessagePersonal('room-b', 'room-b-message-3', hidden: true);
    await state.setMessagePersonal('room-b', 'room-b-message-3', hidden: false);
    expect(service.mutations.map((request) => request['body']), [
      {'marked': true},
      {'marked': false},
      {'hidden': true},
      {'hidden': false},
    ]);
    expect(
      service.mutations.every(
        (request) =>
            request['owner'] == 'alice' &&
            request['room'] == 'room-b' &&
            request['id'] == 'room-b-message-3' &&
            request['kind'] == 'preferences',
      ),
      isTrue,
    );
    expect(state.selectedRoomId, 'room-a');
    expect(service.receipts, isEmpty);
  });

  test('forwarding protection sends the observed source revision and preserves permission/conflict failures', () async {
    await connect();
    final message = service.message('room-b', 'room-b-message-3');
    await state.setMessageForwarding('room-b', message, true);
    expect(service.mutations.single['body'], {
      'base_revision': 7,
      'no_forward': true,
    });
    expect(service.mutations.single['room'], 'room-b');
    service.failNextMutation = 409;
    await expectLater(
      state.setMessageForwarding('room-b', message, false),
      throwsA(
        isA<OfficeException>().having(
          (error) => error.code,
          'code',
          'conflict',
        ),
      ),
    );
    service.failNextMutation = 403;
    await expectLater(
      state.setMessageForwarding('room-b', message, false),
      throwsA(
        isA<OfficeException>().having(
          (error) => error.code,
          'code',
          'author_required',
        ),
      ),
    );
    expect(service.mutations, hasLength(3));
    expect(service.receipts, isEmpty);
  });

  test(
    'late successful personal mutation does not refresh a replacement identity',
    () async {
      await connect();
      final held = Completer<http.Response>();
      service.holdMutation = held;
      final mutation = state.setMessagePersonal(
        'room-b',
        'room-b-message-3',
        hidden: true,
      );
      await service.until(() => service.mutations.isNotEmpty);
      await connect('bob');
      final refreshCount = state.refreshOwners.length;
      held.complete(service.json({'changed': true}));
      await mutation;
      expect(service.mutations.single['owner'], 'alice');
      expect(state.me!['id'], 'bob');
      expect(state.refreshOwners, hasLength(refreshCount));
      expect(state.selectedRoomId, 'room-a');
    },
  );

  test('late successful forwarding mutation does not refresh a replacement identity', () async {
    await connect();
    final held = Completer<http.Response>();
    service.holdMutation = held;
    final mutation = state.setMessageForwarding(
      'room-b',
      service.message('room-b', 'room-b-message-3'),
      true,
    );
    await service.until(() => service.mutations.isNotEmpty);
    await connect('bob');
    final refreshCount = state.refreshOwners.length;
    held.complete(
      service.json({
        'message': {'id': 'room-b-message-3'},
      }),
    );
    await mutation;
    expect(state.me!['id'], 'bob');
    expect(state.refreshOwners, hasLength(refreshCount));
    expect(service.mutations.single['owner'], 'alice');
  });

  test('a late native forward cannot erase a replacement identity pending intent or refresh its state', () async {
    await connect();
    final held = Completer<http.Response>();
    service.holdMutation = held;
    final message = service.message('room-b', 'room-b-message-3');
    final alice = state.forwardMessage(
      message,
      'room-a',
      sourceRoomId: 'room-b',
    );
    final aliceRejected = expectLater(
      alice,
      throwsA(
        isA<OfficeException>().having(
          (error) => error.status,
          'identity changed',
          401,
        ),
      ),
    );
    await service.until(() => service.mutations.isNotEmpty);
    final aliceClient = (service.mutations.single['body'] as Map)['client_id'];
    await connect('bob');
    service.failNextMutation = 503;
    await expectLater(
      state.forwardMessage(message, 'room-a', sourceRoomId: 'room-b'),
      throwsA(
        isA<OfficeException>().having(
          (error) => error.status,
          'pending response',
          503,
        ),
      ),
    );
    final bobClient = (service.mutations.last['body'] as Map)['client_id'];
    expect(bobClient, isNot(aliceClient));
    final refreshCount = state.refreshOwners.length;
    held.complete(
      service.json({
        'message': {'id': 'alice-forwarded-message'},
      }),
    );
    await aliceRejected;
    expect(state.me!['id'], 'bob');
    expect(state.refreshOwners, hasLength(refreshCount));
    await state.forwardMessage(message, 'room-a', sourceRoomId: 'room-b');
    expect(service.mutations.last['owner'], 'bob');
    expect((service.mutations.last['body'] as Map)['client_id'], bobClient);
    expect(service.receipts, isEmpty);
  });

  test('a refresh failure after a confirmed forward cannot mark a replacement identity offline', () async {
    await connect();
    final held = Completer<void>();
    state.holdNextRefresh = held;
    final mutation = state.forwardMessage(
      service.message('room-b', 'room-b-message-3'),
      'room-a',
      sourceRoomId: 'room-b',
    );
    final rejected = expectLater(
      mutation,
      throwsA(
        isA<OfficeException>().having(
          (error) => error.status,
          'identity changed',
          401,
        ),
      ),
    );
    await service.until(() => state.holdNextRefresh == null);
    await connect('bob');
    expect(state.connected, isTrue);
    held.completeError(OfficeException(503, 'Old identity refresh failed'));
    await rejected;
    expect(state.me!['id'], 'bob');
    expect(state.connected, isTrue);
    expect(state.error, isEmpty);
  });

  test('a confirmed old forward stops its refresh sequence when the identity changes during room refresh', () async {
    await connect();
    final held = Completer<void>();
    state.holdNextRefresh = held;
    final mutation = state.forwardMessage(
      service.message('room-b', 'room-b-message-3'),
      'room-a',
      sourceRoomId: 'room-b',
    );
    final rejected = expectLater(
      mutation,
      throwsA(
        isA<OfficeException>().having(
          (error) => error.status,
          'identity changed',
          401,
        ),
      ),
    );
    await service.until(() => state.holdNextRefresh == null);
    await connect('bob');
    final businessCount = state.businessRefreshOwners.length;
    final messageCount = service.messageRequests.length;
    held.complete();
    await rejected;
    expect(state.me!['id'], 'bob');
    expect(state.businessRefreshOwners, hasLength(businessCount));
    expect(service.messageRequests, hasLength(messageCount));
    expect(state.connected, isTrue);
  });

  test('shareable links strip endpoint credentials, query secrets and fragments while preserving encoded coordinates', () {
    const room = 'room/中文 +&?#', message = 'msg/回复 +&?#';
    final result = officeMessageLink(
      'https://test-user:test-password@example.test:8443/private?token=synthetic-token&access_token=synthetic-access#synthetic-fragment',
      room,
      message,
    );
    final uri = Uri.parse(result);
    expect(uri.scheme, 'https');
    expect(uri.host, 'example.test');
    expect(uri.port, 8443);
    expect(uri.path, '/office/');
    expect(uri.userInfo, isEmpty);
    expect(uri.fragment, isEmpty);
    expect(uri.queryParameters, {'room': room, 'message': message});
    expect(officeMessageTarget(uri), (room, message));
    for (final secret in [
      'test-user',
      'test-password',
      'synthetic-token',
      'synthetic-access',
      'synthetic-fragment',
      '/private',
    ]) {
      expect(result, isNot(contains(secret)));
    }
  });

  test('message coordinates round-trip for IPv6/custom ports and reject blank or unbounded targets', () {
    final uri = Uri.parse(
      officeMessageLink('http://[::1]:3218', 'room-a', 'msg-a'),
    );
    expect(uri.host, '::1');
    expect(uri.port, 3218);
    expect(officeMessageTarget(uri), ('room-a', 'msg-a'));
    for (final query in <Map<String, String>>[
      {},
      {'room': 'room-a'},
      {'message': 'msg-a'},
      {'room': ' ', 'message': 'msg-a'},
      {'room': 'room-a', 'message': 'x' * 201},
      {'room': 'x' * 201, 'message': 'msg-a'},
    ]) {
      expect(officeMessageTarget(Uri(queryParameters: query)), isNull);
    }
    expect(
      officeMessageTarget(
        Uri(queryParameters: {'room': ' room-a ', 'message': ' msg-a '}),
      ),
      ('room-a', 'msg-a'),
    );
  });
}
