import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_forward_bundle.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared native-contract fixture for conversation integration tests.
class BundleOffice extends OfficeState {
  BundleOffice({this.sourceRoom = 'source', String kind = 'human'}) {
    endpoint = 'https://bundle.invalid';
    me = {'id': 'member', 'name': '发起者', 'kind': kind};
    selectedRoomId = sourceRoom;
    connected = true;
    rooms = [
      {'id': 'target-a', 'name': '设计群', 'kind': 'group'},
      {'id': 'target-b', 'name': 'Agent 协作群', 'kind': 'group'},
    ];
    sources = [source('m1', '第一条原文', 3), source('m2', '第二条原文', 4)];
    detail = {
      'room': {'id': sourceRoom, 'name': '来源会话'},
      'messages': sources,
      'native_features': {'message_forward_bundles': true},
    };
  }
  final String sourceRoom;
  late List<Json> sources;
  final requests = <Json>[];
  int generation = 0;
  @override
  int get identityGeneration => generation;
  void emit() => notifyListeners();
  void changeIdentity() {
    generation++;
    me = {'id': 'other-member', 'name': '另一个身份', 'kind': 'human'};
    emit();
  }

  Json copy(Json value) => Json.from(jsonDecode(jsonEncode(value)) as Map);
  static Json source(String id, String content, int revision) => {
    'id': id,
    'content': content,
    'revision': revision,
    'at': '2026-09-07T00:01:00Z',
    'author': {'id': 'author', 'name': '同事', 'kind': 'human'},
    'kind': 'text',
    'attachments': <Json>[],
  };
  static Json item(String id, String content) => {
    'source_message_id': id,
    'source_revision': 1,
    'source_at': '2026-09-07T00:01:00Z',
    'author': {'id': 'author', 'name': '同事', 'kind': 'human'},
    'kind': 'text',
    'content': content,
    'attachments': <Json>[],
  };
  final membersByRoom = <String, List<Json>>{};
  List<Json> get commonMembers => [
    {'id': 'member', 'name': '发起者', 'kind': 'human'},
    {'id': 'agent', 'name': '机伴', 'kind': 'agent'},
    {'id': 'colleague', 'name': '小明', 'kind': 'human'},
  ];
  Completer<Json>? pendingGet, pendingPost;
  String? pendingGetPath;
  Object? postFailure, readFailure;
  Json? receipt;
  bool loseSuccess = false, malformedReceipt = false, hiddenCard = false;
  Json get card => {
    'id': 'delivery',
    'kind': 'forward_bundle',
    'revision': 1,
    'content': '附言',
    'hidden': hiddenCard,
    'forward_bundle': {
      'id': 'bundle-native',
      'title': '聊天记录',
      'message_count': 2,
      'preview': [
        {'author_name': '同事', 'content': '仅列表预览'},
      ],
    },
  };
  Json bundleDetail = {
    'room_id': 'target-a',
    'message_id': 'delivery',
    'bundle': {
      'id': 'bundle-native',
      'title': '聊天记录',
      'message_count': 2,
      'snapshot_policy': 'shared_copy',
      'items': [item('m1', '从接口读取的原文'), item('m2', '第二条真实快照')],
    },
  };
  List<Json> get posts => requests.where((r) => r['method'] == 'POST').toList();
  Json deliveryReceipt(Json payload) => {
    'client_id': payload['client_id'],
    'bundle': {
      'id': 'bundle-native',
      'title': '聊天记录',
      'message_count': (payload['message_ids'] as List).length,
      'created_by': 'member',
      'created_at': '2026-09-07T00:01:00Z',
    },
    'deliveries': [
      for (final roomId in payload['target_room_ids'] as List)
        {
          'room_id': roomId,
          'message': {
            ...card,
            'id': 'delivery-$roomId',
            'content': payload['comment'],
            'mentions': payload['mentions'],
            if (malformedReceipt) 'kind': 'text',
          },
        },
    ],
    'duplicate': false,
  };
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
    if (method == 'GET' && pendingGet != null && path == pendingGetPath) {
      return pendingGet!.future;
    }
    if (path.contains('/forward-bundle-receipts?')) {
      return {
        'receipts': receipt == null ? [] : [copy(receipt!)],
        'truncated': false,
      };
    }
    if (method == 'POST' &&
        path == '/rooms/$sourceRoom/messages/forward-bundle') {
      if (pendingPost != null) return pendingPost!.future;
      if (postFailure != null) {
        final error = postFailure!;
        postFailure = null;
        throw error;
      }
      receipt = deliveryReceipt(data!);
      if (loseSuccess) {
        loseSuccess = false;
        throw TimeoutException('投递响应丢失');
      }
      return copy(receipt!);
    }
    if (path == '/rooms') return {'rooms': rooms};
    if (path == '/rooms/target-a/messages/delivery') return {'message': card};
    if (path == '/rooms/target-a/messages/delivery/forward-bundle') {
      if (readFailure != null) throw readFailure!;
      return copy(bundleDetail);
    }
    for (final source in sources) {
      if (path == '/rooms/$sourceRoom/messages/${source['id']}') {
        if (readFailure != null) throw readFailure!;
        return {'message': copy(source)};
      }
    }
    for (final room in rooms) {
      if (path == '/rooms/${room['id']}') {
        return {
          'room': copy(room),
          'members': membersByRoom[room['id']] ?? commonMembers,
        };
      }
    }
    throw StateError('Unexpected request: $method $path');
  }
}

