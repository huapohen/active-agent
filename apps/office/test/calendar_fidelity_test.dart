import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/calendar.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class CalendarFixture extends OfficeState {
  CalendarFixture({String kind = 'human', String role = 'member'}) {
    endpoint = 'https://calendar-fixture.invalid';
    me = {'id': 'self', 'name': '日历测试成员', 'kind': kind};
    principals = [
      me!,
      {'id': 'colleague', 'name': '策划同事', 'kind': 'human'},
      {'id': 'agent', 'name': '日程 Agent', 'kind': 'agent'},
    ];
    rooms = [
      {
        'id': 'room-a',
        'name': '产品协作',
        'created_by': role == 'owner' ? 'self' : 'colleague',
      },
      {'id': 'room-b', 'name': '研发协作', 'created_by': 'colleague'},
    ];
    // Match real roomView / library responses: only full selected-room details
    // include member roles; library member records omit them.
    libraryRooms = rooms.map((r) => {...r, 'members': principals}).toList();
    selectedRoomId = 'room-a';
    detail = {
      'room': rooms.first,
      'members': [
        {...me!, 'role': role},
        {...principals[1], 'role': 'member'},
        {...principals[2], 'role': 'member'},
      ],
    };
    final now = DateTime.now();
    String at(int hour, [int minute = 0]) => DateTime(
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    ).toUtc().toIso8601String();
    calendarEvents = [
      {
        'id': 'early',
        'room_id': 'room-a',
        'created_by': 'self',
        'revision': 1,
        'title': '凌晨真实日程',
        'starts_at': at(1),
        'ends_at': at(2),
        'attendee_ids': ['self', 'agent'],
        'responses': {},
      },
      {
        'id': 'normal',
        'room_id': 'room-b',
        'created_by': 'colleague',
        'revision': 1,
        'title': '下午研发评审',
        'starts_at': at(13),
        'ends_at': at(14),
        'attendee_ids': ['colleague'],
        'responses': {},
        'meeting_id': 'meeting-b',
      },
    ];
  }
  int generation = 0;
  @override
  int get identityGeneration => generation;
  final created = <Json>[];
  final updated = <Json>[];
  final responses = <String>[];
  Completer<Json>? pending;
  void changed() => notifyListeners();
  @override
  Future<Json> createCalendarEvent({
    required String title,
    required String startsAt,
    required String endsAt,
    String description = '',
    String location = '',
    List<String> attendeeIds = const [],
    String? roomId,
  }) async {
    created.add({
      'room_id': roomId,
      'title': title,
      'starts_at': startsAt,
      'ends_at': endsAt,
      'description': description,
      'location': location,
      'attendee_ids': attendeeIds,
    });
    return pending == null ? {'id': 'created'} : await pending!.future;
  }

  @override
  Future<void> updateCalendarEvent(Json event, Json changes) async {
    updated.add({
      ...changes,
      'id': event['id'],
      'base_revision': event['revision'],
    });
  }

  @override
  Future<void> respondCalendarEvent(String id, String response) async {
    responses.add('$id:$response');
  }
}

