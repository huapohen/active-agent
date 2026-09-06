import 'dart:convert';

import 'package:active_office/minutes_api.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/minutes.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const roomId = 'room-00000000-0000-0000-0000-000000000001';
const minuteId = 'minute-00000000-0000-0000-0000-000000000001';
const documentId = 'doc-00000000-0000-0000-0000-000000000001';
const meetingId = 'meeting-00000000-0000-0000-0000-000000000001';
const createdAt = '2026-09-06T09:00:00.000Z';
Json copy(Json value) => Json.from(jsonDecode(jsonEncode(value)));

Json minuteFixture({bool audio = false}) => {
  'id': minuteId,
  'room_id': roomId,
  'title': audio ? '待补充文字的录音' : '项目讨论记录',
  'revision': 1,
  'created_by': 'human-fixture',
  'updated_by': 'human-fixture',
  'created_at': createdAt,
  'updated_at': createdAt,
  'meeting_id': meetingId,
  'document_id': null,
  'task_ids': <String>[],
  'audio_attachment_id': audio ? 'attachment-fixture' : null,
  if (audio)
    'audio_attachment': {
      'id': 'attachment-fixture',
      'filename': 'discussion.wav',
      'mime_type': 'audio/wav',
      'bytes': 44,
    },
  'transcript': audio
      ? <Json>[]
      : [
          {'speaker_label': '项目同事', 'offset_ms': 12000, 'text': '确认共同目标。'},
          {
            'speaker_label': '协作 Agent',
            'offset_ms': 80000,
            'text': '整理可核对的行动项。',
          },
        ],
};

/// Mock only the authenticated transport boundary; the real API adapter, UI,
/// transcript parser and document dialog run without an external service.
class MockMinutesOfficeState extends OfficeState {
  MockMinutesOfficeState({Json? initialMinute, this.conflictOnce = false}) {
    endpoint = 'https://minutes-ui-fixture.example';
    me = {'id': 'human-fixture', 'name': '项目同事', 'kind': 'human'};
    connected = true;
    rooms = [
      {'id': roomId, 'name': '共同项目', 'kind': 'group'},
    ];
    selectedRoomId = roomId;
    meetings = [
      {'id': meetingId, 'room_id': roomId, 'title': '每周协作会'},
    ];
    minute = initialMinute == null ? null : copy(initialMinute);
  }

  Json? minute, document;
  bool conflictOnce;
  int documentReads = 0;
  final calls = <Json>[];
  List<Json> requests(String method, String path) => calls
      .where((call) => call['method'] == method && call['path'] == path)
      .toList();

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    calls.add({
      'path': path,
      'method': method,
      'data': data == null ? null : copy(data),
    });
    if (method == 'GET' && path.startsWith('/minutes?q=')) {
      final summary = minute == null ? null : copy(minute!);
      if (summary != null) {
        final segments = (summary.remove('transcript') as List).length;
        summary['segment_count'] = segments;
        summary['transcript_count'] = segments;
      }
      return {
        'minutes': [?summary],
      };
    }
    if (method == 'GET' && path == '/minutes/$minuteId') {
      return {'minute': copy(minute!)};
    }
    if (method == 'POST' && path == '/rooms/$roomId/minutes') {
      expect(data!.keys.toSet(), {
        'client_id',
        'title',
        'transcript',
        'meeting_id',
        'audio_attachment_id',
      });
      expect(data['client_id'], isA<String>());
      expect((data['client_id'] as String).isNotEmpty, isTrue);
      minute = {...minuteFixture(), ...copy(data)}..remove('client_id');
      return {'minute': copy(minute!)};
    }
    if (method == 'POST' && path == '/rooms/$roomId/documents') {
      expect(data!.keys.toSet(), {'client_id', 'title', 'content'});
      expect(data['client_id'], isA<String>());
      document = {
        'id': documentId,
        'room_ids': [roomId],
        'title': data['title'],
        'content': data['content'],
        'revision': 1,
        'updated_at': createdAt,
      };
      return {'document': copy(document!)};
    }
    if (method == 'PATCH' && path == '/minutes/$minuteId') {
      expect(data!.keys.toSet(), {'base_revision', 'document_id'});
      expect(data['document_id'], documentId);
      if (conflictOnce) {
        conflictOnce = false;
        minute!['revision'] = 2;
        throw OfficeException(409, '妙记已更新，请保留本地编辑并读取最新版本', code: 'conflict');
      }
      expect(data['base_revision'], minute!['revision']);
      minute = {
        ...minute!,
        'document_id': data['document_id'],
        'revision': (minute!['revision'] as int) + 1,
      };
      return {'minute': copy(minute!)};
    }
    fail('Unexpected minutes transport request: $method $path');
  }

  @override
  Future<Json> getDocument(String id, {required String roomId}) async {
    expect(id, documentId);
    expect(roomId, expectedRoomId);
    documentReads++;
    return copy(document!);
  }
}

