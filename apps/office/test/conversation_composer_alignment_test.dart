import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/conversation.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class ComposerOffice extends LayoutOfficeState {
  ComposerOffice() {
    endpoint = 'https://composer-${_serial++}.invalid';
    settings = {'revision': 4, 'send_shortcut': 'enter'};
  }
  static int _serial = 0;
  int generation = 0;
  @override
  int get identityGeneration => generation;
  final sent = <Json>[];
  final uploaded = <String>[];
  final settingsWrites = <Json>[];
  Completer<Json>? pendingSend;
  Object? settingsFailure;
  void changeIdentity() {
    generation++;
    me = {'id': 'other', 'name': '新身份'};
    notifyListeners();
  }

  @override
  Future<void> setConversationVisible(String roomId, bool visible) async {}
  @override
  Future<void> reportVisibleMessageSequences(
    String roomId,
    Iterable<int> sequences, {
    required int selection,
    required int identityGeneration,
  }) async {}
  @override
  Future<void> jumpToLatestMessages() async {}
  @override
  Future<Json> send(
    String content, {
    List<String> mentions = const [],
    bool mentionAll = false,
    String? sourceRoomId,
    String? replyTo,
    String? clientId,
    List<String> attachmentIds = const [],
    Json? richText,
  }) async {
    sent.add({
      'content': content,
      'mentions': mentions,
      'mention_all': mentionAll,
      'rich_text': richText,
      'source_room_id': sourceRoomId,
      'reply_to': replyTo,
      'client_id': clientId,
      'attachment_ids': attachmentIds,
    });
    return pendingSend?.future ?? {'id': 'sent-${sent.length}'};
  }

  @override
  Future<Json> uploadAttachment(
    String filename,
    Uint8List bytes, {
    String mimeType = 'application/octet-stream',
  }) async {
    uploaded.add(filename);
    return {
      'id': 'attachment-${uploaded.length}',
      'filename': filename,
      'room_id': selectedRoomId,
      'mime_type': mimeType,
      'size': bytes.length,
    };
  }

  @override
  Future<void> saveSettings(Json changes, {int? baseRevision}) async {
    settingsWrites.add({...changes, 'base_revision': baseRevision});
    if (settingsFailure != null) throw settingsFailure!;
    settings.addAll(changes);
    settings['revision'] = (settings['revision'] as int) + 1;
    notifyListeners();
  }
}

Future<void> mountComposer(
  WidgetTester tester,
  ComposerOffice state, {
  double width = 514,
  bool mobile = false,
  VoidCallback? onAgentStore,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: OfficeConversation(
          state: state,
          mobile: mobile,
          onAgentStore: onAgentStore,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get input => find.byKey(const ValueKey('composer-input'));
Finder get sendButton => find.byKey(const ValueKey('composer-send'));
Future<void> click(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void mockScreenshot(
  WidgetTester tester,
  Future<Object?> Function(MethodCall) handler,
) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('renji/native_screenshot'),
    handler,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('renji/native_screenshot'),
      null,
    ),
  );
}

Json get capability => {
  'protocol': 'native-screenshot/v1',
  'available': true,
  'requires_permission': false,
  'reason': '',
};
Json get screenshot => {
  'filename': '截图.png',
  'mime_type': 'image/png',
  'bytes': Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1]),
};