Future<void> openBundleComposer(
  WidgetTester tester,
  BundleOffice state, {
  ValueChanged<Json?>? onResult,
  List<Json>? messages,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(viewInsets: viewInsets),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showOfficeMergedForward(
                context,
                state,
                state.sourceRoom,
                messages ?? state.sources,
              );
              onResult?.call(result);
            },
            child: const Text('打开合并'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开合并'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> tapBundle(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> selectA(WidgetTester tester) =>
    tapBundle(tester, find.byKey(const ValueKey('bundle-target-target-a')));
Future<void> sendBundle(WidgetTester tester) =>
    tapBundle(tester, find.byKey(const ValueKey('bundle-send')));
Future<void> openBundleDetail(WidgetTester tester, BundleOffice state) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOfficeForwardBundleDetails(
              context,
              state,
              'target-a',
              state.card,
            ),
            child: const Text('展开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('展开'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'fresh sources post native revisions and automatically return a validated receipt',
    (tester) async {
      final state = BundleOffice();
      Json? delivered;
      await openBundleComposer(
        tester,
        state,
        messages: [
          {'id': 'm1'},
          {'id': 'm2'},
        ],
        onResult: (r) => delivered = r,
      );
      expect(find.textContaining('第一条原文'), findsOneWidget);
      await selectA(tester);
      await sendBundle(tester);
      expect(delivered?['bundle']['id'], 'bundle-native');
      expect(find.byType(OfficeMergedForwardComposer), findsNothing);
      expect(state.posts.single['data']['base_revisions'], {'m1': 3, 'm2': 4});
      expect(state.posts.single['data']['message_ids'], ['m1', 'm2']);
    },
  );
  testWidgets(
    'multi target Agent mention and comment share one native intent',
    (tester) async {
      final state = BundleOffice(kind: 'agent');
      await openBundleComposer(tester, state);
      await tapBundle(tester, find.text('切换多选'));
      await selectA(tester);
      await tapBundle(
        tester,
        find.byKey(const ValueKey('bundle-target-target-b')),
      );
      await tapBundle(tester, find.text('@ 人或 Agent'));
      await tester.tap(find.text('Agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('机伴'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bundle-comment')),
        '请一起核对',
      );
      await sendBundle(tester);
      final data = state.posts.single['data'];
      expect(data['target_room_ids'], ['target-a', 'target-b']);
      expect(data['mentions'], ['agent']);
      expect(data['comment'], '@机伴 请一起核对');
    },
  );
  testWidgets(
    'cancel returns null without changing selection or issuing writes',
    (tester) async {
      final state = BundleOffice();
      var called = false;
      Json? result;
      await openBundleComposer(
        tester,
        state,
        onResult: (value) {
          called = true;
          result = value;
        },
      );
      await selectA(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(called, isTrue);
      expect(result, isNull);
      expect(state.posts, isEmpty);
      expect(state.sources.length, 2);
    },
  );
  testWidgets('changed source is previewed again before any POST', (
    tester,
  ) async {
    final state = BundleOffice();
    await openBundleComposer(tester, state);
    await selectA(tester);
    state.sources[0] = BundleOffice.source('m1', '更新后的正文', 5);
    await sendBundle(tester);
    expect(state.posts, isEmpty);
    expect(find.text('来源消息已更新，请核对预览后再次发送。'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(find.textContaining('更新后的正文'), findsOneWidget);
    await sendBundle(tester);
    expect(state.posts.single['data']['base_revisions']['m1'], 5);
  });
  testWidgets('protected sources block sending from stale caller previews', (
    tester,
  ) async {
    final state = BundleOffice();
    state.sources[0]['no_forward'] = true;
    await openBundleComposer(tester, state);
    expect(find.textContaining('来源消息禁止转发'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('bundle-send')))
          .onPressed,
      isNull,
    );
    expect(state.posts, isEmpty);
  });
  testWidgets(
    'lost success recovers before source revision checks and never resends',
    (tester) async {
      final state = BundleOffice()..loseSuccess = true;
      Json? result;
      await openBundleComposer(tester, state, onResult: (r) => result = r);
      await selectA(tester);
      await sendBundle(tester);
      expect(find.text('重试确认原请求'), findsOneWidget);
      state.sources[0]['retracted_at'] = '2026-09-07T00:02:00Z';
      await sendBundle(tester);
      expect(state.posts.length, 1);
      expect(result?['recovered'], isTrue);
      expect(
        state.requests.last['path'],
        contains('forward-bundle-receipts?client_id='),
      );
    },
  );
  testWidgets(
    'unknown outcome without a receipt retries the identical frozen payload',
    (tester) async {
      final state = BundleOffice()..postFailure = TimeoutException('offline');
      await openBundleComposer(tester, state);
      await selectA(tester);
      await sendBundle(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bundle-comment')))
            .enabled,
        isFalse,
      );
      await sendBundle(tester);
      expect(state.posts.length, 2);
      expect(state.posts[1]['data'], state.posts[0]['data']);
    },
  );
  testWidgets(
    'reopening pending intent retrieves its receipt without a second POST',
    (tester) async {
      final state = BundleOffice()..loseSuccess = true;
      await openBundleComposer(tester, state);
      await selectA(tester);
      await sendBundle(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开合并'));
      await tester.pumpAndSettle();
      expect(state.posts.length, 1);
      expect(find.byType(OfficeMergedForwardComposer), findsNothing);
    },
  );
  testWidgets('malformed delivery never becomes success or a fresh intent', (
    tester,
  ) async {
    final state = BundleOffice()..malformedReceipt = true;
    Json? result;
    await openBundleComposer(tester, state, onResult: (r) => result = r);
    await selectA(tester);
    await sendBundle(tester);
    expect(result, isNull);
    expect(find.text('重试确认原请求'), findsOneWidget);
    await sendBundle(tester);
    expect(state.posts.length, 1);
    expect(result, isNull);
  });
  testWidgets('identity changes stop follow-on reads after the room request', (
    tester,
  ) async {
    final state = BundleOffice()
      ..pendingGetPath = '/rooms'
      ..pendingGet = Completer<Json>();
    await openBundleComposer(tester, state);
    state.changeIdentity();
    state.pendingGet!.complete({'rooms': state.rooms});
    await tester.pumpAndSettle();
    expect(state.requests.length, 1);
    expect(find.text('工作身份已变更，请重新打开。'), findsOneWidget);
  });
  testWidgets('identity changes stop further source batches', (tester) async {
    final state = BundleOffice();
    state.sources = [
      for (var i = 0; i < 8; i++) BundleOffice.source('m$i', '正文 $i', 1),
    ];
    state.pendingGetPath = '/rooms/source/messages/m0';
    state.pendingGet = Completer<Json>();
    await openBundleComposer(tester, state);
    state.changeIdentity();
    state.pendingGet!.complete({'message': state.sources.first});
    await tester.pumpAndSettle();
    expect(
      state.requests
          .where((r) => r['path'].toString().contains('/messages/'))
          .length,
      5,
    );
    expect(find.textContaining('正文'), findsNothing);
  });
  testWidgets(
    'late POST does not close or disclose a receipt to a new identity',
    (tester) async {
      final state = BundleOffice()..pendingPost = Completer<Json>();
      Json? result;
      await openBundleComposer(tester, state, onResult: (r) => result = r);
      await selectA(tester);
      await tester.tap(find.byKey(const ValueKey('bundle-send')));
      await tester.pump();
      state.changeIdentity();
      state.pendingPost!.complete(
        state.deliveryReceipt(state.posts.single['data']),
      );
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('工作身份已变更，请重新打开。'), findsOneWidget);
    },
  );
  testWidgets(
    'permission failure clears stale preview and requires fresh verification',
    (tester) async {
      final state = BundleOffice()
        ..postFailure = OfficeException(403, '目标成员资格变化');
      await openBundleComposer(tester, state);
      await selectA(tester);
      await sendBundle(tester);
      expect(find.textContaining('第一条原文'), findsNothing);
      expect(find.text('重试确认原请求'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('bundle-send')))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'mobile keyboard leaves cancel and send in the available viewport',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openBundleComposer(
        tester,
        BundleOffice(),
        viewInsets: const EdgeInsets.only(bottom: 300),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('bundle-send'))).bottom,
        lessThanOrEqualTo(544),
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMergedForwardComposer), findsNothing);
    },
  );
  testWidgets(
    'details load authenticated shared records instead of card preview text',
    (tester) async {
      final state = BundleOffice();
      await openBundleDetail(tester, state);
      expect(find.text('从接口读取的原文'), findsOneWidget);
      expect(find.textContaining('仅列表预览'), findsNothing);
      expect(
        state.requests.single['path'],
        '/rooms/target-a/messages/delivery/forward-bundle',
      );
    },
  );
  testWidgets('identity changes erase displayed shared records', (
    tester,
  ) async {
    final state = BundleOffice();
    await openBundleDetail(tester, state);
    state.changeIdentity();
    await tester.pumpAndSettle();
    expect(find.text('从接口读取的原文'), findsNothing);
    expect(find.text('工作身份或聊天记录权限已变更，请重新打开。'), findsOneWidget);
  });
  testWidgets('late shared records are discarded after identity changes', (
    tester,
  ) async {
    final state = BundleOffice()
      ..pendingGetPath = '/rooms/target-a/messages/delivery/forward-bundle'
      ..pendingGet = Completer<Json>();
    await openBundleDetail(tester, state);
    state.changeIdentity();
    state.pendingGet!.complete(state.bundleDetail);
    await tester.pumpAndSettle();
    expect(find.text('从接口读取的原文'), findsNothing);
  });
  for (final malformed in [
    'attachment room',
    'non-map item',
    'nesting depth',
    'source provenance',
  ]) {
    testWidgets('invalid $malformed rejects the complete shared record', (
      tester,
    ) async {
      final state = BundleOffice();
      final bundle = state.bundleDetail['bundle'];
      if (malformed == 'attachment room') {
        bundle['items'][0]['attachments'] = [
          {'id': 'att-a', 'room_id': 'source', 'filename': 'private.txt'},
        ];
      } else if (malformed == 'non-map item') {
        bundle['items'] = <dynamic>['invalid', bundle['items'][1]];
      } else if (malformed == 'source provenance') {
        bundle['items'][0].remove('source_message_id');
      } else {
        var item = bundle['items'][0];
        for (var i = 0; i < 3; i++) {
          item['kind'] = 'forward_bundle';
          item['forward_bundle'] = {
            'title': 'nested',
            'message_count': 1,
            'items': [BundleOffice.item('nested$i', 'too deep')],
          };
          item = item['forward_bundle']['items'][0];
        }
      }
      await openBundleDetail(tester, state);
      expect(find.text('从接口读取的原文'), findsNothing);
      expect(find.text('第二条真实快照'), findsNothing);
      expect(find.text('private.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('nested cards expand actual source records', (tester) async {
    final state = BundleOffice();
    final first = state.bundleDetail['bundle']['items'][0];
    first['kind'] = 'forward_bundle';
    first['forward_bundle'] = {
      'title': '嵌套讨论',
      'message_count': 1,
      'items': [BundleOffice.item('nested-message', '嵌套原文')],
    };
    await openBundleDetail(tester, state);
    expect(find.text('嵌套原文'), findsNothing);
    await tapBundle(tester, find.text('嵌套讨论 · 1 条'));
    expect(find.text('嵌套原文'), findsOneWidget);
  });
  testWidgets('revoked access has no synthetic text fallback', (tester) async {
    final state = BundleOffice()
      ..readFailure = OfficeException(403, '已不是接收会话成员');
    await openBundleDetail(tester, state);
    expect(find.textContaining('已不是接收会话成员'), findsOneWidget);
    expect(find.text('从接口读取的原文'), findsNothing);
  });
  testWidgets('hidden cards cannot open shared snapshots', (tester) async {
    final state = BundleOffice()..hiddenCard = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfficeForwardBundleCard(
            state: state,
            roomId: 'target-a',
            message: state.card,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('聊天记录暂不可用'), findsOneWidget);
    expect(state.requests, isEmpty);
  });
  test('copy includes verified provenance, nested body and attachment names without source-room reads', () async {
    final state = BundleOffice();
    final first = state.bundleDetail['bundle']['items'][0];
    first['kind'] = 'forward_bundle';
    first['forward_bundle'] = {
      'title': '嵌套讨论',
      'message_count': 1,
      'items': [BundleOffice.item('nested-message', '嵌套原文')],
    };
    first['forward_bundle']['items'][0]['attachments'] = [
      {'id': 'att-target', 'room_id': 'target-a', 'filename': '计划.pdf'},
    ];
    final copied = await officeForwardBundleCopyText(
      state,
      'target-a',
      state.card,
    );
    for (final text in [
      '附言',
      '同事',
      '2026-09-07T00:01:00Z',
      '从接口读取的原文',
      '嵌套原文',
      '计划.pdf',
    ]) {
      expect(copied, contains(text));
    }
    expect(state.requests.map((r) => r['path']), [
      '/rooms/target-a/messages/delivery',
      '/rooms/target-a/messages/delivery/forward-bundle',
    ]);
  });
  test('copy fails when fresh current card is hidden', () async {
    final state = BundleOffice();
    final original = state.card;
    state.hiddenCard = true;
    await expectLater(
      officeForwardBundleCopyText(state, 'target-a', original),
      throwsFormatException,
    );
    expect(state.requests.length, 1);
  });
  test('copy stops between requests when identity is replaced', () async {
    final state = BundleOffice()
      ..pendingGetPath = '/rooms/target-a/messages/delivery'
      ..pendingGet = Completer<Json>();
    final future = officeForwardBundleCopyText(state, 'target-a', state.card);
    final expectation = expectLater(future, throwsStateError);
    state.changeIdentity();
    state.pendingGet!.complete({'message': state.card});
    await expectation;
    expect(state.requests.length, 1);
  });
}
