import 'package:active_office/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_search_test.dart' show SearchLayoutState;

Finder searchField(String hint) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == hint,
);

void main() {
  testWidgets('sidebar opens a single global IME client before typing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1512, 982);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = SearchLayoutState();
    addTearDown(state.dispose);
    await tester.pumpWidget(ActiveOfficeApp(state: state));
    await tester.pumpAndSettle();
    final sidebar = searchField('搜索');
    final entry = tester.widget<TextField>(sidebar);
    expect(entry.readOnly, isTrue);
    expect(entry.canRequestFocus, isFalse);
    await tester.tap(sidebar);
    await tester.pumpAndSettle();
    final sidebarInput = tester.state<EditableTextState>(
      find.descendant(of: sidebar, matching: find.byType(EditableText)),
    );
    final global = searchField('搜索人、Agent 和工作内容');
    expect(global, findsOneWidget);
    final globalInput = tester.state<EditableTextState>(
      find.descendant(of: global, matching: find.byType(EditableText)),
    );
    expect(sidebarInput.widget.focusNode.hasFocus, isFalse);
    expect(globalInput.widget.focusNode.hasFocus, isTrue);
    for (final candidate in ['q', 'qi', 'qiy', 'qiye']) {
      final value = TextEditingValue(
        text: candidate,
        selection: TextSelection.collapsed(offset: candidate.length),
        composing: TextRange(start: 0, end: candidate.length),
      );
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
      expect(globalInput.widget.controller.value, value);
      expect(sidebarInput.widget.controller.text, isEmpty);
      expect(globalInput.widget.focusNode.hasFocus, isTrue);
    }
    const committed = TextEditingValue(
      text: '企业',
      selection: TextSelection.collapsed(offset: 2),
    );
    tester.testTextInput.updateEditingValue(committed);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(globalInput.widget.controller.value, committed);
    expect(state.queries.map((q) => q['q']), ['企业']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
