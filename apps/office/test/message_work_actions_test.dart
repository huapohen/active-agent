import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_work_actions.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json workMessage(String id, {int revision = 1, String kind = 'human'}) => {
  'id': id,
  'revision': revision,
  'content': '来源正文 $id :feishu:SMILE: 👩🏽‍💻',
  'author_id': 'author-$kind',
  'author': {'id': 'author-$kind', 'name': '作者 $kind', 'kind': kind},
  'at': '2026-09-06T14:00:00Z',
  'room_id': 'room-a',
  'attachments': <Json>[],
};

Json clone(Json value) => Json.from(jsonDecode(jsonEncode(value)) as Map);

class WorkFixture extends OfficeState {
  WorkFixture({String kind = 'human', int count = 1}) {
    endpoint = 'https://work.invalid';
    me = {'id': 'self', 'kind': kind, 'name': '工作身份'};
    selectedRoomId = 'room-a';
    connected = true;
    source = List.generate(count, (i) => workMessage('msg-$i'));
  }
  late List<Json> source;
  List<Json> people = [
    {'principal_id': 'person-a', 'name': '人类同事', 'kind': 'human'},
    {'principal_id': 'agent-a', 'name': 'Agent 同事', 'kind': 'agent'},
  ];
  final reads = <String>[], posts = <Json>[];
  int generation = 0;
  OfficeException? getFailure, postFailure;
  Completer<void>? holdGets;
  Completer<Json>? holdPost;
  bool failPostOnce = false;
  List<Json> operations = [], existingTasks = [];
  Json? existingDocument;
  @override
  int get identityGeneration => generation;
  void emit() => notifyListeners();

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (method == 'POST') {
      posts.add({'path': path, 'body': clone(data!)});
      if (holdPost != null) return holdPost!.future;
      if (postFailure != null) {
        final error = postFailure!;
        if (failPostOnce) postFailure = null;
        throw error;
      }
      final export = path.endsWith('export-document');
      return {
        export ? 'document' : 'task': {
          'id': export ? 'document-created' : 'task-created',
          'title': data['title'],
          'revision': 1,
          'source_message_ids': data['message_ids'],
          'content':
              '${source.map((s) => s['content']).join('\n')}\n${data['content'] ?? data['description']}',
        },
        'source_message_ids': data['message_ids'],
      };
    }
    expect(method, 'GET');
    expect(data, isNull);
    reads.add(path);
    if (holdGets != null) await holdGets!.future;
    if (getFailure != null) throw getFailure!;
    if (path.contains('/messages/source-operations?')) {
      return {'operations': operations, 'truncated': false};
    }
    if (path.contains('/documents/')) {
      return {'document': existingDocument};
    }
    if (path == '/rooms/room-a') {
      return {
        'room': {'id': 'room-a'},
        'members': people,
        'tasks': existingTasks,
      };
    }
    final id = Uri.decodeComponent(path.split('/').last);
    return {'message': clone(source.firstWhere((s) => s['id'] == id))};
  }

  @override
  Future<void> createTask(
    String title, {
    String description = '',
    String? assigneeId,
    String? roomId,
  }) async {
    fail('Source actions must use the atomic native command, not createTask');
  }

  @override
  Future<Json> saveDocument({
    String? id,
    required String title,
    required String content,
    int? baseRevision,
    String? roomId,
  }) async {
    fail('Source actions must use the atomic native command, not saveDocument');
  }
}

