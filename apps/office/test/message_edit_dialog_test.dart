import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_edit_dialog.dart';
import 'package:active_office/ui/office_rich_text.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class MessageEditFixture extends OfficeState {
  MessageEditFixture({bool attachments = false, bool agent = false}) {
    endpoint = 'https://message-edit-fixture.example';
    connected = true;
    me = {'id': 'self', 'kind': agent ? 'agent' : 'human'};
    selectedRoomId = 'source-room';
    message = {
      'id': 'message-1',
      'room_id': 'source-room',
      'author_id': 'self',
      'content': '旧身份私有正文',
      'revision': 4,
      'attachment_ids': attachments ? ['attachment-1'] : [],
    };
    detail = {
      'room': {'id': 'source-room'},
      'messages': [message],
    };
  }
  int generation = 0;
  @override
  int get identityGeneration => generation;
  late Json message;
  void changed() => notifyListeners();
}

Future<void> launch(
  WidgetTester tester,
  MessageEditFixture state, {
  bool retract = false,
  required ValueChanged<dynamic> result,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result(
              retract
                  ? await confirmOfficeMessageRetraction(
                      context,
                      state,
                      state.message,
                    )
                  : await showOfficeMessageEdit(context, state, state.message),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  for (final preview in [false, true]) {
    testWidgets(
      'withdrawn source clears the nested format ${preview ? 'preview' : 'editor'} and rejects stale completion',
      (tester) async {
        final state = MessageEditFixture();
        state.message['rich_text'] = {
          'version': 1,
          'spans': [
            {
              'start': 0,
              'end': 4,
              'styles': ['bold'],
            },
          ],
        };
        dynamic result;
        await launch(tester, state, result: (value) => result = value);
        await tester.tap(find.text('文字格式'));
        await tester.pumpAndSettle();
        final controller =
            tester
                    .widget<TextField>(
                      find.byKey(const ValueKey('rich-editor-content')),
                    )
                    .controller!
                as OfficeRichTextEditingController;
        final staleSave = tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('rich-editor-save')),
            )
            .onPressed!;
        if (preview) {
          await tester.tap(find.text('预览'));
          await tester.pumpAndSettle();
        }
        state.detail = {
          'room': {'id': 'source-room'},
          'messages': [
            {
              ...state.message,
              'retracted_at': '2026-09-07T02:00:00Z',
              'content': '',
            },
          ],
        };
        state.changed();
        await tester.pumpAndSettle();
        expect(controller.text, isEmpty);
        expect(controller.richText, isNull);
        expect(find.text('旧身份私有正文'), findsNothing);
        expect(find.text('来源消息已变化，请关闭文字排版'), findsOneWidget);
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
        expect(find.byType(OfficeRichTextEditor), findsOneWidget);
        expect(result, isNull);
        await tester.tap(find.byTooltip('取消排版'));
        await tester.pumpAndSettle();
        expect(find.text('这条消息已撤回'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a real merged card can clear its optional styled comment', (
    tester,
  ) async {
    final state = MessageEditFixture();
    state.message.addAll({
      'kind': 'forward_bundle',
      'forward_bundle': {'id': 'bundle-test', 'message_count': 2},
      'rich_text': {
        'version': 1,
        'spans': [
          {
            'start': 0,
            'end': 4,
            'styles': ['bold'],
          },
        ],
      },
    });
    dynamic result;
    await launch(tester, state, result: (value) => result = value);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, isA<OfficeRichTextValue>());
    expect(result.content, isEmpty);
    expect(result.richText, isNull);
    expect(state.message['revision'], 4);
    expect(state.message['forward_bundle']['id'], 'bundle-test');
    expect(tester.takeException(), isNull);
  });

  testWidgets('styled message editing keeps ranges and rebases inserted text', (
    tester,
  ) async {
    final state = MessageEditFixture();
    state.message['rich_text'] = {
      'version': 1,
      'spans': [
        {
          'start': 0,
          'end': 4,
          'styles': ['bold', 'underline'],
        },
      ],
    };
    dynamic result;
    await launch(tester, state, result: (value) => result = value);
    await tester.enterText(
      find.byType(TextField),
      "新增 ${state.message['content']}",
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(result.content, "新增 ${state.message['content']}");
    expect(result.richText, {
      'version': 1,
      'spans': [
        {
          'start': 3,
          'end': 7,
          'styles': ['bold', 'underline'],
        },
      ],
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'same principal relogin clears styled editor without submitting',
    (tester) async {
      final state = MessageEditFixture();
      state.message['rich_text'] = {
        'version': 1,
        'spans': [
          {
            'start': 0,
            'end': 4,
            'styles': ['bold'],
          },
        ],
      };
      dynamic result;
      await launch(tester, state, result: (value) => result = value);
      state.generation++;
      state.changed();
      await tester.pumpAndSettle();
      expect(find.text('旧身份私有正文'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final retract in [false, true]) {
    for (final change in ['principal', 'endpoint', 'connection']) {
      testWidgets(
        '${retract ? 'retraction' : 'edit'} clears and locks content on $change change',
        (tester) async {
          final state = MessageEditFixture();
          dynamic result;
          await launch(
            tester,
            state,
            retract: retract,
            result: (value) => result = value,
          );
          TextEditingController? editor;
          if (!retract) {
            editor = tester
                .widget<TextField>(find.byType(TextField))
                .controller!;
            await tester.enterText(find.byType(TextField), '尚未提交的私有草稿');
          }
          if (change == 'principal') state.me = {'id': 'another'};
          if (change == 'endpoint') {
            state.endpoint = 'https://another-fixture.example';
          }
          if (change == 'connection') state.connected = false;
          state.changed();
          await tester.pumpAndSettle();
          expect(find.text('旧身份私有正文'), findsNothing);
          expect(find.text('尚未提交的私有草稿'), findsNothing);
          if (editor != null) expect(editor.text, isEmpty);
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
          // Returning to the original identity cannot resurrect the old route.
          state.me = {'id': 'self'};
          state.endpoint = 'https://message-edit-fixture.example';
          state.connected = true;
          state.changed();
          await tester.pumpAndSettle();
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(result, retract ? false : null);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '${retract ? 'retraction' : 'edit'} observes withdrawal tombstone in captured room',
      (tester) async {
        final state = MessageEditFixture();
        await launch(tester, state, retract: retract, result: (_) {});
        state.detail = {
          'room': {'id': 'source-room'},
          'messages': [
            {
              ...state.message,
              'retracted_at': '2026-09-06T11:20:00Z',
              'content': '',
            },
          ],
        };
        state.changed();
        await tester.pumpAndSettle();
        expect(find.text('这条消息已撤回'), findsOneWidget);
        expect(find.text('旧身份私有正文'), findsNothing);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
      },
    );
  }

  testWidgets(
    'edit preserves raw text and keeps source revision when another room is selected',
    (tester) async {
      final state = MessageEditFixture(agent: true);
      dynamic result;
      await launch(tester, state, result: (value) => result = value);
      await tester.enterText(find.byType(TextField), '  Agent 的编辑正文  ');
      state.selectedRoomId = 'another-room';
      state.detail = {
        'room': {'id': 'another-room'},
        'messages': [
          {'id': 'message-1', 'retracted_at': 'irrelevant'},
        ],
      };
      state.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result.content, '  Agent 的编辑正文  ');
      expect(state.message['revision'], 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty text is rejected while attachment-only edit can save empty content',
    (tester) async {
      final state = MessageEditFixture();
      dynamic result;
      await launch(tester, state, result: (value) => result = value);
      await tester.enterText(find.byType(TextField), '  ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('消息内容不能为空'), findsOneWidget);
      expect(result, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      state.message['attachment_ids'] = ['attachment-1'];
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result.content, '');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retraction confirms explicitly and denies a different author', (
    tester,
  ) async {
    final state = MessageEditFixture(agent: true);
    dynamic result;
    await launch(
      tester,
      state,
      retract: true,
      result: (value) => result = value,
    );
    await tester.tap(find.text('确认撤回'));
    await tester.pumpAndSettle();
    expect(result, true);
    state.message['author_id'] = 'different-author';
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('只能编辑或撤回自己发送的消息。'), findsOneWidget);
    expect(find.text('旧身份私有正文'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