Future<GlobalKey<OfficeCalendarState>> mountCalendar(
  WidgetTester tester,
  CalendarFixture state, {
  double width = 1100,
  double height = 800,
  double scale = 1,
  bool? use24,
  EdgeInsets? safePadding,
  List<String>? meetings,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final key = GlobalKey<OfficeCalendarState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          alwaysUse24HourFormat: use24,
          padding: safePadding,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: OfficeCalendar(
          key: key,
          state: state,
          onMeeting: (id) async {
            meetings?.add(id);
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  return key;
}

Future<void> openEditor(
  WidgetTester tester,
  GlobalKey<OfficeCalendarState> key,
) async {
  unawaited(key.currentState!.createEvent());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'desktop week begins Sunday and includes all 24 hours, including early events',
    (tester) async {
      final state = CalendarFixture();
      await mountCalendar(tester, state, width: 846);
      expect(find.text('工作会话日历'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
      expect(find.text('23:00'), findsOneWidget);
      expect(find.text('凌晨真实日程'), findsOneWidget);
      final now = DateTime.now();
      final sunday = DateTime(now.year, now.month, now.day - now.weekday % 7);
      expect(
        find.byKey(
          ValueKey(
            'calendar-slot-${sunday.year}-${sunday.month}-${sunday.day}-0',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desktop day and month display real data and month cell opens the selected day',
    (tester) async {
      final state = CalendarFixture();
      await mountCalendar(tester, state);
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w.key.toString().contains('calendar-slot-'),
        ),
        findsNWidgets(24),
      );
      await tester.tap(find.byKey(const ValueKey('calendar-view-month')));
      await tester.pumpAndSettle();
      expect(find.text('凌晨真实日程'), findsOneWidget);
      final now = DateTime.now();
      await tester.tap(
        find.byKey(
          ValueKey('calendar-month-open-${now.year}-${now.month}-${now.day}'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w.key.toString().contains('calendar-slot-'),
        ),
        findsNWidgets(24),
      );
    },
  );
  testWidgets(
    'room filtering and personal participation filtering operate on real event scope',
    (tester) async {
      final state = CalendarFixture();
      await mountCalendar(tester, state);
      await tester.tap(find.byKey(const ValueKey('calendar-room-room-a')));
      await tester.pumpAndSettle();
      expect(find.text('凌晨真实日程'), findsNothing);
      expect(find.text('下午研发评审'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('calendar-room-room-a')));
      await tester.tap(find.text('仅我参与的日程'));
      await tester.pumpAndSettle();
      expect(find.text('凌晨真实日程'), findsOneWidget);
      expect(find.text('下午研发评审'), findsNothing);
    },
  );
  for (final width in [320.0, 402.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'mobile $width/$scale has three-day grid, inline month toggle and usable editor',
        (tester) async {
          final state = CalendarFixture();
          final key = await mountCalendar(
            tester,
            state,
            width: width,
            scale: scale,
          );
          expect(
            find.byWidgetPredicate(
              (w) => w.key.toString().contains('calendar-slot-'),
            ),
            findsNWidgets(72),
          );
          await tester.tap(find.byKey(const ValueKey('calendar-month-toggle')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('calendar-inline-month')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('calendar-month-toggle')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('calendar-inline-month')),
            findsNothing,
          );
          await openEditor(tester, key);
          expect(find.text('添加主题'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('calendar-attendee-entry')),
            findsOneWidget,
          );
          expect(find.byType(FilterChip), findsNothing);
          expect(find.text('保存'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(state.created, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('mobile view menu changes to real day, week and month views', (
    tester,
  ) async {
    final state = CalendarFixture();
    await mountCalendar(tester, state, width: 402);
    for (final pair in [('日', 24), ('周', 168), ('月', 0)]) {
      await tester.tap(find.byKey(const ValueKey('calendar-mobile-view-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(pair.$1).last);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w.key.toString().contains('calendar-slot-'),
        ),
        findsNWidgets(pair.$2),
      );
      expect(tester.takeException(), isNull);
    }
  });
  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind creates a real source-room event with human and Agent attendees',
      (tester) async {
        final state = CalendarFixture(kind: kind);
        final key = await mountCalendar(tester, state);
        await openEditor(tester, key);
        await tester.enterText(
          find.byKey(const ValueKey('calendar-event-title')),
          '共同交付',
        );
        await tester.tap(find.byKey(const ValueKey('calendar-attendee-entry')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('calendar-attendee-agent')));
        await tester.tap(
          find.byKey(const ValueKey('calendar-attendee-colleague')),
        );
        await tester.tap(
          find.byKey(const ValueKey('calendar-attendee-confirm')),
        );
        await tester.pumpAndSettle();
        state.selectedRoomId = 'room-b';
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(state.created.single['room_id'], 'room-a');
        expect(
          state.created.single['attendee_ids'],
          containsAll(['self', 'agent', 'colleague']),
        );
        expect(state.created.single['title'], '共同交付');
        expect(
          DateTime.parse(state.created.single['ends_at'])
              .isAfter(DateTime.parse(state.created.single['starts_at'])),
          isTrue,
        );
      },
    );
  }
  for (final field in ['generation', 'endpoint', 'principal']) {
    testWidgets(
      'stale editor callback blocks $field identity switch before next rebuild',
      (tester) async {
        final state = CalendarFixture();
        final key = await mountCalendar(tester, state);
        await openEditor(tester, key);
        await tester.enterText(
          find.byKey(const ValueKey('calendar-event-title')),
          '旧身份草稿',
        );
        final save = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed!;
        if (field == 'generation') state.generation++;
        if (field == 'endpoint') state.endpoint = 'https://other.invalid';
        if (field == 'principal') state.me = {...state.me!, 'id': 'other'};
        save();
        await tester.pumpAndSettle();
        expect(state.created, isEmpty);
        state.changed();
        await tester.pumpAndSettle();
        expect(find.text('日程草稿已过期'), findsOneWidget);
        expect(find.text('旧身份草稿'), findsNothing);
      },
    );
  }
  testWidgets(
    'identity change while choosing room cannot create a draft in the new identity',
    (tester) async {
      final state = CalendarFixture()..selectedRoomId = null;
      final key = await mountCalendar(tester, state);
      await openEditor(tester, key);
      state.generation++;
      await tester.tap(find.text('产品协作').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-event-title')), findsNothing);
      expect(state.created, isEmpty);
    },
  );
  testWidgets(
    'late save completion does not dismiss a new identity route or replay writes',
    (tester) async {
      final state = CalendarFixture()..pending = Completer<Json>();
      final key = await mountCalendar(tester, state);
      await openEditor(tester, key);
      await tester.enterText(
        find.byKey(const ValueKey('calendar-event-title')),
        '保存中草稿',
      );
      await tester.tap(find.text('保存'));
      await tester.pump();
      state.generation++;
      state.changed();
      await tester.pumpAndSettle();
      state.pending!.complete({'id': 'created'});
      await tester.pumpAndSettle();
      expect(find.text('日程草稿已过期'), findsOneWidget);
      expect(state.created, hasLength(1));
    },
  );
  testWidgets(
    'detail removes stale event data and blocks captured RSVP and meeting callbacks',
    (tester) async {
      final state = CalendarFixture();
      final meetings = <String>[];
      final key = await mountCalendar(tester, state, meetings: meetings);
      state.calendarEvents.first['meeting_id'] = 'meeting-a';
      unawaited(key.currentState!.openEvent(state.calendarEvents.first));
      await tester.pumpAndSettle();
      final respond = tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '接受'))
          .onSelected!;
      final join = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '加入会议'))
          .onPressed!;
      state.generation++;
      respond(true);
      join();
      state.changed();
      await tester.pumpAndSettle();
      expect(state.responses, isEmpty);
      expect(meetings, isEmpty);
      expect(find.text('日程已不可用'), findsOneWidget);
    },
  );
  testWidgets(
    'Agent RSVP responds as the current identity and room owner can edit another creator event',
    (tester) async {
      final state = CalendarFixture(kind: 'agent', role: 'owner');
      state.calendarEvents.first['created_by'] = 'colleague';
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(state.calendarEvents.first));
      await tester.pumpAndSettle();
      await tester.tap(find.text('接受'));
      await tester.pumpAndSettle();
      expect(state.responses, ['early:accepted']);
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('calendar-event-title')),
        '会话管理员改期',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(state.updated.single['id'], 'early');
      expect(state.updated.single['base_revision'], 1);
    },
  );
  testWidgets(
    'isolated afternoon event is full width after an overlapping morning group',
    (tester) async {
      final state = CalendarFixture();
      final now = DateTime.now();
      state.calendarEvents.add({
        ...state.calendarEvents.first,
        'id': 'early-overlap',
        'title': '重叠日程',
        'starts_at': DateTime(
          now.year,
          now.month,
          now.day,
          1,
          30,
        ).toUtc().toIso8601String(),
        'ends_at': DateTime(
          now.year,
          now.month,
          now.day,
          2,
          30,
        ).toUtc().toIso8601String(),
      });
      await mountCalendar(tester, state);
      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      double eventWidth(String id) => tester
          .getSize(find.byKey(ValueKey('calendar-event-$id-${now.day}')))
          .width;
      expect(eventWidth('early'), closeTo(eventWidth('early-overlap'), .1));
      expect(eventWidth('normal'), greaterThan(eventWidth('early') * 1.9));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unselected room creator can edit using real roomView when library omits roles',
    (tester) async {
      final state = CalendarFixture(role: 'owner');
      state.calendarEvents.first['created_by'] = 'colleague';
      state.libraryRooms = state.rooms
          .map((r) => {...r, 'members': state.principals})
          .toList();
      state.selectedRoomId = 'room-b';
      state.detail = {'room': state.rooms.last, 'members': state.principals};
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(state.calendarEvents.first));
      await tester.pumpAndSettle();
      expect(find.text('编辑日程'), findsOneWidget);
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed!;
      state.rooms.removeAt(0);
      state.libraryRooms.removeAt(0);
      state.detail = {'room': state.rooms.first, 'members': state.principals};
      save();
      await tester.pumpAndSettle();
      expect(state.updated, isEmpty);
      state.changed();
      await tester.pumpAndSettle();
      expect(find.text('日程草稿已过期'), findsOneWidget);
    },
  );
  testWidgets(
    'enterprise admin who is not author or room owner cannot edit the event',
    (tester) async {
      final state = CalendarFixture();
      state.enterpriseSummary = {
        'capabilities': {'access_admin': true},
        'membership': {'role': 'admin'},
      };
      state.calendarEvents.first['created_by'] = 'colleague';
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(state.calendarEvents.first));
      await tester.pumpAndSettle();
      expect(find.text('编辑日程'), findsNothing);
    },
  );
  testWidgets('deleted event cannot keep an editable draft alive', (
    tester,
  ) async {
    final state = CalendarFixture();
    final key = await mountCalendar(tester, state);
    unawaited(key.currentState!.openEvent(state.calendarEvents.first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑日程'));
    await tester.pumpAndSettle();
    final save = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
        .onPressed!;
    state.calendarEvents.removeAt(0);
    save();
    state.changed();
    await tester.pumpAndSettle();
    expect(state.updated, isEmpty);
    expect(find.text('日程草稿已过期'), findsOneWidget);
  });
  testWidgets(
    'search only opens a matching current event and stays read only',
    (tester) async {
      final state = CalendarFixture();
      await mountCalendar(tester, state, width: 402);
      await tester.tap(find.byTooltip('搜索日程'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '研发');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('凌晨真实日程'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('下午研发评审'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('加入会议'), findsOneWidget);
      expect(state.created, isEmpty);
      expect(state.updated, isEmpty);
    },
  );
  testWidgets(
    'mobile return-today menu restores the actual date and current time region',
    (tester) async {
      final state = CalendarFixture();
      await mountCalendar(tester, state, width: 402);
      final now = DateTime.now();
      final other = DateTime(now.year, now.month, now.day == 1 ? 2 : 1);
      await tester.tap(find.byKey(const ValueKey('calendar-month-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          ValueKey('calendar-date-${other.year}-${other.month}-${other.day}'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('calendar-month-toggle')));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('calendar-timeline-scroll')),
          )
          .controller!;
      scroll.jumpTo(0);
      await tester.pump();
      expect(
        find.byKey(
          ValueKey('calendar-slot-${other.year}-${other.month}-${other.day}-0'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('calendar-mobile-view-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回到今天'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey('calendar-slot-${now.year}-${now.month}-${now.day}-0'),
        ),
        findsOneWidget,
      );
      final expected = (now.hour < 3 ? 0 : now.hour - 3) * 52.0;
      expect(
        scroll.offset,
        closeTo(expected.clamp(0.0, scroll.position.maxScrollExtent), 1),
      );
      expect(state.created, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mobile event form is white with an unframed readable topic and explicit input hints',
    (tester) async {
      final state = CalendarFixture();
      final key = await mountCalendar(tester, state, width: 402);
      await openEditor(tester, key);
      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.backgroundColor, Colors.white);
      expect(dialog.surfaceTintColor, Colors.transparent);
      final topic = tester.widget<TextField>(
        find.byKey(const ValueKey('calendar-event-title')),
      );
      expect(topic.decoration!.hintStyle!.fontSize, 18);
      expect(topic.decoration!.enabledBorder, InputBorder.none);
      expect(topic.decoration!.focusedBorder, InputBorder.none);
      for (final hint in ['添加地点', '添加描述']) {
        final field = tester.widget<TextField>(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.hintText == hint,
          ),
        );
        expect(field.decoration!.hintStyle!.fontSize, 17);
        expect(field.decoration!.filled, isFalse);
      }
      expect(find.textContaining('本机时区 · GMT'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [846.0, 320.0]) {
    for (final scale in [1.0, 1.3]) {
      for (final count in [2, 3, 4]) {
        testWidgets(
          'month cell fits $count events at $width x 697 / $scale and overflow opens every event',
          (tester) async {
            final state = CalendarFixture();
            final now = DateTime.now();
            final template = state.calendarEvents.first;
            state.calendarEvents = List.generate(
              count,
              (i) => {
                ...template,
                'id': 'dense-$i',
                'title': '同一天的第${i + 1}项真实安排',
                'starts_at': DateTime(
                  now.year,
                  now.month,
                  now.day,
                  10 + i,
                ).toUtc().toIso8601String(),
                'ends_at': DateTime(
                  now.year,
                  now.month,
                  now.day,
                  11 + i,
                ).toUtc().toIso8601String(),
              },
            );
            await mountCalendar(
              tester,
              state,
              width: width,
              height: 697,
              scale: scale,
            );
            if (width > 650) {
              await tester.tap(
                find.byKey(const ValueKey('calendar-view-month')),
              );
            } else {
              await tester.tap(
                find.byKey(const ValueKey('calendar-mobile-view-menu')),
              );
              await tester.pumpAndSettle();
              await tester.tap(find.text('月').last);
            }
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final more = find.byKey(
              ValueKey(
                'calendar-month-more-${now.year}-${now.month}-${now.day}',
              ),
            );
            if (count >= 3) expect(more, findsOneWidget);
            final open = more.evaluate().isNotEmpty
                ? more
                : find.byKey(
                    ValueKey(
                      'calendar-month-open-${now.year}-${now.month}-${now.day}',
                    ),
                  );
            await tester.ensureVisible(open);
            await tester.tap(open);
            await tester.pumpAndSettle();
            for (var i = 0; i < count; i++) {
              expect(
                find.byKey(ValueKey('calendar-event-dense-$i-${now.day}')),
                findsOneWidget,
              );
            }
            expect(tester.takeException(), isNull);
            expect(state.created, isEmpty);
          },
        );
      }
    }
  }
  testWidgets(
    'mobile hour grid uses reference spacing while desktop retains 48',
    (tester) async {
      final state = CalendarFixture();
      await mountCalendar(tester, state, width: 402);
      final now = DateTime.now();
      final slot = find.byKey(
        ValueKey('calendar-slot-${now.year}-${now.month}-${now.day}-13'),
      );
      expect(tester.getSize(slot).height, 52);
    },
  );
  for (final scale in [1.0, 1.3]) {
    testWidgets(
      '100 colleagues stay compact at 320 / $scale and the source picker searches actual Agents',
      (tester) async {
        final state = CalendarFixture();
        final people = List<Json>.generate(
          100,
          (i) => i == 0
              ? state.me!
              : {
                  'id': 'person-$i',
                  'name': '同事${i.toString().padLeft(3, '0')}',
                  'kind': i.isOdd ? 'agent' : 'human',
                },
        );
        state.principals = people;
        state.libraryRooms = state.rooms
            .map((r) => {...r, 'members': people})
            .toList();
        state.detail = {'room': state.rooms.first, 'members': people};
        final key = await mountCalendar(
          tester,
          state,
          width: 320,
          scale: scale,
        );
        await openEditor(tester, key);
        final entry = find.byKey(const ValueKey('calendar-attendee-entry'));
        expect(tester.getSize(entry).height, lessThan(90));
        expect(find.textContaining('同事099'), findsNothing);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('calendar-attendee-search')),
          '099',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('calendar-attendee-person-99')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('calendar-attendee-person-98')),
          findsNothing,
        );
        await tester.tap(
          find.byKey(const ValueKey('calendar-attendee-person-99')),
        );
        await tester.tap(
          find.byKey(const ValueKey('calendar-attendee-confirm')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('同事099 · Agent'), findsOneWidget);
        expect(tester.getSize(entry).height, lessThan(100));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(state.created, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'participant picker rejects stale identity callbacks and hides old member data',
    (tester) async {
      final state = CalendarFixture();
      final key = await mountCalendar(tester, state);
      await openEditor(tester, key);
      await tester.tap(find.byKey(const ValueKey('calendar-attendee-entry')));
      await tester.pumpAndSettle();
      final confirm = tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('calendar-attendee-confirm')),
          )
          .onPressed!;
      state.generation++;
      confirm();
      state.changed();
      await tester.pumpAndSettle();
      expect(find.text('参与者选择已过期'), findsOneWidget);
      expect(find.text('日程 Agent · Agent'), findsNothing);
      expect(state.created, isEmpty);
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      expect(find.text('日程草稿已过期'), findsOneWidget);
    },
  );
  testWidgets(
    'desktop draft preview has a separate read-only real timeline and never saves on cancellation',
    (tester) async {
      final state = CalendarFixture();
      final key = await mountCalendar(tester, state);
      await openEditor(tester, key);
      final now = DateTime.now();
      final preview = find.byKey(
        const ValueKey('calendar-draft-timeline-scroll'),
      );
      expect(preview, findsOneWidget);
      expect(
        find.byKey(ValueKey('calendar-preview-event-early-${now.day}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('calendar-preview-event-normal-${now.day}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('calendar-preview-event-draft-preview-${now.day}')),
        findsOneWidget,
      );
      final source = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('calendar-timeline-scroll')),
          )
          .controller;
      final draft = tester.widget<SingleChildScrollView>(preview).controller;
      expect(identical(source, draft), isFalse);
      final slot = tester.widget<InkWell>(
        find.byKey(
          ValueKey(
            'calendar-preview-slot-${now.year}-${now.month}-${now.day}-13',
          ),
        ),
      );
      expect(slot.onTap, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('calendar-event-title')),
        '预览草稿',
      );
      await tester.pumpAndSettle();
      expect(find.text('草稿 · 预览草稿'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.created, isEmpty);
      expect(state.updated, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  for (final keyboardHeight in [0.0, 180.0]) {
    testWidgets(
      '100-person picker at 320 x 420 / 130% remains usable with keyboard $keyboardHeight',
      (tester) async {
        final state = CalendarFixture();
        final people = List<Json>.generate(
          100,
          (i) => i == 0
              ? state.me!
              : {
                  'id': 'person-$i',
                  'name': '同事${i.toString().padLeft(3, '0')}',
                  'kind': i.isOdd ? 'agent' : 'human',
                },
        );
        state.principals = people;
        state.libraryRooms = state.rooms
            .map((r) => {...r, 'members': people})
            .toList();
        state.detail = {'room': state.rooms.first, 'members': people};
        final key = await mountCalendar(
          tester,
          state,
          width: 320,
          height: 420,
          scale: 1.3,
        );
        await openEditor(tester, key);
        await tester.ensureVisible(
          find.byKey(const ValueKey('calendar-attendee-entry')),
        );
        await tester.tap(find.byKey(const ValueKey('calendar-attendee-entry')));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final confirm = find.byKey(const ValueKey('calendar-attendee-confirm'));
        expect(
          tester.getRect(confirm).bottom,
          lessThanOrEqualTo(420 - keyboardHeight),
        );
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(find.text('选择参与者'), findsNothing);
        expect(state.created, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final use24 in [true, false]) {
    testWidgets(
      'non-today ordinary and draft cards show a time range respecting ${use24 ? '24' : '12'}-hour settings',
      (tester) async {
        final state = CalendarFixture();
        final now = DateTime.now();
        final other = DateTime(
          now.year,
          now.month,
          now.day + (now.weekday % 7 == 0 ? 1 : -(now.weekday % 7)),
        );
        final event = {
          ...state.calendarEvents.first,
          'id': 'other-day',
          'starts_at': DateTime(
            other.year,
            other.month,
            other.day,
            20,
          ).toUtc().toIso8601String(),
          'ends_at': DateTime(
            other.year,
            other.month,
            other.day,
            21,
          ).toUtc().toIso8601String(),
        };
        state.calendarEvents = [event];
        final key = await mountCalendar(tester, state, use24: use24);
        final expected = use24 ? '20:00 – 21:00' : '下午 8:00 – 下午 9:00';
        final card = find.byKey(
          ValueKey('calendar-event-other-day-${other.day}'),
        );
        expect(
          find.descendant(of: card, matching: find.text(expected)),
          findsOneWidget,
        );
        unawaited(key.currentState!.openEvent(event));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑日程'));
        await tester.pumpAndSettle();
        final draft = find.byKey(
          ValueKey('calendar-preview-event-draft-preview-${other.day}'),
        );
        expect(
          find.descendant(of: draft, matching: find.text(expected)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: draft,
            matching: find.text(
              '${other.month}/${other.day} – ${other.month}/${other.day}',
            ),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'mobile editor white surface covers status and home areas while content respects safe padding',
    (tester) async {
      final state = CalendarFixture();
      final key = await mountCalendar(
        tester,
        state,
        width: 402,
        height: 800,
        safePadding: const EdgeInsets.only(top: 44, bottom: 34),
      );
      await openEditor(tester, key);
      final dialog = find.byType(Dialog);
      final material = find
          .descendant(of: dialog, matching: find.byType(Material))
          .first;
      expect(tester.getRect(material).top, 0);
      expect(tester.getRect(material).bottom, 800);
      expect(tester.widget<Dialog>(dialog).backgroundColor, Colors.white);
      final safe = find.descendant(of: dialog, matching: find.byType(SafeArea));
      final content = find
          .descendant(of: safe, matching: find.byType(Column))
          .first;
      expect(tester.getRect(content).top, 44);
      expect(tester.getRect(content).bottom, 766);
      expect(
        tester.getRect(find.widgetWithText(TextButton, '取消')).top,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
