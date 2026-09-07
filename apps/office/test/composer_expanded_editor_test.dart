import 'dart:async';

import 'package:active_office/office_state.dart' hide Json;
import 'package:active_office/ui/composer_expanded_editor.dart';
import 'package:active_office/ui/office_emoji.dart';
import 'package:active_office/ui/office_rich_text.dart';
import 'package:active_office/ui/office_theme.dart' show Json, officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json span(int start, int end, List<String> styles) => {
  'start': start,
  'end': end,
  'styles': styles,
};
Json rich(List<Json> spans) => {'version': 1, 'spans': spans};

class ExpandedOffice extends OfficeState {
  ExpandedOffice() {
    endpoint = 'https://expanded.example';
    connected = true;
    me = {'id': 'human-self', 'kind': 'human', 'name': '自己'};
    selectedRoomId = 'room-one';
    detail = {
      'room': {'id': 'room-one', 'kind': 'group', 'name': '人机协作'},
    };
  }
  int generation = 1;
  final requests = <Json>[];
  Completer<Json>? pendingMembers;
  Json? memberResult;
  @override
  int get identityGeneration => generation;
  void expire({bool room = false}) {
    if (room) {
      selectedRoomId = 'room-two';
    } else {
      generation++;
    }
    notifyListeners();
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    requests.add({'path': path, 'method': method, 'data': data});
    if (path == '/rooms/room-one') {
      if (pendingMembers != null) return pendingMembers!.future;
      return memberResult ??
          {
            ...detail!,
            'members': [
              me!,
              {'id': 'human-peer', 'kind': 'human', 'name': '人类同事'},
              {'id': 'agent-peer', 'kind': 'agent', 'name': 'Agent 同事'},
            ],
          };
    }
    if (path == '/emoji/recents') return {'emoji_ids': <String>[]};
    throw StateError('Unexpected request: $method $path');
  }
}

