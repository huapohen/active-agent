import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class ReceiptService {
  final sequences = {'room-a': 2, 'room-b': 5};
  final acknowledgments = <String, int>{};
  final receipts = <Json>[];
  final messageRequests = <Json>[];
  final polls = <({String owner, Completer<http.Response> response})>[];
  int pollCount = 0, cursor = 1;
  Completer<http.Response>? holdNextReceipt;
  bool failNextReceipt = false;
  bool failNextPage = false;
  String principalKind = 'human';
  Completer<http.Response>? holdNextPage;
  http.Response json(Json data, [int status = 200]) => http.Response(
    jsonEncode(data),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  Json room(String id, String owner) {
    final sequence = sequences[id]!;
    final read = acknowledgments['$owner:$id'] ?? 0;
    return {
      'id': id,
      'name': id,
      'kind': 'group',
      'revision': 1,
      'last_message': {'seq': sequence},
      'read_seq': read,
      'unread_count': sequence - read,
      'first_unread_seq': read < sequence ? read + 1 : null,
    };
  }

  Future<http.Response> call(http.Request request) async {
    final owner = request.headers['authorization']!.replaceFirst(
      'Bearer receipt-',
      '',
    );
    final path = request.url.path.replaceFirst('/api/im', '');
    if (path == '/me') {
      return json({
        'principal': {'id': owner, 'kind': principalKind},
      });
    }
    if (path == '/presence') return json({});
    if (path == '/events') {
      final response = Completer<http.Response>();
      polls.add((owner: owner, response: response));
      pollCount++;
      return response.future;
    }
    final match = RegExp(r'^/rooms/(room-[ab])(?:/(preferences|messages))?$')
        .firstMatch(path);
    if (match == null) {
      throw StateError('Unexpected receipt request: ${request.method} $path');
    }
    final id = match[1]!;
    if (match[2] == 'preferences' && request.method == 'PATCH') {
      final data = Json.from(jsonDecode(request.body));
      expect(data.keys.toSet(), {'read_seq'});
      receipts.add({'owner': owner, 'room': id, 'seq': data['read_seq']});
      if (failNextReceipt) {
        failNextReceipt = false;
        return json({'code': 'temporary'}, 503);
      }
      acknowledgments['$owner:$id'] = data['read_seq'] as int;
      final held = holdNextReceipt;
      holdNextReceipt = null;
      return held == null ? json({'room': room(id, owner)}) : held.future;
    }
    expect(request.method, 'GET');
    final all = List.generate(
      sequences[id]!,
      (index) => <String, dynamic>{
        'id': '$id-message-${index + 1}',
        'seq': index + 1,
        'author_id': 'other',
        'author': {'id': 'other', 'kind': 'human'},
        'content': 'Synthetic message ${index + 1}',
      },
    );
    if (match[2] == 'messages') {
      final query = request.url.queryParameters;
      messageRequests.add({'owner': owner, 'room': id, ...query});
      if (failNextPage) {
        failNextPage = false;
        return json({'error': 'Synthetic window interrupted'}, 503);
      }
      final limit = int.tryParse(query['limit'] ?? '') ?? 100;
      final read = acknowledgments['$owner:$id'] ?? 0;
      final firstUnread = read < sequences[id]! ? read + 1 : null;
      var candidates = all;
      var forward = false;
      if (query['first_unread'] == 'true' && firstUnread != null) {
        candidates = all
            .where((message) => (message['seq'] as int) >= firstUnread)
            .toList();
        forward = true;
      } else if (query['after'] != null) {
        candidates = all
            .where(
              (message) => (message['seq'] as int) > int.parse(query['after']!),
            )
            .toList();
        forward = true;
      } else if (query['before'] != null) {
        candidates = all
            .where(
              (message) =>
                  (message['seq'] as int) < int.parse(query['before']!),
            )
            .toList();
      }
      final messages = forward
          ? candidates.take(limit).toList()
          : candidates
                .skip(candidates.length > limit ? candidates.length - limit : 0)
                .toList();
      final first = messages.isEmpty ? null : messages.first['seq'] as int;
      final last = messages.isEmpty ? null : messages.last['seq'] as int;
      final before = first != null && first > 1;
      final after = last != null && last < sequences[id]!;
      final result = json({
        'messages': messages,
        'has_more': before,
        'has_more_before': before,
        'has_more_after': after,
        'before_cursor': first,
        'after_cursor': last,
        'anchor_seq': query['first_unread'] == 'true' ? firstUnread : null,
        'first_unread_seq': firstUnread,
        'unread_count': sequences[id]! - read,
        'read_seq': read,
        'remaining_unread_after': last == null
            ? 0
            : sequences[id]! - (last > read ? last : read),
      });
      final pending = holdNextPage;
      holdNextPage = null;
      return pending == null ? result : pending.future;
    }
    return json({
      'room': room(id, owner),
      'has_more_messages': false,
      'members': <Json>[],
      'messages': all.skip(all.length > 200 ? all.length - 200 : 0).toList(),
    });
  }

  Future<void> until(bool Function() ready) async {
    for (var attempt = 0; attempt < 200 && !ready(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(
      ready(),
      isTrue,
      reason: 'Expected synthetic poll/receipt boundary did not arrive',
    );
  }

  Future<void> event(String owner) async {
    await until(() => polls.any((poll) => poll.owner == owner));
    final pending = polls.firstWhere((poll) => poll.owner == owner);
    polls.remove(pending);
    final previous = pollCount;
    pending.response.complete(
      json({
        'cursor': ++cursor,
        'events': [
          {'type': 'message.created'},
        ],
      }),
    );
    await until(() => pollCount > previous);
  }

  void releasePolls() {
    for (final pending in polls) {
      if (!pending.response.isCompleted) {
        pending.response.complete(json({'cursor': cursor, 'events': []}));
      }
    }
    polls.clear();
  }
}

/// Keep real sign-in, selected-room loading, event polling and HTTP receipts.
/// Only unrelated business refreshes are removed from this bounded fixture.
class ReceiptOfficeState extends OfficeState {
  ReceiptOfficeState(this.service) : super(client: MockClient(service.call));
  final ReceiptService service;
  @override
  Future<void> refresh() async {
    rooms = service.sequences.keys
        .map((id) => service.room(id, me!['id'] as String))
        .toList();
    notifyListeners();
  }

  @override
  Future<void> refreshBusiness() async {}
}

void main() {
  late ReceiptService service;
  late ReceiptOfficeState state;
  setUp(() {
    service = ReceiptService();
    state = ReceiptOfficeState(service);
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

  Future<void> showAndReport(String room) async {
    final previous = service.receipts.length;
    await state.setConversationVisible(room, true);
    expect(service.receipts, hasLength(previous));
    await state.reportVisibleMessageSequences(
      room,
      (state.detail?['messages'] as List? ?? []).map(
        (message) => (message['seq'] as num).toInt(),
      ),
      selection: state.conversationSelection,
      identityGeneration: state.identityGeneration,
    );
  }

  test('sign-in and hidden event polling never mark a loaded room read; only reported visible messages do', () async {
    await connect();
    expect(state.selectedRoomId, 'room-a');
    expect(state.detail!['messages'], hasLength(2));
    expect(service.receipts, isEmpty);
    service.sequences['room-a'] = 3;
    await service.event('alice');
    expect(state.detail!['messages'], hasLength(3));
    expect(service.receipts, isEmpty);
    await showAndReport('room-a');
    expect(service.receipts.single, {
      'owner': 'alice',
      'room': 'room-a',
      'seq': 3,
    });
    service.sequences['room-a'] = 4;
    await service.event('alice');
    expect(service.receipts, hasLength(1));
    await showAndReport('room-a');
    expect(service.receipts.last['seq'], 4);
    await state.setConversationVisible('room-a', false);
    service.sequences['room-a'] = 5;
    await service.event('alice');
    expect(service.receipts, hasLength(2));
    expect(state.rooms.first['unread_count'], 1);
    await showAndReport('room-a');
    expect(service.receipts.last['seq'], 5);
    expect(state.rooms.first['unread_count'], 0);
  });

  test('switching rooms requires new visibility and an old widget cannot hide or activate another room', () async {
    await connect();
    await showAndReport('room-a');
    await state.selectRoom('room-b');
    expect(service.receipts, hasLength(1));
    await showAndReport('room-b');
    expect(service.receipts.last['room'], 'room-b');
    await state.setConversationVisible('room-a', false);
    await showAndReport('room-a');
    service.sequences['room-b'] = 6;
    await service.event('alice');
    await showAndReport('room-b');
    expect(service.receipts.last, {
      'owner': 'alice',
      'room': 'room-b',
      'seq': 6,
    });
    expect(service.receipts, hasLength(3));
  });

  test(
    'a receipt response arriving after hiding cannot zero a newer unread count',
    () async {
      await connect();
      final delayed = Completer<http.Response>();
      service.holdNextReceipt = delayed;
      final first = showAndReport('room-a');
      await service.until(() => service.receipts.length == 1);
      await state.setConversationVisible('room-a', false);
      service.sequences['room-a'] = 3;
      await service.event('alice');
      expect(state.rooms.first['unread_count'], 1);
      delayed.complete(service.json({}));
      await first;
      expect(state.rooms.first['unread_count'], 1);
      await showAndReport('room-a');
      expect(service.receipts.last['seq'], 3);
    },
  );

  test('an old identity receipt cannot poison the new identity read cache or counters', () async {
    await connect();
    final delayed = Completer<http.Response>();
    service.holdNextReceipt = delayed;
    final previousIdentity = showAndReport('room-a');
    await service.until(() => service.receipts.length == 1);
    await connect('bob');
    expect(state.rooms.first['unread_count'], 2);
    delayed.complete(service.json({}));
    await previousIdentity;
    expect(state.rooms.first['unread_count'], 2);
    await showAndReport('room-a');
    expect(service.receipts.last, {'owner': 'bob', 'room': 'room-a', 'seq': 2});
  });

  test('repeated visible builds deduplicate a pending receipt, visibility changes and failures remain retryable', () async {
    await connect();
    final delayed = Completer<http.Response>();
    service.holdNextReceipt = delayed;
    final first = showAndReport('room-a');
    await service.until(() => service.receipts.length == 1);
    await showAndReport('room-a');
    expect(service.receipts, hasLength(1));
    await state.setConversationVisible('room-a', false);
    await showAndReport('room-a');
    expect(service.receipts, hasLength(2));
    delayed.complete(service.json({}));
    await first;
    await state.setConversationVisible('room-a', false);
    service.sequences['room-a'] = 3;
    await service.event('alice');
    service.failNextReceipt = true;
    await expectLater(
      showAndReport('room-a'),
      throwsA(
        isA<OfficeException>().having((error) => error.status, 'status', 503),
      ),
    );
    await showAndReport('room-a');
    expect(service.receipts.map((item) => item['seq']), [2, 2, 3, 3]);
    expect(state.rooms.first['unread_count'], 0);
  });
}
