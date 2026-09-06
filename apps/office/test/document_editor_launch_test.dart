import 'dart:async';

import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/document_editor_launcher.dart';
import 'package:active_office/ui/document_editor_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show IndependentBusinessOfficeState;

class EditorLaunchOffice extends IndependentBusinessOfficeState {
  @override
  Future<Uri> documentEditorUrl(String id, {required String roomId}) async =>
      Uri.parse('https://office.example/office-document#open=synthetic-ticket');
  @override
  Future<Json> saveDocument({
    String? id,
    required String title,
    required String content,
    int? baseRevision,
    String? roomId,
  }) async => throw OfficeException(409, '共同文档版本冲突');
}

class ReservedEditorWindow implements DocumentEditorWindow {
  final events = <String>[];
  bool failNavigation = false;
  @override
  Future<void> navigate(Uri url) async {
    events.add('navigate:$url');
    if (failNavigation) throw StateError('window closed');
  }

  @override
  void close() => events.add('close');
}

void main() {
  test(
    'Editor window is reserved before asynchronous ticket issuance',
    () async {
      final order = <String>[];
      final ticket = Completer<Uri>();
      final window = ReservedEditorWindow();
      final opening = openOfficeDocumentEditor(
        () {
          order.add('issue ticket');
          return ticket.future;
        },
        reserveWindow: () {
          order.add('reserve window');
          return window;
        },
      );
      expect(order, ['reserve window', 'issue ticket']);
      expect(window.events, isEmpty);
      ticket.complete(
        Uri.parse('https://office.example/office-document#open=synthetic'),
      );
      await opening;
      expect(window.events, [
        'navigate:https://office.example/office-document#open=synthetic',
      ]);
    },
  );

  test('Blocked popup does not request a ticket', () async {
    var requested = false;
    await expectLater(
      openOfficeDocumentEditor(() async {
        requested = true;
        return Uri.parse('https://office.example/office-document');
      }, reserveWindow: () => throw StateError('popup blocked')),
      throwsStateError,
    );
    expect(requested, isFalse);
  });

  test('Failed ticket or navigation closes the reserved window', () async {
    final ticketFailure = ReservedEditorWindow();
    await expectLater(
      openOfficeDocumentEditor(
        () async => throw StateError('ticket unavailable'),
        reserveWindow: () => ticketFailure,
      ),
      throwsStateError,
    );
    expect(ticketFailure.events, ['close']);
    final navigationFailure = ReservedEditorWindow()..failNavigation = true;
    await expectLater(
      openOfficeDocumentEditor(
        () async => Uri.parse('https://office.example/office-document'),
        reserveWindow: () => navigationFailure,
      ),
      throwsStateError,
    );
    expect(navigationFailure.events, [
      'navigate:https://office.example/office-document',
      'close',
    ]);
  });

  testWidgets(
    'Editor launch failure does not offer document merge; save conflict does',
    (tester) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      MethodCall? launched;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') launched = call;
        return false;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(943, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = EditorLaunchOffice();
      state.endpoint = 'https://editor-launch.example';
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('云文档').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('独立共同文档'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('协作编辑器'));
      await tester.pumpAndSettle();
      expect(
        launched?.arguments['url'],
        'https://office.example/office-document#open=synthetic-ticket',
      );
      expect(launched?.arguments['useWebView'], isFalse);
      expect(launched?.arguments['useSafariVC'], isFalse);
      expect(find.text('无法打开浏览器，请检查系统默认浏览器'), findsOneWidget);
      expect(find.text('读取最新版本并合并'), findsNothing);
      await tester.tap(find.text('保存共同文档'));
      await tester.pumpAndSettle();
      expect(find.text('共同文档版本冲突'), findsOneWidget);
      expect(find.text('读取最新版本并合并'), findsOneWidget);
      expect(find.text('独立业务正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