Future<void> mountWork(
  WidgetTester tester,
  WorkFixture state, {
  bool export = false,
  Size size = const Size(1024, 1000),
  ValueChanged<Json?>? onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              final result = export
                  ? await showOfficeMessageExport(
                      context,
                      state,
                      'room-a',
                      state.source.map(clone).toList(),
                    )
                  : await showOfficeMessageTask(
                      context,
                      state,
                      'room-a',
                      state.source.map(clone).toList(),
                    );
              onResult?.call(result);
            },
            child: const Text('打开消息操作'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开消息操作'));
  await tester.pumpAndSettle();
}

TextField titleField(WidgetTester t) =>
    t.widget(find.byKey(const ValueKey('message-work-title')));
TextField bodyField(WidgetTester t) =>
    t.widget(find.byKey(const ValueKey('message-work-body')));
Future<void> submitWork(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('message-work-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Human and Agent task creators use frozen source room and atomic IDs with actual Agent assignee',
    (tester) async {
      for (final kind in ['human', 'agent']) {
        final state = WorkFixture(kind: kind, count: 2);
        Json? result;
        await mountWork(tester, state, onResult: (value) => result = value);
        expect(bodyField(tester).controller!.text, isEmpty);
        await tester.enterText(
          find.byKey(const ValueKey('message-work-title')),
          '评审跟进',
        );
        await tester.enterText(
          find.byKey(const ValueKey('message-work-body')),
          '补充 :feishu:THANKS: 👩🏽‍💻',
        );
        await tester.ensureVisible(find.text('待分配'));
        await tester.tap(find.text('待分配'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Agent 同事 · Agent').last);
        await tester.pumpAndSettle();
        state.selectedRoomId = 'different-room';
        state.emit();
        await submitWork(tester);
        expect(state.posts, hasLength(1));
        final post = state.posts.single;
        expect(post['path'], '/rooms/room-a/messages/create-task');
        final data = post['body'] as Json;
        expect(data['message_ids'], ['msg-0', 'msg-1']);
        expect(data['base_revisions'], {'msg-0': 1, 'msg-1': 1});
        expect(data['assignee_id'], 'agent-a');
        expect(data['description'], '补充 :feishu:THANKS: 👩🏽‍💻');
        expect(data['description'], isNot(contains('来源正文')));
        expect(data['client_id'], isNotEmpty);
        expect(
          state.reads.where((p) => p.endsWith('/messages/msg-0')),
          hasLength(2),
        );
        expect(find.text('任务已创建'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('message-work-success-title')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('message-work-close')));
        await tester.pumpAndSettle();
        expect(result?['id'], 'task-created');
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      }
    },
  );

  testWidgets(
    'mobile multi-message export returns the real document and retains raw tokens in server source',
    (tester) async {
      final state = WorkFixture(count: 2);
      Json? result;
      await mountWork(
        tester,
        state,
        export: true,
        size: const Size(430, 930),
        onResult: (v) => result = v,
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(titleField(tester).controller!.text, '聊天记录 · 2 条');
      await tester.enterText(
        find.byKey(const ValueKey('message-work-body')),
        '会议补充',
      );
      await submitWork(tester);
      expect(
        state.posts.single['path'],
        '/rooms/room-a/messages/export-document',
      );
      expect((state.posts.single['body'] as Json)['content'], '会议补充');
      expect(find.text('文档已创建'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('message-work-close')));
      await tester.pumpAndSettle();
      expect(result?['id'], 'document-created');
      expect(result?['content'], contains(':feishu:SMILE: 👩🏽‍💻'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final flag in ['no_forward', 'hidden', 'retracted_at']) {
    testWidgets(
      '$flag present at open suppresses source body and both creating actions',
      (tester) async {
        for (final export in [false, true]) {
          final state = WorkFixture();
          state.source[0][flag] = flag == 'retracted_at'
              ? '2026-09-06T14:02:00Z'
              : true;
          await mountWork(tester, state, export: export);
          expect(find.byKey(const ValueKey('message-work-body')), findsNothing);
          expect(
            find.byKey(const ValueKey('message-work-submit')),
            findsNothing,
          );
          expect(state.reads, isEmpty);
          expect(state.posts, isEmpty);
          await tester.pumpWidget(const SizedBox());
          state.dispose();
        }
      },
    );

    testWidgets(
      '$flag changed after opening is caught by fresh GET and cannot export stale draft',
      (tester) async {
        final state = WorkFixture();
        await mountWork(tester, state, export: true);
        await tester.enterText(
          find.byKey(const ValueKey('message-work-body')),
          '草稿',
        );
        state.source[0][flag] = flag == 'retracted_at'
            ? '2026-09-06T14:02:00Z'
            : true;
        await submitWork(tester);
        expect(state.posts, isEmpty);
        expect(find.byKey(const ValueKey('message-work-body')), findsNothing);
        expect(find.text('文档已创建'), findsNothing);
      },
    );
  }

  testWidgets(
    'source edit refreshes preview while preserving supplement and requires explicit second submit',
    (tester) async {
      final state = WorkFixture();
      await mountWork(tester, state);
      await tester.enterText(
        find.byKey(const ValueKey('message-work-body')),
        '人工补充',
      );
      state.source[0] = {...state.source[0], 'content': '新来源正文', 'revision': 2};
      await submitWork(tester);
      expect(state.posts, isEmpty);
      expect(bodyField(tester).controller!.text, '人工补充');
      expect(find.textContaining('来源消息已更新'), findsOneWidget);
      await submitWork(tester);
      expect((state.posts.single['body'] as Json)['base_revisions'], {
        'msg-0': 2,
      });
    },
  );

  testWidgets(
    'atomic 409 preserves draft and requires fresh source review before a new intent',
    (tester) async {
      final state = WorkFixture();
      state.postFailure = OfficeException(
        409,
        '来源版本发生变化',
        code: 'source_revision_conflict',
      );
      state.failPostOnce = true;
      await mountWork(tester, state, export: true);
      await tester.enterText(
        find.byKey(const ValueKey('message-work-body')),
        '不可丢失的说明',
      );
      await submitWork(tester);
      final firstId = (state.posts.single['body'] as Json)['client_id'];
      expect(bodyField(tester).controller!.text, '不可丢失的说明');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('message-work-submit')),
            )
            .onPressed,
        isNull,
      );
      state.source[0]['revision'] = 2;
      await tester.ensureVisible(find.text('重新核对来源'));
      await tester.tap(find.text('重新核对来源'));
      await tester.pumpAndSettle();
      expect(state.posts, hasLength(1));
      await submitWork(tester);
      final second = state.posts.last['body'] as Json;
      expect(second['client_id'], isNot(firstId));
      expect(second['base_revisions'], {'msg-0': 2});
      expect(second['content'], '不可丢失的说明');
    },
  );

  testWidgets(
    'unknown create outcome freezes editing and repeats exactly one client intent',
    (tester) async {
      final state = WorkFixture();
      state.postFailure = OfficeException(503, '连接中断');
      state.failPostOnce = true;
      await mountWork(tester, state);
      await tester.enterText(
        find.byKey(const ValueKey('message-work-body')),
        '原请求',
      );
      await submitWork(tester);
      final first = clone(state.posts.single['body'] as Json);
      expect(bodyField(tester).enabled, isFalse);
      expect(find.text('重试确认'), findsOneWidget);
      await submitWork(tester);
      expect(state.posts.last['body'], first);
      expect(find.text('任务已创建'), findsOneWidget);
    },
  );

  testWidgets(
    'closing an uncertain request retains its ID when the same source is reopened',
    (tester) async {
      final state = WorkFixture();
      state.postFailure = OfficeException(503, '请求结果未知');
      state.failPostOnce = true;
      await mountWork(tester, state, export: true);
      await tester.enterText(
        find.byKey(const ValueKey('message-work-title')),
        '冻结的标题',
      );
      await submitWork(tester);
      final first = clone(state.posts.single['body'] as Json);
      await tester.tap(find.byKey(const ValueKey('message-work-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开消息操作'));
      await tester.pumpAndSettle();
      expect(titleField(tester).controller!.text, '冻结的标题');
      expect(titleField(tester).enabled, isFalse);
      await submitWork(tester);
      expect(state.posts.last['body'], first);
    },
  );

  testWidgets(
    'GET failure during uncertain retry never discards the frozen earlier command',
    (tester) async {
      final state = WorkFixture();
      state.postFailure = OfficeException(503, '请求结果未知');
      state.failPostOnce = true;
      await mountWork(tester, state);
      await submitWork(tester);
      final first = clone(state.posts.single['body'] as Json);
      state.getFailure = OfficeException(403, '暂时无法核对来源');
      await submitWork(tester);
      expect(state.posts, hasLength(1));
      expect(titleField(tester).enabled, isFalse);
      state.getFailure = null;
      await submitWork(tester);
      expect(state.posts.last['body'], first);
    },
  );

  testWidgets(
    'pending server materialization is checked without issuing a second creation',
    (tester) async {
      final state = WorkFixture();
      state.postFailure = OfficeException(
        503,
        '创建结果待确认',
        code: 'outcome_pending',
      );
      state.failPostOnce = true;
      await mountWork(tester, state, export: true);
      await submitWork(tester);
      final first = state.posts.single['body'] as Json;
      state.operations = [
        {
          'client_id': first['client_id'],
          'room_id': 'room-a',
          'operation': 'export-document',
          'status': 'pending',
        },
      ];
      await submitWork(tester);
      expect(state.posts, hasLength(1));
      expect(find.textContaining('上次创建仍待确认'), findsOneWidget);
      expect(titleField(tester).enabled, isFalse);
    },
  );

  testWidgets(
    'completed unknown document is recovered from its actual resource even if sources were edited',
    (tester) async {
      final state = WorkFixture();
      state.postFailure = OfficeException(503, '响应丢失');
      state.failPostOnce = true;
      Json? returned;
      await mountWork(
        tester,
        state,
        export: true,
        onResult: (value) => returned = value,
      );
      await submitWork(tester);
      final first = state.posts.single['body'] as Json;
      state.operations = [
        {
          'client_id': first['client_id'],
          'room_id': 'room-a',
          'operation': 'export-document',
          'status': 'completed',
          'resource_id': 'real-document',
        },
      ];
      state.existingDocument = {
        'id': 'real-document',
        'title': '服务端已经创建的文档',
        'revision': 1,
      };
      state.source[0]['revision'] = 2;
      await submitWork(tester);
      expect(state.posts, hasLength(1));
      expect(find.text('文档已创建'), findsOneWidget);
      expect(find.text('服务端已经创建的文档'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('message-work-close')));
      await tester.pumpAndSettle();
      expect(returned?['id'], 'real-document');
    },
  );

  testWidgets(
    'idempotency conflict keeps original intent frozen instead of creating a new client ID',
    (tester) async {
      final state = WorkFixture();
      state.postFailure = OfficeException(
        409,
        '请求不匹配',
        code: 'idempotency_conflict',
      );
      state.failPostOnce = true;
      await mountWork(tester, state);
      await submitWork(tester);
      final first = clone(state.posts.single['body'] as Json);
      expect(titleField(tester).enabled, isFalse);
      expect(find.textContaining('请求标识与已保存的请求冲突'), findsOneWidget);
      await submitWork(tester);
      expect(state.posts.last['body'], first);
    },
  );

  testWidgets(
    'offline and GET errors preserve the draft and never create implicitly',
    (tester) async {
      final state = WorkFixture();
      await mountWork(tester, state);
      await tester.enterText(
        find.byKey(const ValueKey('message-work-body')),
        '离线草稿',
      );
      state.connected = false;
      state.emit();
      await tester.pump();
      expect(bodyField(tester).controller!.text, '离线草稿');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('message-work-submit')),
            )
            .onPressed,
        isNull,
      );
      state.connected = true;
      state.getFailure = OfficeException(403, '已不在来源会话');
      state.emit();
      await submitWork(tester);
      expect(bodyField(tester).controller!.text, '离线草稿');
      expect(state.posts, isEmpty);
      expect(find.text('任务已创建'), findsNothing);
    },
  );

  testWidgets(
    'identity generation A-B-A during reads permanently expires old source and draft',
    (tester) async {
      final state = WorkFixture();
      await mountWork(tester, state);
      await tester.enterText(
        find.byKey(const ValueKey('message-work-body')),
        '旧身份正文',
      );
      state.holdGets = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('message-work-submit')));
      await tester.pump();
      state.generation++;
      state.emit();
      state.generation++;
      state.emit();
      state.holdGets!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('工作身份或消息来源已变化'), findsOneWidget);
      expect(find.byKey(const ValueKey('message-work-body')), findsNothing);
      expect(state.posts, isEmpty);
    },
  );

  testWidgets(
    'late create response after identity change cannot show a success or close underlying page',
    (tester) async {
      final state = WorkFixture();
      await mountWork(tester, state, export: true);
      state.holdPost = Completer<Json>();
      await tester.tap(find.byKey(const ValueKey('message-work-submit')));
      await tester.pumpAndSettle();
      state.generation++;
      state.emit();
      state.holdPost!.complete({
        'document': {'id': 'old-document', 'title': '旧身份'},
      });
      await tester.pumpAndSettle();
      expect(find.text('文档已创建'), findsNothing);
      expect(find.textContaining('工作身份或消息来源已变化'), findsOneWidget);
      expect(find.text('打开消息操作'), findsOneWidget);
    },
  );

  testWidgets(
    'closing while create is pending is safe and retry can recover the same intent',
    (tester) async {
      final state = WorkFixture();
      await mountWork(tester, state);
      state.holdPost = Completer<Json>();
      await tester.tap(find.byKey(const ValueKey('message-work-submit')));
      await tester.pumpAndSettle();
      final first = clone(state.posts.single['body'] as Json);
      await tester.tap(find.byKey(const ValueKey('message-work-close')));
      await tester.pumpAndSettle();
      state.holdPost!.complete({
        'task': {'id': 'completed-in-background', 'title': '完成'},
      });
      await tester.pumpAndSettle();
      state.holdPost = null;
      await tester.tap(find.text('打开消息操作'));
      await tester.pumpAndSettle();
      await submitWork(tester);
      expect(state.posts.last['body'], first);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removed assignee requires explicit new selection before creating',
    (tester) async {
      final state = WorkFixture();
      await mountWork(tester, state);
      await tester.ensureVisible(find.text('待分配'));
      await tester.tap(find.text('待分配'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('人类同事 · 人类').last);
      await tester.pumpAndSettle();
      state.people.removeAt(0);
      await submitWork(tester);
      expect(state.posts, isEmpty);
      expect(find.textContaining('原负责人已不在来源会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('more than fifty sources is rejected without issuing requests', (
    tester,
  ) async {
    final state = WorkFixture(count: 51);
    await mountWork(tester, state, export: true);
    expect(find.textContaining('1–50'), findsOneWidget);
    expect(state.reads, isEmpty);
    expect(state.posts, isEmpty);
  });
}