void main() {
  testWidgets(
    'desktop empty frame matches 470 by 82 logical reference region',
    (tester) async {
      await mountComposer(tester, ComposerOffice());
      final frame = tester.getRect(
        find.byKey(const ValueKey('conversation-composer-frame')),
      );
      expect(frame.width, 470);
      expect(frame.height, 82);
      expect(
        tester.widget<TextField>(input).decoration!.hintText,
        '发送给 协作测试项目',
      );
      expect(tester.widget<IconButton>(sendButton).onPressed, isNull);
      expect(find.text('发送'), findsNothing);
      expect(find.text('Enter 发送 · Shift + Enter 换行'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'desktop tools align to the right and retain an Agent peer entry',
    (tester) async {
      await mountComposer(tester, ComposerOffice(), width: 900);
      final frame = tester.getRect(
        find.byKey(const ValueKey('conversation-composer-frame')),
      );
      final format = tester.getRect(
        find.byKey(const ValueKey('composer-format')),
      );
      expect(format.left, greaterThan(frame.center.dx));
      final keys = [
        'composer-format',
        'composer-emoji',
        'composer-mention',
        'composer-screenshot',
        'composer-agent',
        'composer-more',
        'composer-expand',
        'composer-send',
        'composer-send-options',
      ];
      final centers = keys
          .map((key) => tester.getCenter(find.byKey(ValueKey(key))))
          .toList();
      for (var i = 1; i < centers.length; i++) {
        expect(centers[i].dx, greaterThan(centers[i - 1].dx));
        expect(centers[i].dy, centers.first.dy);
      }
      expect(centers.last.dx, lessThan(frame.right));
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets('typing enables icon send and successful delivery clears it', (
    tester,
  ) async {
    final state = ComposerOffice();
    await mountComposer(tester, state);
    await tester.enterText(input, '  当前消息  ');
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(sendButton).onPressed, isNotNull);
    await click(tester, sendButton);
    expect(state.sent.single['content'], '当前消息');
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(tester.widget<IconButton>(sendButton).onPressed, isNull);
  });
  testWidgets('whitespace and disconnected drafts keep send disabled', (
    tester,
  ) async {
    final state = ComposerOffice();
    await mountComposer(tester, state);
    await tester.enterText(input, '   ');
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(sendButton).onPressed, isNull);
    state.connected = false;
    await tester.enterText(input, '离线草稿');
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(sendButton).onPressed, isNull);
    expect(state.sent, isEmpty);
  });
  testWidgets(
    'plus exposes preserved work actions and opens the actual task dialog',
    (tester) async {
      await mountComposer(tester, ComposerOffice());
      expect(find.byTooltip('新建共同文档'), findsNothing);
      await click(tester, find.byKey(const ValueKey('composer-more')));
      for (final text in ['文件与图片', '新建共同文档', '创建任务', '工作记录']) {
        expect(find.text(text), findsWidgets);
      }
      await click(tester, find.text('创建任务'));
      expect(find.byType(TextField), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == '写下一个具体、可完成的行动',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'send mode dropdown saves CAS personal settings and preserves draft',
    (tester) async {
      final state = ComposerOffice();
      await mountComposer(tester, state);
      await tester.enterText(input, '不丢草稿');
      await click(tester, find.byKey(const ValueKey('composer-send-options')));
      await click(tester, find.text('Ctrl / ⌘ + Enter 发送'));
      expect(state.settingsWrites.single, {
        'send_shortcut': 'mod_enter',
        'base_revision': 4,
      });
      expect(tester.widget<TextField>(input).controller!.text, '不丢草稿');
      expect(state.sent, isEmpty);
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'failed send-mode update leaves current shortcut and visible error',
    (tester) async {
      final state = ComposerOffice()
        ..settingsFailure = OfficeException(409, '设置版本变化');
      await mountComposer(tester, state);
      await click(tester, find.byKey(const ValueKey('composer-send-options')));
      await click(tester, find.text('Ctrl / ⌘ + Enter 发送'));
      expect(state.settings['send_shortcut'], 'enter');
      expect(find.textContaining('设置版本变化'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'expanded editor cancellation returns to unchanged inline draft',
    (tester) async {
      await mountComposer(tester, ComposerOffice());
      await tester.enterText(input, '原有草稿');
      await click(tester, find.byKey(const ValueKey('composer-expand')));
      final expanded = find.byKey(const ValueKey('expanded-body'));
      await tester.enterText(expanded, '尚未确认的编辑');
      await click(tester, find.text('取消'));
      expect(tester.widget<TextField>(input).controller!.text, '原有草稿');
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'multiline text grows beyond the empty frame without hiding the tools',
    (tester) async {
      await mountComposer(tester, ComposerOffice());
      await tester.enterText(input, '第一行\n第二行\n第三行\n第四行');
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('conversation-composer-frame')))
            .height,
        greaterThan(82),
      );
      expect(tester.getRect(sendButton).bottom, lessThan(844));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'Aa edits real spans and trimmed send retains styles without Markdown markers',
    (tester) async {
      final state = ComposerOffice();
      await mountComposer(tester, state);
      await tester.enterText(input, '  共同目标  ');
      await click(tester, find.byKey(const ValueKey('composer-format')));
      final editor = find.byKey(const ValueKey('rich-editor-content'));
      final controller = tester.widget<TextField>(editor).controller!;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 6,
      );
      await tester.pumpAndSettle();
      await click(tester, find.byKey(const ValueKey('rich-format-bold')));
      await click(tester, find.byKey(const ValueKey('rich-editor-save')));
      expect(tester.widget<TextField>(input).controller!.text, '  共同目标  ');
      await click(tester, sendButton);
      expect(state.sent.single['content'], '共同目标');
      expect(state.sent.single['rich_text'], {
        'version': 1,
        'spans': [
          {
            'start': 0,
            'end': 4,
            'styles': ['bold'],
          },
        ],
      });
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'inline changes rebase existing formatted draft spans before sending',
    (tester) async {
      final state = ComposerOffice();
      await mountComposer(tester, state);
      await tester.enterText(input, '共同目标');
      await click(tester, find.byKey(const ValueKey('composer-format')));
      final editor = tester.widget<TextField>(
        find.byKey(const ValueKey('rich-editor-content')),
      );
      editor.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 2,
      );
      await tester.pumpAndSettle();
      await click(tester, find.byKey(const ValueKey('rich-format-italic')));
      await click(tester, find.byKey(const ValueKey('rich-editor-save')));
      await tester.enterText(input, '新的共同目标');
      await tester.pumpAndSettle();
      await click(tester, sendButton);
      expect(state.sent.single['rich_text'], {
        'version': 1,
        'spans': [
          {
            'start': 2,
            'end': 4,
            'styles': ['italic'],
          },
        ],
      });
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'mobile empty composer has a compact white editor and independent common tools',
    (tester) async {
      await mountComposer(tester, ComposerOffice(), width: 390, mobile: true);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('composer-input-surface')))
            .height,
        lessThanOrEqualTo(42),
      );
      expect(
        find.byKey(const ValueKey('mobile-composer-tools')),
        findsOneWidget,
      );
      expect(sendButton, findsNothing);
      expect(
        tester.widget<TextField>(input).decoration!.hintText,
        '发送给 协作测试项目',
      );
      final keys = [
        'composer-emoji',
        'composer-mention',
        'composer-voice',
        'composer-images',
        'composer-format',
        'composer-agent',
        'composer-more',
      ];
      final positions = keys
          .map((key) => tester.getCenter(find.byKey(ValueKey(key))))
          .toList();
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i].dx, greaterThan(positions[i - 1].dx));
      }
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('composer-voice')))
            .onPressed,
        isNull,
      );
      expect(find.byTooltip('语音消息（尚未接入）'), findsOneWidget);
      for (final key in [
        'composer-emoji',
        'composer-mention',
        'composer-images',
        'composer-agent',
        'composer-more',
      ]) {
        final button = find.byKey(ValueKey(key));
        final bounds = tester.getRect(button);
        final icon = tester.getRect(
          find.descendant(of: button, matching: find.byType(Icon)),
        );
        expect(bounds.contains(icon.topLeft), isTrue);
        expect(bounds.contains(icon.bottomRight), isTrue);
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mobile Aa toggles a real inline format row and sends formatted content',
    (tester) async {
      final state = ComposerOffice();
      await mountComposer(tester, state, width: 390, mobile: true);
      await tester.enterText(input, '共同目标');
      tester.widget<TextField>(input).controller!.selection =
          const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pumpAndSettle();
      await click(tester, find.byKey(const ValueKey('composer-format')));
      expect(
        find.byKey(const ValueKey('composer-inline-bold')),
        findsOneWidget,
      );
      await click(tester, find.byKey(const ValueKey('composer-inline-bold')));
      await click(tester, find.byKey(const ValueKey('composer-format-close')));
      expect(find.byKey(const ValueKey('composer-agent')), findsOneWidget);
      await click(tester, sendButton);
      expect(state.sent.single['rich_text'], {
        'version': 1,
        'spans': [
          {
            'start': 0,
            'end': 2,
            'styles': ['bold'],
          },
        ],
      });
      expect(sendButton, findsNothing);
    },
  );
  testWidgets(
    'mobile plus toggles shut on the second tap and retains work tools',
    (tester) async {
      await mountComposer(tester, ComposerOffice(), width: 390, mobile: true);
      await click(tester, find.byKey(const ValueKey('composer-more')));
      expect(find.text('文件与图片'), findsOneWidget);
      expect(find.text('云文档'), findsWidgets);
      await click(tester, find.byKey(const ValueKey('composer-more')));
      expect(find.text('文件与图片'), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile-composer-tools')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'mobile keyboard leaves input and send above its top edge without overflow',
    (tester) async {
      await mountComposer(tester, ComposerOffice(), width: 390, mobile: true);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(input, '键盘上方的草稿');
      await tester.pumpAndSettle();
      expect(tester.getRect(sendButton).bottom, lessThanOrEqualTo(544));
      expect(tester.getRect(input).bottom, lessThanOrEqualTo(544));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mobile expanded title survives collapse and reopening without duplicate encoding',
    (tester) async {
      final state = ComposerOffice();
      await mountComposer(tester, state, width: 390, mobile: true);
      await tester.enterText(input, '协作正文');
      await click(tester, find.byTooltip('展开消息编辑器'));
      await tester.enterText(
        find.byKey(const ValueKey('expanded-title')),
        '共同计划',
      );
      await click(tester, find.byKey(const ValueKey('expanded-collapse')));
      expect(tester.widget<TextField>(input).controller!.text, '共同计划\n协作正文');
      await click(tester, find.byTooltip('展开消息编辑器'));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('expanded-title')))
            .controller!
            .text,
        '共同计划',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('expanded-body')))
            .controller!
            .text,
        '协作正文',
      );
      await click(tester, find.byKey(const ValueKey('expanded-collapse')));
      expect(tester.widget<TextField>(input).controller!.text, '共同计划\n协作正文');
      await click(tester, sendButton);
      expect(state.sent.single['rich_text'], {
        'version': 1,
        'spans': [
          {
            'start': 0,
            'end': 4,
            'styles': ['bold'],
          },
        ],
      });
    },
  );
  testWidgets(
    'manual first-line edits prevent a stale expanded title from reappearing',
    (tester) async {
      await mountComposer(tester, ComposerOffice(), width: 390, mobile: true);
      await tester.enterText(input, '正文');
      await click(tester, find.byTooltip('展开消息编辑器'));
      await tester.enterText(
        find.byKey(const ValueKey('expanded-title')),
        '旧标题',
      );
      await click(tester, find.byKey(const ValueKey('expanded-collapse')));
      await tester.enterText(input, '已经修改\n正文');
      await click(tester, find.byTooltip('展开消息编辑器'));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('expanded-title')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('expanded-body')))
            .controller!
            .text,
        '已经修改\n正文',
      );
      await click(tester, find.byKey(const ValueKey('expanded-collapse')));
      expect(tester.widget<TextField>(input).controller!.text, '已经修改\n正文');
    },
  );
  testWidgets(
    'expanded send uses the same real delivery and resets the title draft',
    (tester) async {
      final state = ComposerOffice();
      await mountComposer(tester, state, width: 390, mobile: true);
      await click(tester, find.byTooltip('展开消息编辑器'));
      await tester.enterText(
        find.byKey(const ValueKey('expanded-title')),
        '发送标题',
      );
      await tester.enterText(
        find.byKey(const ValueKey('expanded-body')),
        '正文内容',
      );
      await click(tester, find.byKey(const ValueKey('expanded-send')));
      expect(state.sent.single['content'], '发送标题\n正文内容');
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await click(tester, find.byTooltip('展开消息编辑器'));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('expanded-title')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );
  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'mobile' : 'desktop'} expanded Agent opens full collaboration and returns mentions into the draft',
      (tester) async {
        final state = ComposerOffice();
        await mountComposer(
          tester,
          state,
          width: mobile ? 390 : 900,
          mobile: mobile,
        );
        await click(tester, find.byTooltip('展开消息编辑器'));
        final body = find.byKey(const ValueKey('expanded-body'));
        await tester.enterText(body, '展开中的私人草稿');
        await click(tester, find.byKey(const ValueKey('expanded-agent')));
        expect(find.text('添加 Agent'), findsOneWidget);
        expect(find.text('分派任务'), findsOneWidget);
        expect(find.text('工作记录与成果'), findsOneWidget);
        expect(find.text('人格与参与'), findsOneWidget);
        await click(tester, find.byTooltip('关闭 Agent 协作'));
        expect(tester.widget<TextField>(body).controller!.text, '展开中的私人草稿');
        expect(state.sent, isEmpty);
        await click(tester, find.byKey(const ValueKey('expanded-agent')));
        await click(tester, find.text('@ 协作'));
        expect(find.text('1 位明确提及'), findsOneWidget);
        expect(tester.widget<TextField>(body).controller!.text, '展开中的私人草稿');
        await click(tester, find.byKey(const ValueKey('expanded-send')));
        expect(state.sent.single['content'], '展开中的私人草稿');
        expect(state.sent.single['mentions'], ['agent-demo']);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'expanded Agent records saves the draft before leaving the editor',
    (tester) async {
      final state = ComposerOffice();
      await mountComposer(tester, state, width: 390, mobile: true);
      await click(tester, find.byTooltip('展开消息编辑器'));
      await tester.enterText(
        find.byKey(const ValueKey('expanded-title')),
        '待办标题',
      );
      await tester.enterText(
        find.byKey(const ValueKey('expanded-body')),
        '稍后续写',
      );
      await click(tester, find.byKey(const ValueKey('expanded-agent')));
      await click(tester, find.text('工作记录与成果'));
      expect(find.byKey(const ValueKey('expanded-body')), findsNothing);
      expect(find.byTooltip('关闭 Agent 协作'), findsNothing);
      expect(state.sent, isEmpty);
      await click(tester, find.text('消息').first);
      expect(tester.widget<TextField>(input).controller!.text, '待办标题\n稍后续写');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'switching identity inside expanded Agent cannot return a stale mention',
    (tester) async {
      final state = ComposerOffice();
      await mountComposer(tester, state, width: 390, mobile: true);
      await click(tester, find.byTooltip('展开消息编辑器'));
      await tester.enterText(
        find.byKey(const ValueKey('expanded-body')),
        '旧身份内容',
      );
      await click(tester, find.byKey(const ValueKey('expanded-agent')));
      state.changeIdentity();
      await tester.pumpAndSettle();
      expect(find.text('@ 协作'), findsNothing);
      expect(find.text('旧身份内容'), findsNothing);
      await click(tester, find.text('关闭'));
      expect(find.text('工作身份或会话已变化，请重新打开编辑器。'), findsOneWidget);
      expect(find.byKey(const ValueKey('expanded-send')), findsNothing);
      expect(state.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'expanded Agent store applies its draft before shell navigation',
    (tester) async {
      final state = ComposerOffice();
      String? savedBeforeNavigation;
      await mountComposer(
        tester,
        state,
        width: 390,
        mobile: true,
        onAgentStore: () {
          savedBeforeNavigation = tester
              .widget<TextField>(input)
              .controller!
              .text;
        },
      );
      await click(tester, find.byTooltip('展开消息编辑器'));
      await tester.enterText(
        find.byKey(const ValueKey('expanded-body')),
        '保留商店前的编辑',
      );
      await click(tester, find.byKey(const ValueKey('expanded-agent')));
      await click(tester, find.text('Agent 商店'));
      expect(savedBeforeNavigation, '保留商店前的编辑');
      expect(find.byKey(const ValueKey('expanded-body')), findsNothing);
      expect(state.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  for (final cancellation in [false, true]) {
    testWidgets(
      'native screenshot ${cancellation ? 'cancellation has no upload' : 'attaches captured bytes without sending'}',
      (tester) async {
        final calls = <String>[];
        mockScreenshot(tester, (call) async {
          calls.add(call.method);
          return call.method == 'capability'
              ? capability
              : cancellation
              ? null
              : screenshot;
        });
        final state = ComposerOffice();
        await mountComposer(tester, state);
        await click(tester, find.byKey(const ValueKey('composer-screenshot')));
        expect(calls, ['capability', 'capture']);
        expect(state.uploaded, cancellation ? isEmpty : ['截图.png']);
        expect(state.sent, isEmpty);
        if (!cancellation) {
          expect(find.text('截图.png'), findsOneWidget);
          expect(tester.widget<IconButton>(sendButton).onPressed, isNotNull);
        }
      },
      variant: const TargetPlatformVariant({TargetPlatform.macOS}),
    );
  }
  testWidgets(
    'screenshot hide-window choice reaches native capture explicitly',
    (tester) async {
      Map? captureArgs;
      mockScreenshot(tester, (call) async {
        if (call.method == 'capability') return capability;
        captureArgs = call.arguments as Map?;
        return null;
      });
      await mountComposer(tester, ComposerOffice());
      await click(
        tester,
        find.byKey(const ValueKey('composer-screenshot-menu')),
      );
      await click(tester, find.text('截图时隐藏人机窗口'));
      expect(captureArgs, {'hide_window': true});
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'late screenshot after switching accounts never uploads into the new identity',
    (tester) async {
      final pending = Completer<Object?>();
      mockScreenshot(
        tester,
        (call) async =>
            call.method == 'capability' ? capability : pending.future,
      );
      final state = ComposerOffice();
      await mountComposer(tester, state);
      await tester.tap(find.byKey(const ValueKey('composer-screenshot')));
      await tester.pump();
      state.changeIdentity();
      pending.complete(screenshot);
      await tester.pumpAndSettle();
      expect(state.uploaded, isEmpty);
      expect(find.text('截图.png'), findsNothing);
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
  testWidgets(
    'screen permission refusal is distinct from cancelling a selection',
    (tester) async {
      final calls = <String>[];
      mockScreenshot(tester, (call) async {
        calls.add(call.method);
        return call.method == 'capability'
            ? {...capability, 'available': false, 'requires_permission': true}
            : false;
      });
      final state = ComposerOffice();
      await mountComposer(tester, state);
      await click(tester, find.byKey(const ValueKey('composer-screenshot')));
      expect(calls, ['capability', 'requestPermission']);
      expect(find.textContaining('允许人机录制屏幕'), findsOneWidget);
      expect(state.uploaded, isEmpty);
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );
}
