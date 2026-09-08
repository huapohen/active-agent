import 'dart:async';

import 'package:active_office/meeting_controller.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/meeting_home_widgets.dart';
import 'package:active_office/ui/meetings.dart';
import 'package:active_office/ui/office_theme.dart'
    show officeTheme, PersonAvatar;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class MeetingFixture extends OfficeState {
  MeetingFixture() {
    endpoint = 'https://meeting-fixture.example';
    me = {'id': 'person-a', 'name': '合成同事', 'kind': 'human'};
    connected = true;
    rooms = [
      {'id': 'room-a', 'name': '合成会议工作群', 'created_by': 'person-a'},
    ];
    selectedRoomId = 'room-a';
    detail = {
      'room': rooms.single,
      'members': [
        {'principal_id': 'person-a', 'role': 'owner', 'name': '合成同事'},
      ],
    };
    allDocuments = [
      {'id': 'document-a', 'title': '合成纪要', 'room_id': 'room-a'},
    ];
    meetings = [
      {
        'id': 'meeting-future',
        'title': '合成未来会议',
        'created_by': 'person-b',
        'room_id': 'room-a',
        'starts_at': '2027-01-01T02:00:00Z',
        'duration_minutes': 30,
        'status': 'scheduled',
      },
      {
        'id': 'meeting-past',
        'title': '合成历史会议',
        'created_by': 'person-b',
        'room_id': 'room-a',
        'starts_at': '2026-01-01T02:00:00Z',
        'duration_minutes': 30,
        'ended_at': '2026-01-01T02:30:00Z',
        'status': 'ended',
        'calendar_event_id': 'event-past',
      },
    ];
  }
  int generation = 0;
  @override
  int get identityGeneration => generation;
  final creates = <Json>[], binds = <String>[], endings = <String>[];
  Completer<Json>? createGate, detailGate;
  Json? detailOverride;
  void switchIdentity() {
    generation++;
    me = {...me!, 'id': 'person-b'};
    notifyListeners();
  }

  @override
  Future<Json> createMeeting({
    required String title,
    String? startsAt,
    int durationMinutes = 30,
    String? documentId,
    String? roomId,
  }) async {
    creates.add({
      'title': title,
      'starts_at': startsAt,
      'room_id': roomId,
      'duration_minutes': durationMinutes,
      'document_id': documentId,
    });
    return createGate?.future ?? {'id': 'meeting-created'};
  }

  @override
  Future<Json> meetingDetail(String id) async =>
      detailGate?.future ??
      detailOverride ??
      {
        'meeting': meetings.firstWhere((m) => m['id'] == id),
        'participants': [
          {'name': '临时在线信息，不是历史参与者'},
        ],
      };
  @override
  Future<void> bindMeetingNotes(Json meeting, String documentId) async =>
      binds.add(documentId);
  @override
  Future<void> endMeeting(String id) async => endings.add(id);
}

class MeetingMediaFixture extends MeetingMediaController {
  final joins = <String>[];
  int leaves = 0;
  @override
  Future<void> join(OfficeState office, String id) async {
    joins.add(id);
  }

  @override
  Future<void> leave() async {
    leaves++;
  }
}