// Avoid hiding the fixture room constant with the override's named parameter.
const expectedRoomId = roomId;

Finder input(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> waitForDocumentDialog(WidgetTester tester) async {
  // The underlying route shows a progress animation while the modal is open;
  // wait for its actual content rather than waiting for all animations to stop.
  for (
    var attempt = 0;
    attempt < 10 && find.byTooltip('关闭文档').evaluate().isEmpty;
    attempt++
  ) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byTooltip('关闭文档'), findsOneWidget);
}

Future<void> showMinutes(
  WidgetTester tester,
  MockMinutesOfficeState state,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(body: OfficeMinutes(state: state)),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: '390px library must fit');
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    state.dispose();
  });
}

void main() {
  test(
    'Transcript parser retains speakers and time, including inherited offsets',
    () {
      final parsed = parseMinutesTranscript(
        '[00:12] 项目同事：确认目标\n\n[01:02:03] Agent: 核对依据\n继续记录未标注发言人的内容',
      );
      expect(parsed, [
        {'speaker_label': '项目同事', 'offset_ms': 12000, 'text': '确认目标'},
        {'speaker_label': 'Agent', 'offset_ms': 3723000, 'text': '核对依据'},
        {
          'speaker_label': '未标注发言人',
          'offset_ms': 3723000,
          'text': '继续记录未标注发言人的内容',
        },
      ]);
      expect(
        parseMinutesTranscript(minutesTranscriptText({'transcript': parsed})),
        parsed,
      );
    },
  );

  test('Transcript parser rejects reversed timestamps before saving', () {
    expect(
      () => parseMinutesTranscript('[02:00] 同事：先记录\n[01:59] Agent：倒序记录'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseMinutesTranscript('[00:60] 同事：无效秒数'),
      throwsFormatException,
    );
  });

  testWidgets(
    '390px create form saves real minutes contract and opens transcript',
    (tester) async {
      final state = MockMinutesOfficeState();
      await showMinutes(tester, state);
      await tester.tap(find.text('新建人机妙记'));
      await tester.pumpAndSettle();
      await tester.enterText(input('妙记标题'), '周会共同记录');
      await tester.enterText(
        input('文字记录'),
        '[00:12] 项目同事：确认共同目标。\n[01:20] 协作 Agent：整理可核对的行动项。',
      );
      await tester.tap(find.text('不关联会议'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每周协作会').last);
      await tester.pumpAndSettle();
      final save = find.text('保存妙记');
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(844));
      await tester.tap(save);
      await tester.pumpAndSettle();
      final posted =
          state.requests('POST', '/rooms/$roomId/minutes').single['data']
              as Json;
      expect(posted['title'], '周会共同记录');
      expect(posted['meeting_id'], meetingId);
      expect(posted['audio_attachment_id'], isNull);
      expect(posted['transcript'], minuteFixture()['transcript']);
      expect(find.text('周会共同记录'), findsOneWidget);
      expect(find.text('00:12'), findsOneWidget);
      expect(find.text('01:20'), findsOneWidget);
      expect(find.text('确认共同目标。'), findsOneWidget);
      expect(find.text('每周协作会'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Phone keyboard and validation keep an unsaved transcript editable',
    (tester) async {
      final state = MockMinutesOfficeState();
      await showMinutes(tester, state);
      await tester.tap(find.text('新建人机妙记'));
      await tester.pumpAndSettle();
      await tester.enterText(input('妙记标题'), '保留正在编辑的记录');
      const draft = '[02:00] 同事：先记录\n[01:59] Agent：待修正的时间';
      await tester.enterText(input('文字记录'), draft);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'The create form must fit above a mobile keyboard',
      );
      final save = find.text('保存妙记');
      await tester.ensureVisible(save);
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(544));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.textContaining('逐字稿时间需按先后排列'), findsOneWidget);
      expect(tester.widget<TextField>(input('文字记录')).controller!.text, draft);
      expect(state.requests('POST', '/rooms/$roomId/minutes'), isEmpty);
      expect(
        tester.takeException(),
        isNull,
        reason: 'Validation message must fit while the keyboard is open',
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭妙记编辑'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    '390px detail creates and links a shared document with the saved transcript',
    (tester) async {
      final state = MockMinutesOfficeState(initialMinute: minuteFixture());
      await showMinutes(tester, state);
      expect(find.textContaining('2 段记录'), findsOneWidget);
      await tester.tap(find.text('项目讨论记录'));
      await tester.pumpAndSettle();
      expect(state.requests('GET', '/minutes/$minuteId'), hasLength(1));
      expect(find.text('协作 Agent'), findsOneWidget);
      await tester.tap(find.text('转为共同纪要'));
      await waitForDocumentDialog(tester);
      final created =
          state.requests('POST', '/rooms/$roomId/documents').single['data']
              as Json;
      expect(created['title'], '项目讨论记录 · 共同纪要');
      expect(created['content'], contains('[00:12] 项目同事：确认共同目标。'));
      expect(created['content'], contains('[01:20] 协作 Agent：整理可核对的行动项。'));
      expect(created['content'], contains('不是自动生成的 AI 摘要'));
      expect(state.requests('PATCH', '/minutes/$minuteId').single['data'], {
        'base_revision': 1,
        'document_id': documentId,
      });
      expect(find.text('共同文档'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭文档'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开共同纪要'));
      await waitForDocumentDialog(tester);
      expect(state.documentReads, 1);
      expect(state.requests('POST', '/rooms/$roomId/documents'), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭文档'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Document association conflict retains the created document and retries after refresh',
    (tester) async {
      final state = MockMinutesOfficeState(
        initialMinute: minuteFixture(),
        conflictOnce: true,
      );
      await showMinutes(tester, state);
      await tester.tap(find.text('项目讨论记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转为共同纪要'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已创建的文档已保留'), findsOneWidget);
      expect(find.text('共同文档'), findsNothing);
      expect(state.document, isNotNull);
      expect(state.minute!['document_id'], isNull);
      await tester.tap(find.byTooltip('刷新这份妙记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转为共同纪要'));
      await waitForDocumentDialog(tester);
      expect(state.requests('POST', '/rooms/$roomId/documents'), hasLength(1));
      expect(
        state.requests('PATCH', '/minutes/$minuteId').map((c) => c['data']),
        [
          {'base_revision': 1, 'document_id': documentId},
          {'base_revision': 2, 'document_id': documentId},
        ],
      );
      expect(state.minute!['document_id'], documentId);
      expect(find.text('共同文档'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭文档'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Saved audio without a transcription service stays empty and cannot delegate fabricated text',
    (tester) async {
      final state = MockMinutesOfficeState(
        initialMinute: minuteFixture(audio: true),
      );
      await showMinutes(tester, state);
      await tester.tap(find.text('待补充文字的录音'));
      await tester.pumpAndSettle();
      expect(find.text('录音文件已保存'), findsOneWidget);
      expect(find.textContaining('转写服务尚未配置'), findsOneWidget);
      expect(find.textContaining('还没有文字记录'), findsOneWidget);
      expect(find.text('0 段'), findsOneWidget);
      final delegate = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Agent 整理'),
      );
      expect(delegate.onPressed, isNull);
      expect(state.calls.every((call) => call['method'] == 'GET'), isTrue);
      expect(find.textContaining('转写成功'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