Future<void> openExpanded(
  WidgetTester tester,
  ExpandedOffice state, {
  String content = '正文',
  Json? richText,
  String title = '',
  List<String> mentions = const [],
  bool mentionAll = false,
  bool mobile = true,
  Future<void> Function()? onPickAttachments,
  List<String> Function()? attachmentNames,
  OfficeExpandedAgentEntry? onAgent,
  required ValueChanged<OfficeExpandedDraft?> result,
}) async {
  tester.view.physicalSize = mobile
      ? const Size(390, 844)
      : const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result(
              await showOfficeExpandedComposer(
                context,
                state: state,
                value: OfficeRichTextValue(
                  content: content,
                  richText: richText,
                ),
                title: title,
                mentions: mentions,
                mentionAll: mentionAll,
                mobile: mobile,
                onPickAttachments: onPickAttachments,
                attachmentNames: attachmentNames,
                onAgent: onAgent,
              ),
            ),
            child: const Text('打开展开输入框'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开展开输入框'));
  await tester.pumpAndSettle();
}

Finder key(String id) => find.byKey(ValueKey('expanded-$id'));
OfficeRichTextEditingController body(WidgetTester tester) =>
    tester.widget<TextField>(key('body')).controller!
        as OfficeRichTextEditingController;
TextEditingController titleController(WidgetTester tester) =>
    tester.widget<TextField>(key('title')).controller!;
Future<void> action(WidgetTester tester, String id) async {
  await tester.tap(key(id));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'mobile fills the view and keeps all controls above the keyboard',
    (tester) async {
      final state = ExpandedOffice();
      await openExpanded(tester, state, result: (_) {});
      expect(
        tester.getRect(find.byType(Dialog)),
        const Rect.fromLTWH(0, 0, 390, 844),
      );
      expect(find.text('无标题'), findsOneWidget);
      for (final id in [
        'collapse',
        'body',
        'emoji',
        'mention',
        'images',
        'format',
        'indent',
        'outdent',
        'agent',
        'send',
      ]) {
        expect(key(id), findsOneWidget);
      }
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(key('send')).dy, lessThanOrEqualTo(544));
      expect(tester.getSize(key('body')).height, greaterThan(300));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collapse returns edited title and real styles with UTF16 positions',
    (tester) async {
      OfficeExpandedDraft? result;
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: '😀正文',
        richText: rich([
          span(2, 4, ['italic']),
        ]),
        result: (v) => result = v,
      );
      await tester.enterText(key('title'), '  😀计划 复盘  ');
      await action(tester, 'collapse');
      expect(result!.title, '😀计划 复盘');
      expect(result!.value.content, '😀计划 复盘\n😀正文');
      final prefix = '${result!.title}\n'.length;
      expect(
        result!.value.richText,
        rich([
          span(0, result!.title.length, ['bold']),
          span(prefix + 2, prefix + 4, ['italic']),
        ]),
      );
      expect(result!.sendRequested, isFalse);
    },
  );

  testWidgets(
    'reopening separates remembered title once and preserves body formatting',
    (tester) async {
      OfficeExpandedDraft? result;
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: '计划\n正文',
        title: '计划',
        richText: rich([
          span(0, 2, ['bold']),
          span(3, 5, ['underline']),
        ]),
        result: (v) => result = v,
      );
      expect(titleController(tester).text, '计划');
      expect(body(tester).text, '正文');
      expect(
        body(tester).richText,
        rich([
          span(0, 2, ['underline']),
        ]),
      );
      await action(tester, 'collapse');
      expect(result!.value.content, '计划\n正文');
      expect(
        result!.value.richText,
        rich([
          span(0, 2, ['bold']),
          span(3, 5, ['underline']),
        ]),
      );
    },
  );

  testWidgets('clearing remembered title removes only its prefix', (
    tester,
  ) async {
    OfficeExpandedDraft? result;
    await openExpanded(
      tester,
      ExpandedOffice(),
      content: '计划\n正文',
      title: '计划',
      richText: rich([
        span(0, 2, ['bold']),
        span(3, 5, ['italic']),
      ]),
      result: (v) => result = v,
    );
    await tester.enterText(key('title'), '');
    await action(tester, 'collapse');
    expect(result!.title, '');
    expect(result!.value.content, '正文');
    expect(
      result!.value.richText,
      rich([
        span(0, 2, ['italic']),
      ]),
    );
  });

  testWidgets(
    'mismatched remembered title cannot consume the draft first line',
    (tester) async {
      OfficeExpandedDraft? result;
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: '新的标题\n正文',
        title: '旧标题',
        result: (v) => result = v,
      );
      expect(titleController(tester).text, '');
      expect(body(tester).text, '新的标题\n正文');
      await action(tester, 'collapse');
      expect(result!.value.content, '新的标题\n正文');
      expect(result!.title, '');
    },
  );

  testWidgets('desktop cancel returns null while complete retains draft', (
    tester,
  ) async {
    final results = <OfficeExpandedDraft?>[];
    await openExpanded(
      tester,
      ExpandedOffice(),
      mobile: false,
      result: results.add,
    );
    await tester.enterText(key('body'), '取消修改');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    await tester.tap(find.text('打开展开输入框'));
    await tester.pumpAndSettle();
    expect(body(tester).text, '正文');
    await tester.enterText(key('body'), '完成修改');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(results.last!.value.content, '完成修改');
    expect(results.last!.sendRequested, isFalse);
  });

  testWidgets('mobile system back preserves draft', (tester) async {
    OfficeExpandedDraft? result;
    await openExpanded(tester, ExpandedOffice(), result: (v) => result = v);
    await tester.enterText(key('body'), '返回后保留');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(result!.value.content, '返回后保留');
    expect(result!.sendRequested, isFalse);
  });

  testWidgets('send yields an intent without writing a message', (
    tester,
  ) async {
    final state = ExpandedOffice();
    OfficeExpandedDraft? result;
    await openExpanded(
      tester,
      state,
      mentions: ['agent-peer'],
      mentionAll: true,
      result: (v) => result = v,
    );
    await action(tester, 'send');
    expect(result!.sendRequested, isTrue);
    expect(result!.mentions, ['agent-peer']);
    expect(result!.mentionAll, isTrue);
    expect(state.requests, isEmpty);
  });

  testWidgets('empty send is disabled but an attachment permits sending', (
    tester,
  ) async {
    final state = ExpandedOffice();
    final names = <String>[];
    OfficeExpandedDraft? result;
    await openExpanded(
      tester,
      state,
      content: '',
      attachmentNames: () => names,
      onPickAttachments: () async {
        names.add('设计稿.png');
      },
      result: (v) => result = v,
    );
    expect(tester.widget<IconButton>(key('send')).onPressed, isNull);
    await action(tester, 'images');
    expect(find.text('设计稿.png'), findsOneWidget);
    expect(tester.widget<IconButton>(key('send')).onPressed, isNotNull);
    await action(tester, 'send');
    expect(result!.value.content, '');
    expect(result!.sendRequested, isTrue);
  });

  testWidgets(
    'selected text displays real bold italic underline and strike styles',
    (tester) async {
      OfficeExpandedDraft? result;
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: 'hello world',
        result: (v) => result = v,
      );
      body(tester).selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();
      await action(tester, 'format');
      for (final style in ['bold', 'italic', 'underline', 'strikethrough']) {
        await action(tester, 'format-$style');
      }
      final editable = find.descendant(
        of: key('body'),
        matching: find.byType(EditableText),
      );
      final rendered =
          tester.state<EditableTextState>(editable).renderEditable.text!
              as TextSpan;
      final hello = rendered.children!.whereType<TextSpan>().firstWhere(
        (s) => s.text == 'hello',
      );
      expect(hello.style!.fontWeight, FontWeight.w700);
      expect(hello.style!.fontStyle, FontStyle.italic);
      expect(
        hello.style!.decoration!.contains(TextDecoration.underline),
        isTrue,
      );
      expect(
        hello.style!.decoration!.contains(TextDecoration.lineThrough),
        isTrue,
      );
      await action(tester, 'collapse');
      expect(result!.value.content, 'hello world');
      expect(
        result!.value.richText,
        rich([
          span(0, 5, ['bold', 'italic', 'underline', 'strikethrough']),
        ]),
      );
    },
  );

  testWidgets('paragraph list prefixes retain rich text through toggles', (
    tester,
  ) async {
    await openExpanded(
      tester,
      ExpandedOffice(),
      content: 'a\nb',
      richText: rich([
        span(0, 1, ['bold']),
      ]),
      result: (_) {},
    );
    body(tester).selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 3,
    );
    await tester.pump();
    await action(tester, 'format');
    await action(tester, 'number');
    expect(body(tester).text, '1. a\n2. b');
    expect(
      body(tester).richText,
      rich([
        span(3, 4, ['bold']),
      ]),
    );
    await action(tester, 'bullet');
    expect(body(tester).text, '• a\n• b');
    expect(
      body(tester).richText,
      rich([
        span(2, 3, ['bold']),
      ]),
    );
    await action(tester, 'bullet');
    expect(body(tester).text, 'a\nb');
    expect(
      body(tester).richText,
      rich([
        span(0, 1, ['bold']),
      ]),
    );
  });

  testWidgets(
    'native human Agent and all mentions remain separate from content',
    (tester) async {
      OfficeExpandedDraft? result;
      await openExpanded(tester, ExpandedOffice(), result: (v) => result = v);
      await action(tester, 'mention');
      await tester.tap(find.byKey(const ValueKey('mention-person-human-peer')));
      await tester.tap(find.byKey(const ValueKey('mention-person-agent-peer')));
      await tester.tap(find.byKey(const ValueKey('mention-all-choice')));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('@所有人 2 位明确提及'), findsOneWidget);
      await action(tester, 'collapse');
      expect(result!.mentions, unorderedEquals(['human-peer', 'agent-peer']));
      expect(result!.mentionAll, isTrue);
      expect(result!.value.content, '正文');
    },
  );

  testWidgets(
    'Agent entry filters agents and retains existing human mentions',
    (tester) async {
      OfficeExpandedDraft? result;
      await openExpanded(
        tester,
        ExpandedOffice(),
        mentions: ['human-peer'],
        mentionAll: true,
        result: (v) => result = v,
      );
      await action(tester, 'agent');
      expect(
        find.byKey(const ValueKey('mention-person-human-peer')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('mention-all-choice')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mention-person-agent-peer')));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await action(tester, 'collapse');
      expect(result!.mentions, unorderedEquals(['human-peer', 'agent-peer']));
      expect(result!.mentionAll, isTrue);
    },
  );

  testWidgets('direct conversation never returns an all mention', (
    tester,
  ) async {
    final state = ExpandedOffice();
    state.detail!['room']['kind'] = 'direct';
    OfficeExpandedDraft? result;
    await openExpanded(
      tester,
      state,
      mentionAll: true,
      result: (v) => result = v,
    );
    await action(tester, 'mention');
    expect(find.byKey(const ValueKey('mention-all-choice')), findsNothing);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await action(tester, 'collapse');
    expect(result!.mentionAll, isFalse);
  });

  testWidgets(
    'emoji picker inserts canonical content and records only the recent emoji',
    (tester) async {
      final state = ExpandedOffice();
      await openExpanded(tester, state, content: 'A', result: (_) {});
      body(tester).selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      await action(tester, 'emoji');
      final glyph = find.byType(OfficeEmojiGlyph).first;
      final id = tester.widget<OfficeEmojiGlyph>(glyph).id;
      await tester.tap(glyph);
      await tester.pumpAndSettle();
      expect(body(tester).text, 'A${officeEmojiText(id)}');
      expect(
        state.requests
            .where((r) => r['method'] == 'POST')
            .map((r) => r['path']),
        ['/emoji/recents'],
      );
    },
  );

  for (final room in [false, true]) {
    testWidgets(
      '${room ? 'room change' : 'same principal replacement'} clears title body styles and mentions immediately',
      (tester) async {
        final state = ExpandedOffice();
        final results = <OfficeExpandedDraft?>[];
        await openExpanded(
          tester,
          state,
          content: '私密标题\n私密内容',
          title: '私密标题',
          richText: rich([
            span(0, 4, ['bold']),
            span(5, 9, ['italic']),
          ]),
          mentions: ['agent-peer'],
          mentionAll: true,
          result: results.add,
        );
        final oldTitle = titleController(tester), oldBody = body(tester);
        final staleSend = tester.widget<IconButton>(key('send')).onPressed!;
        state.expire(room: room);
        await tester.pumpAndSettle();
        expect(oldTitle.text, '');
        expect(oldBody.text, '');
        expect(oldBody.richText, isNull);
        expect(key('body'), findsNothing);
        expect(key('send'), findsNothing);
        expect(find.textContaining('明确提及'), findsNothing);
        expect(find.text('工作身份或会话已变化，请重新打开编辑器。'), findsOneWidget);
        staleSend();
        await tester.pumpAndSettle();
        expect(results, [null]);
      },
    );
  }

  testWidgets(
    'account change during member fetch cannot reveal the stale picker',
    (tester) async {
      final state = ExpandedOffice()..pendingMembers = Completer<Json>();
      await openExpanded(tester, state, result: (_) {});
      await tester.tap(key('mention'));
      await tester.pump();
      state.expire();
      await tester.pump();
      state.pendingMembers!.complete({
        'room': {'id': 'room-one', 'kind': 'group'},
        'members': [state.me!],
      });
      await tester.pumpAndSettle();
      expect(find.text('选择成员'), findsNothing);
      expect(find.text('工作身份或会话已变化，请重新打开编辑器。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account change while member picker is open removes all old members',
    (tester) async {
      final state = ExpandedOffice();
      await openExpanded(tester, state, result: (_) {});
      await action(tester, 'mention');
      expect(find.text('人类同事'), findsOneWidget);
      state.expire();
      await tester.pumpAndSettle();
      expect(find.text('人类同事'), findsNothing);
      expect(find.text('Agent 同事'), findsNothing);
      expect(find.text('工作身份或会话已变化，请重新打开。'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('工作身份或会话已变化，请重新打开编辑器。'), findsOneWidget);
    },
  );

  testWidgets(
    'wrong room and removed membership cannot open a mention picker',
    (tester) async {
      final state = ExpandedOffice()
        ..memberResult = {
          'room': {'id': 'other', 'kind': 'group'},
          'members': <Json>[],
        };
      await openExpanded(tester, state, result: (_) {});
      await action(tester, 'mention');
      expect(find.text('会话成员信息不完整，请重试。'), findsOneWidget);
      expect(find.text('选择成员'), findsNothing);
      state.memberResult = {
        'room': {'id': 'room-one', 'kind': 'group'},
        'members': <Json>[],
      };
      await action(tester, 'mention');
      expect(find.text('你已不是当前会话成员。'), findsOneWidget);
    },
  );

  testWidgets(
    'attachments run once while busy and late results stay hidden after identity change',
    (tester) async {
      final state = ExpandedOffice();
      final pending = Completer<void>();
      final names = <String>[];
      var calls = 0;
      await openExpanded(
        tester,
        state,
        attachmentNames: () => names,
        onPickAttachments: () async {
          calls++;
          await pending.future;
          names.add('私密附件.png');
        },
        result: (_) {},
      );
      await tester.tap(key('images'));
      await tester.pump();
      expect(tester.widget<IconButton>(key('images')).onPressed, isNull);
      expect(tester.widget<IconButton>(key('send')).onPressed, isNull);
      expect(calls, 1);
      state.expire();
      await tester.pump();
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('私密附件.png'), findsNothing);
      expect(key('send'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Agent callback is invoked and performs no implicit request', (
    tester,
  ) async {
    final state = ExpandedOffice();
    var calls = 0;
    await openExpanded(
      tester,
      state,
      onAgent: (_) async {
        calls++;
        return null;
      },
      result: (_) {},
    );
    await action(tester, 'agent');
    expect(calls, 1);
    expect(state.requests, isEmpty);
    expect(key('body'), findsOneWidget);
  });

  testWidgets(
    'combined title and content length limit keeps the complete draft recoverable',
    (tester) async {
      final results = <OfficeExpandedDraft?>[];
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: 'a' * 12000,
        result: results.add,
      );
      await tester.enterText(key('title'), '题');
      await action(tester, 'collapse');
      expect(results, isEmpty);
      expect(find.text('正文和标题合计最多 12000 个字符。'), findsOneWidget);
      expect(body(tester).text.length, 12000);
      await tester.enterText(key('title'), '');
      await action(tester, 'collapse');
      expect(results.single!.value.content.length, 12000);
    },
  );

  testWidgets('title span cannot silently erase a full 200-span body', (
    tester,
  ) async {
    final spans = List.generate(200, (i) => span(i * 2, i * 2 + 1, ['bold']));
    final results = <OfficeExpandedDraft?>[];
    await openExpanded(
      tester,
      ExpandedOffice(),
      content: 'a ' * 200,
      richText: rich(spans),
      result: results.add,
    );
    await tester.enterText(key('title'), '题');
    await action(tester, 'collapse');
    expect(results, isEmpty);
    expect(find.text('格式片段过多，请减少格式后再保存。'), findsOneWidget);
    expect(body(tester).richText!['spans'], hasLength(200));
    await tester.enterText(key('title'), '');
    await action(tester, 'collapse');
    expect(results.single!.value.richText, rich(spans));
  });

  testWidgets(
    'indent and outdent round trip all selected paragraphs and UTF16 rich spans',
    (tester) async {
      const text = '😀目标\n  • 项目\n\t分组';
      final metadata = rich([
        span(text.indexOf('目标'), text.indexOf('目标') + 2, ['bold']),
        span(text.indexOf('项目'), text.indexOf('项目') + 2, ['italic']),
      ]);
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: text,
        richText: metadata,
        result: (_) {},
      );
      body(tester).selection = TextSelection(
        baseOffset: text.length,
        extentOffset: 0,
      );
      await tester.pump();
      await action(tester, 'indent');
      expect(body(tester).text, '  😀目标\n    • 项目\n  \t分组');
      await action(tester, 'outdent');
      expect(body(tester).text, text);
      expect(body(tester).richText, metadata);
      expect(
        body(tester).selection,
        TextSelection(baseOffset: text.length, extentOffset: 0),
      );
    },
  );

  testWidgets(
    'outdent removes one leading level without deleting list markers or unindented text',
    (tester) async {
      const text = '  😀目标\n • 项目\n\t分组\n无需缩进';
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: text,
        richText: rich([
          span(text.indexOf('项目'), text.indexOf('项目') + 2, ['underline']),
        ]),
        result: (_) {},
      );
      body(tester).selection = TextSelection(
        baseOffset: 0,
        extentOffset: text.length,
      );
      await tester.pump();
      await action(tester, 'outdent');
      const expected = '😀目标\n• 项目\n分组\n无需缩进';
      expect(body(tester).text, expected);
      expect(
        body(tester).richText,
        rich([
          span(expected.indexOf('项目'), expected.indexOf('项目') + 2, [
            'underline',
          ]),
        ]),
      );
      await action(tester, 'outdent');
      expect(body(tester).text, expected);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'outdent selection ending at a newline does not alter the following paragraph',
    (tester) async {
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: '  一\n  二',
        result: (_) {},
      );
      body(tester).selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 4,
      );
      await tester.pump();
      await action(tester, 'outdent');
      expect(body(tester).text, '一\n  二');
    },
  );

  testWidgets(
    'all eight expanded mobile tools fit a narrow keyboard viewport',
    (tester) async {
      await openExpanded(tester, ExpandedOffice(), result: (_) {});
      tester.view.physicalSize = const Size(320, 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      await tester.pumpAndSettle();
      for (final name in [
        'emoji',
        'mention',
        'images',
        'format',
        'indent',
        'outdent',
        'agent',
        'send',
      ]) {
        final rect = tester.getRect(key(name));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
        expect(rect.bottom, lessThanOrEqualTo(390));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real Agent entry returns native mentions into the expanded draft immediately',
    (tester) async {
      OfficeExpandedDraft? result;
      await openExpanded(
        tester,
        ExpandedOffice(),
        mentions: ['human-peer'],
        onAgent: (_) async => ['agent-peer', 'agent-peer', ''],
        result: (value) => result = value,
      );
      await action(tester, 'agent');
      expect(find.text('2 位明确提及'), findsOneWidget);
      await action(tester, 'collapse');
      expect(result!.mentions, unorderedEquals(['human-peer', 'agent-peer']));
    },
  );

  testWidgets(
    'late Agent selection after identity change cannot restore mentions',
    (tester) async {
      final pending = Completer<List<String>?>();
      final state = ExpandedOffice();
      final results = <OfficeExpandedDraft?>[];
      await openExpanded(
        tester,
        state,
        onAgent: (_) => pending.future,
        result: results.add,
      );
      await tester.tap(key('agent'));
      await tester.pump();
      expect(tester.widget<IconButton>(key('agent')).onPressed, isNull);
      state.expire();
      pending.complete(['private-agent']);
      await tester.pumpAndSettle();
      expect(find.textContaining('明确提及'), findsNothing);
      expect(key('body'), findsNothing);
      await action(tester, 'collapse');
      expect(results, [null]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Agent navigation save finishes only after the caller receives its draft',
    (tester) async {
      final results = <OfficeExpandedDraft?>[];
      var navigationAllowed = false;
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: '导航前保留的正文',
        onAgent: (saveAndClose) async {
          final saved = await saveAndClose();
          expect(saved, isTrue);
          expect(results.single!.value.content, '导航前保留的正文');
          navigationAllowed = true;
          return null;
        },
        result: results.add,
      );
      await action(tester, 'agent');
      expect(navigationAllowed, isTrue);
      expect(key('body'), findsNothing);
      expect(results.single!.sendRequested, isFalse);
    },
  );

  testWidgets(
    'Agent navigation is refused while an overlength draft remains editable',
    (tester) async {
      final results = <OfficeExpandedDraft?>[];
      bool? saved;
      await openExpanded(
        tester,
        ExpandedOffice(),
        content: 'a' * 12000,
        onAgent: (saveAndClose) async {
          saved = await saveAndClose();
          return null;
        },
        result: results.add,
      );
      await tester.enterText(key('title'), '额外标题');
      await action(tester, 'agent');
      expect(saved, isFalse);
      expect(results, isEmpty);
      expect(body(tester).text.length, 12000);
      expect(find.text('正文和标题合计最多 12000 个字符。'), findsOneWidget);
    },
  );
}
