import 'package:active_office/ui/office_emoji.dart';
import 'package:active_office/office_state.dart' hide Json;
import 'package:active_office/ui/office_rich_text.dart';
import 'package:active_office/ui/office_theme.dart' show Json, officeTheme;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json span(int start, int end, List<String> styles) => {
  'start': start,
  'end': end,
  'styles': styles,
};
Json rich(List<Json> spans) => {'version': 1, 'spans': spans};

class RichScopeState extends OfficeState {
  RichScopeState() {
    endpoint = 'https://office.example';
    me = {'id': 'same-principal', 'kind': 'human'};
    selectedRoomId = 'room-one';
  }
  int generation = 1;
  @override
  int get identityGeneration => generation;
}

Future<void> mountRich(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(20), child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openEditor(
  WidgetTester tester,
  String content, {
  Json? richText,
  OfficeState? state,
  bool Function()? sourceIsCurrent,
  Size size = const Size(1100, 860),
  required ValueChanged<OfficeRichTextValue?> result,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result(
              await showOfficeRichTextEditor(
                context,
                content: content,
                richText: richText,
                state: state,
                sourceIsCurrent: sourceIsCurrent,
              ),
            ),
            child: const Text('打开文字排版'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开文字排版'));
  await tester.pumpAndSettle();
}

TextEditingController editor(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('rich-editor-content')))
    .controller!;
Future<void> select(WidgetTester tester, int start, int end) async {
  editor(tester).selection = TextSelection(
    baseOffset: start,
    extentOffset: end,
  );
  await tester.pump();
}

Future<void> format(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('rich-format-$name')));
  await tester.pump();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('rich-editor-save')));
  await tester.pumpAndSettle();
}

