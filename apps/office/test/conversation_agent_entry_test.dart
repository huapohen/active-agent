import 'package:active_office/ui/conversation.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversation_composer_alignment_test.dart' show ComposerOffice, input;

class AgentEntryHarness extends StatefulWidget {
  const AgentEntryHarness({
    super.key,
    required this.office,
    required this.mobile,
    this.onConsume,
    this.initialRequest = 0,
  });
  final ComposerOffice office;
  final bool mobile;
  final VoidCallback? onConsume;
  final int initialRequest;
  @override
  State<AgentEntryHarness> createState() => AgentEntryHarnessState();
}

class AgentEntryHarnessState extends State<AgentEntryHarness> {
  late int request = widget.initialRequest;
  int handled = 0, incarnation = 0;
  void deliver(int id) => setState(() => request = id);
  void remount() => setState(() => incarnation++);
  @override
  Widget build(BuildContext context) => OfficeConversation(
    key: ValueKey(incarnation),
    state: widget.office,
    mobile: widget.mobile,
    agentEntryRequest: request,
    onAgentEntryHandled: () {
      setState(() {
        handled++;
        request = 0;
      });
      widget.onConsume?.call();
    },
  );
}

Future<({ComposerOffice office, GlobalKey<AgentEntryHarnessState> harness})>
mountAgentEntry(
  WidgetTester tester, {
  bool mobile = true,
  VoidCallback? onConsume,
  ComposerOffice? state,
  int initialRequest = 0,
}) async {
  tester.view.physicalSize = Size(mobile ? 402 : 1000, 874);
  tester.view.devicePixelRatio = 1;
  final office = state ?? ComposerOffice();
  final harness = GlobalKey<AgentEntryHarnessState>();
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    office.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: AgentEntryHarness(
          key: harness,
          office: office,
          mobile: mobile,
          onConsume: onConsume,
          initialRequest: initialRequest,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (office: office, harness: harness);
}

void main() {
  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'mobile' : 'desktop'} menu request uses real composer Agent collaboration and retains draft mentions',
      (tester) async {
        final fixture = await mountAgentEntry(tester, mobile: mobile);
        await tester.enterText(input, '保留现有工作草稿');
        fixture.harness.currentState!.deliver(1);
        await tester.pumpAndSettle();
        expect(fixture.harness.currentState!.handled, 1);
        expect(fixture.harness.currentState!.request, 0);
        for (final text in [
          'Agent 协作',
          '添加 Agent',
          '分派任务',
          '工作记录与成果',
          '人格与参与',
        ]) {
          expect(find.text(text), findsOneWidget);
        }
        await tester.tap(find.text('@ 协作'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, '保留现有工作草稿');
        expect(fixture.office.sent, isEmpty);
        fixture.harness.currentState!.remount();
        await tester.pumpAndSettle();
        expect(find.text('Agent 协作'), findsNothing);
        expect(fixture.harness.currentState!.handled, 1);
        if (mobile) {
          await tester.tap(input);
          await tester.testTextInput.receiveAction(TextInputAction.send);
        } else {
          await tester.tap(find.byKey(const ValueKey('composer-send')));
        }
        await tester.pumpAndSettle();
        expect(fixture.office.sent.single['mentions'], ['agent-demo']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a newly opened conversation consumes its initial Agent request once',
    (tester) async {
      final fixture = await mountAgentEntry(tester, initialRequest: 9);
      expect(find.text('Agent 协作'), findsOneWidget);
      expect(fixture.harness.currentState!.handled, 1);
      await tester.tap(find.byTooltip('关闭 Agent 协作'));
      await tester.pumpAndSettle();
      fixture.harness.currentState!.remount();
      await tester.pumpAndSettle();
      expect(find.text('Agent 协作'), findsNothing);
      expect(fixture.harness.currentState!.handled, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity changed before request frame cannot open a stale Agent panel',
    (tester) async {
      final fixture = await mountAgentEntry(tester);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => fixture.office.changeIdentity(),
      );
      fixture.harness.currentState!.deliver(1);
      await tester.pumpAndSettle();
      expect(find.text('Agent 协作'), findsNothing);
      expect(fixture.harness.currentState!.handled, 0);
      expect(fixture.office.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'consumption callback changing scope is checked before opening the panel',
    (tester) async {
      final office = ComposerOffice();
      final fixture = await mountAgentEntry(
        tester,
        state: office,
        onConsume: office.changeIdentity,
      );
      fixture.harness.currentState!.deliver(1);
      await tester.pumpAndSettle();
      expect(fixture.harness.currentState!.handled, 1);
      expect(find.text('Agent 协作'), findsNothing);
      expect(fixture.office.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
