import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'read_receipts_test.dart' show ReceiptService, ReceiptOfficeState;

void main() {
  late ReceiptService service;
  late ReceiptOfficeState state;
  setUp(() {
    service = ReceiptService();
    service.sequences['room-a'] = 351;
    service.acknowledgments['alice:room-a'] = 20;
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

  List<int> sequences() => (state.detail?['messages'] as List? ?? [])
      .map((message) => message['seq'] as int)
      .toList();
  Future<void> visible(
    Iterable<int> values, {
    String room = 'room-a',
    int? selection,
    int? generation,
  }) => state.reportVisibleMessageSequences(
    room,
    values,
    selection: selection ?? state.conversationSelection,
    identityGeneration: generation ?? state.identityGeneration,
  );

  for (final kind in ['human', 'agent']) {
    test(
      '$kind opens the first unread window and acknowledges only loaded sequences explicitly seen',
      () async {
        service.principalKind = kind;
        await connect();
        expect(state.me!['kind'], kind);
        expect(sequences(), List.generate(100, (i) => 21 + i));
        expect(service.messageRequests.single['first_unread'], 'true');
        final window = state.conversationWindow!;
        expect(window.entryFirstUnreadSeq, 21);
        expect(window.entryUnreadCount, 331);
        expect(window.anchorSeq, 21);
        expect(window.startAtUnread, isTrue);
        expect(window.hasMoreBefore, isTrue);
        expect(window.hasMoreAfter, isTrue);
        expect(window.remainingUnreadAfter, 231);
        expect(service.receipts, isEmpty);
        await state.setConversationVisible('room-a', true);
        expect(service.receipts, isEmpty);
        await visible([21, 22, 25, 351, 99999]);
        expect(service.receipts.single['seq'], 25);
        expect(state.rooms.first['read_seq'], 25);
        expect(state.rooms.first['unread_count'], 326);
        expect(state.conversationWindow!.firstUnreadSeq, 26);
        expect(state.conversationWindow!.entryFirstUnreadSeq, 21);
        expect(state.conversationWindow!.entryUnreadCount, 331);
        await visible([22, 25]);
        expect(service.receipts, hasLength(1));
      },
    );
  }

  test('forward and earlier windows merge without gaps or receipts and preserve the original entry snapshot', () async {
    await connect();
    final version = state.conversationWindow!.positionVersion;
    await state.loadLaterMessages();
    expect(sequences(), List.generate(200, (i) => 21 + i));
    expect(service.messageRequests.last['after'], '120');
    expect(state.conversationWindow!.remainingUnreadAfter, 131);
    await state.loadEarlierMessages();
    expect(sequences(), List.generate(220, (i) => i + 1));
    expect(service.messageRequests.last['before'], '21');
    expect(state.conversationWindow!.hasMoreBefore, isFalse);
    expect(state.conversationWindow!.hasMoreAfter, isTrue);
    expect(state.conversationWindow!.remainingUnreadAfter, 131);
    expect(state.conversationWindow!.entryFirstUnreadSeq, 21);
    expect(state.conversationWindow!.positionVersion, version);
    expect(service.receipts, isEmpty);
  });

  test('background refresh preserves a partly read window while new arrivals remain ahead of it', () async {
    await connect();
    await state.setConversationVisible('room-a', true);
    await visible([21, 24]);
    service.sequences['room-a'] = 400;
    await service.event('alice');
    expect(sequences(), List.generate(100, (i) => 21 + i));
    expect(state.conversationWindow!.remainingUnreadAfter, 280);
    expect(state.conversationWindow!.entryUnreadCount, 331);
    expect(state.conversationWindow!.entryFirstUnreadSeq, 21);
    expect(service.receipts, hasLength(1));
    expect(service.receipts.single['seq'], 24);
    expect(state.rooms.first['unread_count'], 376);
  });

  test('jump to latest relocates the window without reading it and retains the entry marker', () async {
    await connect();
    final version = state.conversationWindow!.positionVersion;
    await state.jumpToLatestMessages();
    expect(sequences(), List.generate(100, (i) => 252 + i));
    expect(state.conversationWindow!.startAtUnread, isFalse);
    expect(state.conversationWindow!.anchorSeq, isNull);
    expect(state.conversationWindow!.positionVersion, greaterThan(version));
    expect(state.conversationWindow!.entryFirstUnreadSeq, 21);
    expect(state.conversationWindow!.entryUnreadCount, 331);
    expect(state.conversationWindow!.hasMoreBefore, isTrue);
    expect(state.conversationWindow!.hasMoreAfter, isFalse);
    expect(service.receipts, isEmpty);
    await state.setConversationVisible('room-a', true);
    await visible([351]);
    expect(service.receipts.single['seq'], 351);
    expect(state.rooms.first['unread_count'], 0);
  });

  test(
    'no unread history opens normally without an invented first-unread marker',
    () async {
      service.acknowledgments['alice:room-a'] = 351;
      await connect();
      expect(service.messageRequests, isEmpty);
      expect(state.conversationWindow!.entryFirstUnreadSeq, isNull);
      expect(state.conversationWindow!.entryUnreadCount, 0);
      expect(state.conversationWindow!.startAtUnread, isFalse);
      await state.setConversationVisible('room-a', true);
      await visible([351]);
      expect(service.receipts, isEmpty);
    },
  );

  test('hidden, unloaded, previous-selection and previous-identity rectangle reports never acknowledge', () async {
    await connect();
    final selection = state.conversationSelection,
        generation = state.identityGeneration;
    await visible([25]);
    expect(service.receipts, isEmpty);
    await state.setConversationVisible('room-a', true);
    await visible([351, -1]);
    expect(service.receipts, isEmpty);
    await state.selectRoom('room-a');
    await state.setConversationVisible('room-a', true);
    await visible([25], selection: selection);
    expect(service.receipts, isEmpty);
    await connect('bob');
    await state.setConversationVisible('room-a', true);
    await visible(
      [25],
      selection: state.conversationSelection,
      generation: generation,
    );
    expect(service.receipts, isEmpty);
    await visible([1, 5]);
    expect(service.receipts.single, {
      'owner': 'bob',
      'room': 'room-a',
      'seq': 5,
    });
  });

  for (final change in ['room', 'identity']) {
    test(
      'late forward-page response cannot overwrite a newer $change window',
      () async {
        await connect();
        final delayed = Completer<http.Response>();
        service.holdNextPage = delayed;
        final previous = service.messageRequests.length;
        final pending = state.loadLaterMessages();
        await service.until(() => service.messageRequests.length > previous);
        if (change == 'room') {
          await state.selectRoom('room-b');
        } else {
          await connect('bob');
        }
        final current = sequences();
        final entry = state.conversationWindow;
        delayed.complete(
          service.json({
            'messages': [
              {'id': 'stale', 'seq': 9999},
            ],
          }),
        );
        await pending;
        expect(sequences(), current);
        expect(state.conversationWindow, same(entry));
        expect(state.loadingMessageWindow, isFalse);
        expect(service.receipts, isEmpty);
      },
    );
  }

  test(
    'failed page load preserves its window and the retry uses the same cursor',
    () async {
      await connect();
      service.failNextPage = true;
      final initial = sequences(), entry = state.conversationWindow;
      await expectLater(
        state.loadLaterMessages(),
        throwsA(
          isA<OfficeException>().having((error) => error.status, 'status', 503),
        ),
      );
      expect(sequences(), initial);
      expect(state.conversationWindow, same(entry));
      expect(state.loadingMessageWindow, isFalse);
      await state.loadLaterMessages();
      expect(
        service.messageRequests.skip(1).map((request) => request['after']),
        ['120', '120'],
      );
      expect(sequences(), List.generate(200, (i) => 21 + i));
      expect(service.receipts, isEmpty);
    },
  );

  test('a delayed background window refresh cannot undo an explicit jump to latest', () async {
    await connect();
    final delayed = Completer<http.Response>();
    service.holdNextPage = delayed;
    final previous = service.messageRequests.length;
    final event = service.event('alice');
    await service.until(() => service.messageRequests.length > previous);
    await state.jumpToLatestMessages();
    final version = state.conversationWindow!.positionVersion;
    delayed.complete(
      service.json({
        'messages': [
          {'id': 'stale', 'seq': 1},
        ],
      }),
    );
    await event;
    expect(sequences(), List.generate(100, (i) => 252 + i));
    expect(state.conversationWindow!.positionVersion, version);
    expect(state.conversationWindow!.startAtUnread, isFalse);
    expect(service.receipts, isEmpty);
  });

  test('a receipt honoring a newer device watermark updates remaining unread without changing the entry snapshot', () async {
    await connect();
    await state.setConversationVisible('room-a', true);
    final delayed = Completer<http.Response>();
    service.holdNextReceipt = delayed;
    final pending = visible([25]);
    await service.until(() => service.receipts.length == 1);
    service.acknowledgments['alice:room-a'] = 300;
    delayed.complete(service.json({'room': service.room('room-a', 'alice')}));
    await pending;
    expect(state.rooms.first['read_seq'], 300);
    expect(state.rooms.first['unread_count'], 51);
    expect(state.conversationWindow!.remainingUnreadAfter, 51);
    expect(state.conversationWindow!.firstUnreadSeq, 301);
    expect(state.conversationWindow!.entryFirstUnreadSeq, 21);
    expect(state.conversationWindow!.entryUnreadCount, 331);
  });

  test('a delayed visible receipt cannot replace a fresher unread count after new arrivals', () async {
    await connect();
    await state.setConversationVisible('room-a', true);
    final delayed = Completer<http.Response>();
    service.holdNextReceipt = delayed;
    final pending = visible([25]);
    await service.until(() => service.receipts.length == 1);
    final olderRoom = service.room('room-a', 'alice');
    service.sequences['room-a'] = 400;
    await service.event('alice');
    expect(state.rooms.first['unread_count'], 375);
    delayed.complete(service.json({'room': olderRoom}));
    await pending;
    expect(state.rooms.first['unread_count'], 375);
    expect(state.rooms.first['read_seq'], 25);
    expect(state.conversationWindow!.entryUnreadCount, 331);
  });
}