void main() {
  test('native normalization sorts and deduplicates styles and spans; empty is absent', () {
    expect(officeNormalizeRichText('abc', null), isNull);
    expect(officeNormalizeRichText('abc', rich([])), isNull);
    expect(
      officeNormalizeRichText(
        'abc',
        rich([
          span(1, 3, ['underline', 'bold', 'bold']),
          span(0, 1, ['italic']),
          span(1, 3, ['bold', 'underline']),
        ]),
      ),
      rich([
        span(0, 1, ['italic']),
        span(1, 3, ['bold', 'underline']),
      ]),
    );
  });

  final invalid = <String, Json>{
    'unknown version': {
      'version': 2,
      'spans': [
        span(0, 1, ['bold']),
      ],
    },
    'extra root key': {
      ...rich([
        span(0, 1, ['bold']),
      ]),
      'html': '<b>x</b>',
    },
    'extra span key': rich([
      {
        ...span(0, 1, ['bold']),
        'url': 'javascript:bad',
      },
    ]),
    'surrogate start': rich([
      span(1, 2, ['bold']),
    ]),
    'surrogate end': rich([
      span(0, 1, ['bold']),
    ]),
    'outside content': rich([
      span(0, 99, ['bold']),
    ]),
    'reversed range': rich([
      span(3, 2, ['bold']),
    ]),
    'empty styles': rich([span(2, 3, [])]),
    'unknown style': rich([
      span(2, 3, ['link']),
    ]),
    'noninteger position': rich([
      {
        'start': 2.5,
        'end': 3,
        'styles': ['bold'],
      },
    ]),
  };
  for (final entry in invalid.entries) {
    test('invalid ${entry.key} degrades the entire document', () {
      expect(officeNormalizeRichText('😀ab', entry.value), isNull);
    });
  }
  test('200-span contract rejects oversized input before deduplication', () {
    expect(
      officeNormalizeRichText(
        'abc',
        rich(List.generate(201, (_) => span(0, 1, ['bold']))),
      ),
      isNull,
    );
    expect(
      officeNormalizeRichText(
        'abc',
        rich(List.generate(200, (_) => span(0, 1, ['bold']))),
      ),
      rich([
        span(0, 1, ['bold']),
      ]),
    );
  });

  test('typing before, inside and after styled UTF-16 text preserves the intended range', () {
    final value = rich([
      span(2, 5, ['bold']),
    ]);
    expect(
      officeRebaseRichText('😀abc', 'Z😀abc', value),
      rich([
        span(3, 6, ['bold']),
      ]),
    );
    expect(
      officeRebaseRichText('😀abc', '😀aXbc', value),
      rich([
        span(2, 6, ['bold']),
      ]),
    );
    expect(officeRebaseRichText('😀abc', '😀abcX', value), value);
    expect(
      officeRebaseRichText('😀abc', '😀Xabc', value),
      rich([
        span(3, 6, ['bold']),
      ]),
    );
  });
  test('replacing same-surrogate-prefix emoji cannot split the remaining formatting', () {
    final value = rich([
      span(2, 3, ['underline']),
    ]);
    expect(officeRebaseRichText('😀a', '😁a', value), value);
    expect(
      officeRebaseRichText('😀a', 'a', value),
      rich([
        span(0, 1, ['underline']),
      ]),
    );
    expect(officeRebaseRichText('😀a', '', value), isNull);
  });
  test('partial replacements do not extend an old style onto unrelated inserted text', () {
    final value = rich([
      span(0, 3, ['bold']),
      span(3, 6, ['italic']),
    ]);
    expect(
      officeRebaseRichText('abcdef', 'abXYef', value),
      rich([
        span(0, 2, ['bold']),
        span(4, 6, ['italic']),
      ]),
    );
    expect(
      officeRebaseRichText('abcdef', 'abef', value),
      rich([
        span(0, 2, ['bold']),
        span(2, 4, ['italic']),
      ]),
    );
  });
  test('trim returns matching content and UTF-16 coordinates, dropping whitespace-only formats', () {
    final value = officeTrimRichText(
      ' \n😀好  ',
      rich([
        span(0, 7, ['bold']),
        span(2, 4, ['italic']),
        span(5, 7, ['underline']),
      ]),
    );
    expect(value.content, '😀好');
    expect(
      value.richText,
      rich([
        span(0, 2, ['italic']),
        span(0, 3, ['bold']),
      ]),
    );
    expect(
      officeTrimRichText(
        '  ',
        rich([
          span(0, 2, ['bold']),
        ]),
      ).richText,
      isNull,
    );
  });

  testWidgets(
    'overlapping formats produce actual font and decoration styles without markup',
    (tester) async {
      await mountRich(
        tester,
        OfficeRichText(
          content: 'abcdef',
          selectable: false,
          richText: rich([
            span(0, 4, ['bold']),
            span(2, 6, ['italic']),
            span(1, 5, ['underline']),
            span(3, 4, ['strikethrough']),
          ]),
        ),
      );
      final rendered = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.textSpan?.toPlainText() == 'abcdef',
        ),
      );
      final children = (rendered.textSpan as TextSpan).children!
          .whereType<TextSpan>();
      final d = children.firstWhere((s) => s.text == 'd');
      expect(d.style!.fontWeight, FontWeight.w700);
      expect(d.style!.fontStyle, FontStyle.italic);
      expect(d.style!.decoration!.contains(TextDecoration.underline), isTrue);
      expect(d.style!.decoration!.contains(TextDecoration.lineThrough), isTrue);
      expect(rendered.textSpan!.toPlainText(), 'abcdef');
    },
  );
  testWidgets(
    'styled classic emoji stays a glyph while unknown tokens and HTML stay literal',
    (tester) async {
      const content = '粗体 :feishu:SMILE: 😀 :feishu:Future: <b>文字</b>';
      await mountRich(
        tester,
        OfficeRichText(
          content: content,
          richText: rich([
            span(0, content.length, ['bold']),
          ]),
          selectable: false,
        ),
      );
      expect(find.byType(OfficeEmojiGlyph), findsOneWidget);
      expect(
        tester.widget<OfficeEmojiGlyph>(find.byType(OfficeEmojiGlyph)).id,
        'feishu:SMILE',
      );
      final rendered = tester.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
      );
      expect(
        rendered.textSpan!.toPlainText(),
        contains(':feishu:Future: <b>文字</b>'),
      );
      expect(rendered.textSpan!.toPlainText(), contains('😀'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'malformed rich text renders the full plain content rather than crashing',
    (tester) async {
      await mountRich(
        tester,
        OfficeRichText(
          content: '😀文本',
          richText: rich([
            span(1, 3, ['bold']),
          ]),
        ),
      );
      expect(find.byType(OfficeEmojiText), findsOneWidget);
      expect(find.text('😀文本'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'styled text right-click redirects once to the complete message menu callback',
    (tester) async {
      final positions = <Offset>[];
      await mountRich(
        tester,
        OfficeRichText(
          content: '可操作的格式消息',
          richText: rich([
            span(0, 4, ['bold']),
          ]),
          onOpenMessageMenu: positions.add,
        ),
      );
      final target = find.byType(OfficeRichText);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.down(tester.getTopLeft(target) + const Offset(15, 10));
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(positions, hasLength(1));
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editor selection uses real bold and italic, toggles only selected ranges, saves no marker syntax',
    (tester) async {
      OfficeRichTextValue? result;
      await openEditor(
        tester,
        'hello world',
        result: (value) => result = value,
      );
      await select(tester, 0, 5);
      await format(tester, 'bold');
      await format(tester, 'italic');
      final actualEditingText =
          tester
                  .state<EditableTextState>(find.byType(EditableText))
                  .renderEditable
                  .text!
              as TextSpan;
      final actualHello = actualEditingText.children!
          .whereType<TextSpan>()
          .firstWhere((s) => s.text == 'hello');
      expect(actualHello.style!.fontWeight, FontWeight.w700);
      expect(actualHello.style!.fontStyle, FontStyle.italic);
      final control = editor(tester);
      final rendered = control.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        withComposing: false,
      );
      final hello = rendered.children!.whereType<TextSpan>().firstWhere(
        (s) => s.text == 'hello',
      );
      expect(hello.style!.fontWeight, FontWeight.w700);
      expect(hello.style!.fontStyle, FontStyle.italic);
      await select(tester, 1, 4);
      await format(tester, 'bold');
      await save(tester);
      expect(result!.content, 'hello world');
      expect(
        result!.richText,
        rich([
          span(0, 1, ['bold', 'italic']),
          span(1, 4, ['italic']),
          span(4, 5, ['bold', 'italic']),
        ]),
      );
    },
  );
  testWidgets(
    'editing formatted text rebases through keyboard input and preserves composing behavior',
    (tester) async {
      OfficeRichTextValue? result;
      await openEditor(
        tester,
        '😀abc',
        richText: rich([
          span(2, 5, ['underline']),
        ]),
        result: (value) => result = value,
      );
      await tester.enterText(
        find.byKey(const ValueKey('rich-editor-content')),
        '😀aXbc',
      );
      await tester.pump();
      final c = editor(tester);
      c.value = c.value.copyWith(composing: const TextRange(start: 2, end: 4));
      final rendered = c.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        withComposing: true,
      );
      expect(rendered.toPlainText(), '😀aXbc');
      await save(tester);
      expect(
        result!.richText,
        rich([
          span(2, 6, ['underline']),
        ]),
      );
    },
  );
  testWidgets(
    'real bullet and numbered paragraphs retain their content styles across prefix changes',
    (tester) async {
      OfficeRichTextValue? result;
      await openEditor(
        tester,
        '甲\n😀乙',
        richText: rich([
          span(2, 5, ['bold']),
        ]),
        result: (value) => result = value,
      );
      await select(tester, 0, 5);
      await tester.tap(find.byKey(const ValueKey('rich-list-bullet')));
      await tester.pump();
      expect(editor(tester).text, '• 甲\n• 😀乙');
      await tester.tap(find.byKey(const ValueKey('rich-list-numbered')));
      await tester.pump();
      expect(editor(tester).text, '1. 甲\n2. 😀乙');
      await save(tester);
      expect(result!.content, '1. 甲\n2. 😀乙');
      expect(
        result!.richText,
        rich([
          span(8, 11, ['bold']),
        ]),
      );
    },
  );
  testWidgets(
    'list on a collapsed first-line cursor does not throw and toggles off',
    (tester) async {
      OfficeRichTextValue? result;
      await openEditor(tester, '首行', result: (value) => result = value);
      await select(tester, 0, 0);
      await tester.tap(find.byKey(const ValueKey('rich-list-bullet')));
      await tester.pump();
      expect(editor(tester).text, '• 首行');
      await tester.tap(find.byKey(const ValueKey('rich-list-bullet')));
      await tester.pump();
      expect(editor(tester).text, '首行');
      await save(tester);
      expect(result!.richText, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cancel discards formatting and does not mutate the caller document',
    (tester) async {
      final original = rich([
        span(0, 2, ['bold']),
      ]);
      final originalCopy = rich([
        span(0, 2, ['bold']),
      ]);
      OfficeRichTextValue? result;
      var returned = false;
      await openEditor(
        tester,
        '资料',
        richText: original,
        result: (value) {
          result = value;
          returned = true;
        },
      );
      await select(tester, 0, 2);
      await format(tester, 'italic');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(result, isNull);
      expect(original, originalCopy);
    },
  );
  testWidgets(
    'phone keyboard retains reachable completion and preview uses real emoji',
    (tester) async {
      OfficeRichTextValue? result;
      await openEditor(
        tester,
        '预览 :feishu:SMILE:',
        size: const Size(390, 700),
        result: (value) => result = value,
      );
      await select(tester, 0, 2);
      await format(tester, 'strikethrough');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final saveButton = find.byKey(const ValueKey('rich-editor-save'));
      expect(tester.getRect(saveButton).bottom, lessThanOrEqualTo(400));
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeEmojiGlyph), findsOneWidget);
      await save(tester);
      expect(result!.content, '预览 :feishu:SMILE:');
      expect(
        result!.richText,
        rich([
          span(0, 2, ['strikethrough']),
        ]),
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('shared style toggle retains safe selections and rejects fragmentation without mutating input', () {
    final value = rich([
      span(0, 2, ['bold']),
    ]);
    expect(
      officeToggleRichTextStyle(
        '😀x',
        value,
        const TextSelection(baseOffset: 1, extentOffset: 2),
        'italic',
      ),
      value,
    );
    expect(
      officeToggleRichTextStyle(
        '😀x',
        value,
        const TextSelection(baseOffset: 0, extentOffset: 2),
        'bold',
      ),
      isNull,
    );
    final many = rich(
      List.generate(200, (i) => span(i * 2, i * 2 + 1, ['bold'])),
    );
    expect(
      () => officeToggleRichTextStyle(
        'a' * 400,
        many,
        const TextSelection(baseOffset: 0, extentOffset: 400),
        'italic',
      ),
      throwsFormatException,
    );
    expect((many['spans'] as List).length, 200);
    expect((many['spans'] as List).first, span(0, 1, ['bold']));
  });

  for (final changeRoom in [false, true]) {
    testWidgets(
      '${changeRoom ? 'room change' : 'same principal new login'} clears an open rich editor and blocks retained save',
      (tester) async {
        final state = RichScopeState();
        addTearDown(state.dispose);
        OfficeRichTextValue? result;
        var returned = false;
        await openEditor(
          tester,
          '当前身份私有草稿',
          richText: rich([
            span(0, 4, ['bold']),
          ]),
          state: state,
          result: (value) {
            result = value;
            returned = true;
          },
        );
        final controller = editor(tester);
        final staleSave = tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('rich-editor-save')),
            )
            .onPressed!;
        if (changeRoom) {
          state.selectedRoomId = 'room-two';
        } else {
          state.generation++;
        }
        state.notifyListeners();
        await tester.pumpAndSettle();
        expect(controller.text, isEmpty);
        expect(find.byKey(const ValueKey('rich-editor-content')), findsNothing);
        expect(find.text('工作身份或会话已变化，请重新打开文字排版'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('rich-editor-save')),
              )
              .onPressed,
          isNull,
        );
        staleSave();
        await tester.pumpAndSettle();
        expect(returned, isFalse);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(returned, isTrue);
        expect(result, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'source invalidation before a notification clears and permanently locks the old format route',
    (tester) async {
      final state = RichScopeState();
      addTearDown(state.dispose);
      var sourceCurrent = true, returned = false;
      OfficeRichTextValue? result;
      await openEditor(
        tester,
        '来源消息正文',
        richText: rich([
          span(0, 4, ['bold']),
        ]),
        state: state,
        sourceIsCurrent: () => sourceCurrent,
        result: (value) {
          result = value;
          returned = true;
        },
      );
      final controller = editor(tester) as OfficeRichTextEditingController;
      final staleSave = tester
          .widget<FilledButton>(find.byKey(const ValueKey('rich-editor-save')))
          .onPressed!;
      sourceCurrent = false;
      // Saving rechecks current source state even before the next state event.
      staleSave();
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(controller.richText, isNull);
      expect(returned, isFalse);
      expect(find.text('来源消息已变化，请关闭文字排版'), findsOneWidget);
      sourceCurrent = true;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('rich-editor-save')),
            )
            .onPressed,
        isNull,
      );
      expect(controller.text, isEmpty);
      staleSave();
      await tester.pumpAndSettle();
      expect(returned, isFalse);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(result, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  test('public controller atomically restores text and formatting and notifies for style-only edits', () {
    final controller = OfficeRichTextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    var changes = 0;
    controller.addListener(() => changes++);
    controller.setRichValue(
      OfficeRichTextValue(
        content: 'abc',
        richText: rich([
          span(0, 3, ['bold']),
        ]),
      ),
      selection: controller.selection,
    );
    expect(changes, 1);
    expect(
      controller.richText,
      rich([
        span(0, 3, ['bold']),
      ]),
    );
    controller.setRichValue(
      OfficeRichTextValue(
        content: '😀字',
        richText: rich([
          span(2, 3, ['italic']),
        ]),
      ),
      selection: const TextSelection(baseOffset: 1, extentOffset: 3),
    );
    expect(changes, 2);
    expect(controller.selection.baseOffset, 0);
    expect(
      controller.richText,
      rich([
        span(2, 3, ['italic']),
      ]),
    );
    controller.value = const TextEditingValue(
      text: 'X😀字',
      selection: TextSelection.collapsed(offset: 4),
    );
    expect(changes, 3);
    expect(
      controller.richText,
      rich([
        span(3, 4, ['italic']),
      ]),
    );
    controller.richText = rich([
      span(0, 1, ['underline']),
    ]);
    expect(changes, 4);
    expect(controller.text, 'X😀字');
  });
}