Future<void> mountMeetings(
  WidgetTester tester,
  MeetingFixture state,
  MeetingMediaFixture media, {
  double width = 1100,
  double scale = 1,
  VoidCallback? calendar,
  VoidCallback? minutes,
}) async {
  tester.view.physicalSize = Size(width, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: OfficeMeetings(
          state: state,
          media: media,
          onCalendar: calendar ?? () {},
          onMinutes: minutes ?? () {},
          mobileHeaderLeading: const CircleAvatar(radius: 18, child: Text('我')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder entry(String label) => find.byKey(ValueKey('meeting-entry-$label'));

void main() {
  testWidgets(
    'desktop launcher has two columns with concurrent upcoming and history',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      await mountMeetings(tester, state, media);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('meeting-launcher-pane')))
            .width,
        350,
      );
      expect(
        tester.getTopLeft(entry('发起会议')).dy,
        tester.getTopLeft(entry('加入会议')).dy,
      );
      expect(
        tester.getTopLeft(entry('预约会议')).dy,
        greaterThan(tester.getBottomLeft(entry('发起会议')).dy),
      );
      expect(find.text('合成未来会议'), findsOneWidget);
      expect(find.text('合成历史会议'), findsOneWidget);
      expect(media.joins, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 402.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('mobile meeting home and idle join fit $width at $scale', (
        tester,
      ) async {
        final state = MeetingFixture(), media = MeetingMediaFixture();
        await mountMeetings(tester, state, media, width: width, scale: scale);
        expect(
          tester.getTopLeft(entry('发起会议')).dy,
          tester.getTopLeft(entry('人机妙记')).dy,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(entry('加入会议'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('meeting-join-idle-preview')),
          findsOneWidget,
        );
        expect(find.text('麦克风'), findsOneWidget);
        expect(find.text('摄像头'), findsOneWidget);
        expect(find.text('扬声器'), findsOneWidget);
        expect(media.joins, isEmpty);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭加入会议'));
        await tester.pumpAndSettle();
        expect(find.byType(OfficeMeetingHome), findsOneWidget);
      });
    }
  }

  testWidgets(
    'narrow join stays scrollable when the software keyboard is visible',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      await mountMeetings(tester, state, media, width: 320, scale: 1.3);
      await tester.tap(entry('加入会议'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 420);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(OfficeMeetingJoinPreview),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(media.joins, isEmpty);
    },
  );

  testWidgets(
    'mobile join uses full white safe area, readable underline and 188 avatar',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      await mountMeetings(tester, state, media, width: 402);
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
      addTearDown(tester.view.resetPadding);
      await tester.pump();
      await tester.tap(entry('加入会议'));
      await tester.pumpAndSettle();
      final fieldFinder = find.byKey(const ValueKey('meeting-join-id-input'));
      final field = tester.widget<TextField>(fieldFinder);
      expect(field.decoration!.hintStyle!.fontSize, 24);
      expect(field.style!.fontSize, 24);
      expect(field.decoration!.filled, isFalse);
      expect(field.decoration!.border, isA<UnderlineInputBorder>());
      expect(field.decoration!.focusedBorder, isA<UnderlineInputBorder>());
      expect(tester.getSize(fieldFinder).width, 210);
      expect(tester.getSize(find.byType(PersonAvatar)).width, 188);
      final dialog = tester.getRect(
        find.byKey(const ValueKey('meeting-join-fullscreen')),
      );
      expect(dialog.top, 0);
      expect(dialog.bottom, 820);
      final buttonText = tester.widget<Text>(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.text('加入会议'),
        ),
      );
      expect(buttonText.style!.fontSize, 17);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [650.0, 1036.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'desktop join keeps compact device controls and join on one row at $width / $scale',
        (tester) async {
          final state = MeetingFixture(), media = MeetingMediaFixture();
          await mountMeetings(tester, state, media, width: width, scale: scale);
          await tester.tap(entry('加入会议'));
          await tester.pumpAndSettle();
          final mic = tester.getRect(
            find.byKey(const ValueKey('meeting-desktop-microphone')),
          );
          final camera = tester.getRect(
            find.byKey(const ValueKey('meeting-desktop-camera')),
          );
          final speaker = tester.getRect(
            find.byKey(const ValueKey('meeting-desktop-speaker')),
          );
          final join = tester.getRect(
            find.byKey(const ValueKey('meeting-desktop-join-button')),
          );
          expect(mic.width, 114);
          expect(camera.width, 114);
          expect(speaker.width, inInclusiveRange(200.0, 210.0));
          expect(join.width, 120);
          expect(mic.top, join.top);
          expect(camera.top, join.top);
          expect(speaker.top, join.top);
          expect(speaker.right, lessThan(join.left));
          expect(tester.takeException(), isNull);
          expect(media.joins, isEmpty);
        },
      );
    }
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets(
      'desktop upcoming meetings retain real status in compact two-line rows at $scale',
      (tester) async {
        final state = MeetingFixture(), media = MeetingMediaFixture();
        state.meetings = [
          {...state.meetings.first, 'status': 'active', 'participant_count': 3},
          {
            ...state.meetings.first,
            'id': 'meeting-second',
            'title': '第二场真实标题',
            'status': 'scheduled',
          },
        ];
        await mountMeetings(tester, state, media, width: 1036, scale: scale);
        final first = tester.getRect(
          find.byKey(const ValueKey('meeting-record-meeting-future')),
        );
        final second = tester.getRect(
          find.byKey(const ValueKey('meeting-record-meeting-second')),
        );
        expect(
          first.height,
          inInclusiveRange(scale == 1 ? 68.0 : 78.0, scale == 1 ? 71.0 : 82.0),
        );
        expect(second.top - first.bottom, closeTo(1, .1));
        expect(find.byTooltip(RegExp('进行中 · 当前在线 3 个会话')), findsOneWidget);
        expect(
          find.textContaining('进行中 · 当前在线 3 个会话', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('meeting-record-meeting-future')),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('meeting-join-id-input')),
              )
              .controller!
              .text,
          'meeting-future',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mobile join reserves measured lower margin and input-preview gap',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      await mountMeetings(tester, state, media, width: 402);
      await tester.tap(entry('加入会议'));
      await tester.pumpAndSettle();
      final input = tester.getRect(
        find.byKey(const ValueKey('meeting-join-id-input')),
      );
      final preview = tester.getRect(
        find.byKey(const ValueKey('meeting-join-idle-preview')),
      );
      final join = tester.getRect(find.byType(FilledButton));
      expect(preview.top - input.bottom, 30);
      expect(820 - join.bottom, 42);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('join submits real ID once and closing preview never joins', (
    tester,
  ) async {
    final state = MeetingFixture(), media = MeetingMediaFixture();
    await mountMeetings(tester, state, media);
    await tester.tap(entry('加入会议'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' meeting-future ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '加入会议'));
    await tester.pumpAndSettle();
    expect(media.joins, ['meeting-future']);
    await tester.tap(entry('加入会议'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭加入会议'));
    await tester.pumpAndSettle();
    expect(media.joins.length, 1);
  });

  testWidgets(
    'create uses captured room and calendar/minutes navigate through real callbacks',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      var calendar = 0, minutes = 0;
      await mountMeetings(
        tester,
        state,
        media,
        calendar: () => calendar++,
        minutes: () => minutes++,
      );
      await tester.tap(entry('人机妙记'));
      await tester.tap(find.text('在日历中查看全部 ›'));
      expect([calendar, minutes], [1, 1]);
      await tester.tap(entry('发起会议'));
      await tester.pumpAndSettle();
      state.selectedRoomId = 'room-other';
      await tester.tap(find.text('发起并加入'));
      await tester.pumpAndSettle();
      expect(state.creates.single['room_id'], 'room-a');
      expect(media.joins, ['meeting-created']);
    },
  );

  for (final scale in [1.0, 1.3]) {
    testWidgets(
      '320 wide create can select a long document title with a long room name at $scale',
      (tester) async {
        final state = MeetingFixture(), media = MeetingMediaFixture();
        const longRoom = '人机原生办公协作平台跨端界面与协议联合验收工作讨论群';
        const longTitle = '2026年9月会议纪要：人和 Agent 同权协作平台移动端与桌面端全部页面功能对照和后续执行方案';
        state.rooms.single['name'] = longRoom;
        state.allDocuments = [
          {'id': 'document-long', 'title': longTitle, 'room_id': 'room-a'},
          {'id': 'document-second', 'title': '第二份会议资料', 'room_id': 'room-a'},
        ];
        await mountMeetings(tester, state, media, width: 320, scale: scale);
        await tester.tap(entry('发起会议'));
        await tester.pumpAndSettle();
        final selector = find.byKey(
          const ValueKey('meeting-document-selector'),
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(selector);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        final option = find.byKey(
          const ValueKey('meeting-document-option-document-long'),
        );
        await tester.ensureVisible(option);
        expect(tester.takeException(), isNull);
        final menuTitle = tester.widget<Text>(
          find.descendant(of: option, matching: find.byType(Text)),
        );
        expect(menuTitle.data, longTitle);
        expect(menuTitle.maxLines, isNull);
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(find.byTooltip(longTitle), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('发起并加入'));
        await tester.pumpAndSettle();
        expect(state.creates.single['document_id'], 'document-long');
        expect(state.creates.single['room_id'], 'room-a');
        expect(media.joins, ['meeting-created']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final label in ['发起会议', '预约会议', '加入会议']) {
    testWidgets('old $label route cannot dispatch after A to B to A', (
      tester,
    ) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      await mountMeetings(tester, state, media);
      await tester.tap(entry(label));
      await tester.pumpAndSettle();
      final buttons = tester
          .widgetList<FilledButton>(find.byType(FilledButton))
          .toList();
      final oldAction = buttons.last.onPressed;
      state.switchIdentity();
      state.me = {...state.me!, 'id': 'person-a'};
      oldAction?.call();
      await tester.pumpAndSettle();
      expect(find.text('工作身份已变化'), findsOneWidget);
      expect(state.creates, isEmpty);
      expect(media.joins, isEmpty);
    });
  }

  testWidgets(
    'pending schedule disables nested pickers and does not auto join',
    (tester) async {
      final state = MeetingFixture()..createGate = Completer<Json>();
      final media = MeetingMediaFixture();
      await mountMeetings(tester, state, media, width: 320);
      await tester.tap(entry('预约会议'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '合成预约');
      await tester.tap(find.widgetWithText(FilledButton, '预约会议'));
      await tester.pump();
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      state.createGate!.complete({'id': 'meeting-created'});
      await tester.pumpAndSettle();
      expect(state.creates.single['starts_at'], isNotNull);
      expect(media.joins, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history shows durable metadata without claiming ephemeral participation history',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      await mountMeetings(tester, state, media);
      await tester.tap(find.text('合成历史会议'));
      await tester.pumpAndSettle();
      expect(find.textContaining('历史参会名单未保存'), findsOneWidget);
      expect(find.textContaining('临时在线信息'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMeetingHome), findsOneWidget);
    },
  );

  testWidgets(
    'room owner can manage non-created meeting and stale host action cannot end',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      media.activeMeeting = state.meetings.first;
      await mountMeetings(tester, state, media);
      expect(find.byTooltip('主持人操作'), findsOneWidget);
      await tester.tap(find.byTooltip('主持人操作'));
      await tester.pumpAndSettle();
      state.switchIdentity();
      await tester.tap(find.text('结束所有人的会议'));
      await tester.pumpAndSettle();
      expect(state.endings, isEmpty);
      expect(media.leaves, 0);
    },
  );

  testWidgets(
    'note picker hides old documents and cannot bind after identity change',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      media.activeMeeting = state.meetings.first;
      await mountMeetings(tester, state, media);
      await tester.tap(find.byTooltip('共同纪要文档'));
      await tester.pumpAndSettle();
      expect(find.text('合成纪要'), findsOneWidget);
      final option = tester.widget<SimpleDialogOption>(
        find.byType(SimpleDialogOption),
      );
      state.switchIdentity();
      option.onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('工作身份已变化'), findsOneWidget);
      expect(find.text('合成纪要'), findsNothing);
      expect(state.binds, isEmpty);
    },
  );

  testWidgets(
    'unsupported webinar entry explains unavailable service without creating work',
    (tester) async {
      final state = MeetingFixture(), media = MeetingMediaFixture();
      await mountMeetings(tester, state, media);
      await tester.tap(entry('网络研讨会'));
      await tester.pumpAndSettle();
      expect(find.textContaining('报名、观众席和主持人控制尚未接入'), findsOneWidget);
      expect(state.creates, isEmpty);
      expect(media.joins, isEmpty);
    },
  );
}
