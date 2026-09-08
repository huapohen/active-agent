import 'dart:async';

import 'package:active_office/ui/calendar_schedule.dart';
import 'package:active_office/ui/calendar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'calendar_fidelity_test.dart' show CalendarFixture, mountCalendar;

class LeavingRangeFixture extends CalendarFixture {
  @override
  Future<void> updateCalendarEvent(
    Map<String, dynamic> event,
    Map<String, dynamic> changes, {
    String? scope,
    String? occurrenceId,
    bool resetExceptions = false,
  }) async {
    await super.updateCalendarEvent(
      event,
      changes,
      scope: scope,
      occurrenceId: occurrenceId,
      resetExceptions: resetExceptions,
    );
    calendarOccurrences = [];
    changed();
  }
}

class SlowCancelFixture extends CalendarFixture {
  final cancellation = Completer<void>();
  @override
  Future<void> cancelCalendarEvent(
    Map<String, dynamic> event, {
    required String scope,
    String? occurrenceId,
  }) async {
    await cancellation.future;
    await super.cancelCalendarEvent(
      event,
      scope: scope,
      occurrenceId: occurrenceId,
    );
  }
}

class SlowSeriesFixture extends CalendarFixture {
  final seriesRead = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> calendarEventDetail(
    String id, {
    String? occurrenceId,
  }) => seriesRead.future;
}

class CancelRefreshFixture extends CalendarFixture {
  final finish = Completer<void>();
  @override
  Future<void> cancelCalendarEvent(
    Map<String, dynamic> event, {
    required String scope,
    String? occurrenceId,
  }) async {
    calendarEvents.removeWhere((e) => e['id'] == event['id']);
    calendarOccurrences = [];
    changed();
    await finish.future;
  }
}

Future<BuildContext> host(
  WidgetTester tester, {
  double width = 320,
  double height = 700,
  double scale = 1.3,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          padding: const EdgeInsets.only(top: 44, bottom: 34),
          alwaysUse24HourFormat: true,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (value) {
          context = value;
          return const Scaffold(body: Text('宿主页'));
        },
      ),
    ),
  );
  return context;
}

void main() {
  test(
    'all-day date fields use an exclusive civil end across leap day and DST',
    () {
      final value = CalendarSchedule(
        start: DateTime(2024, 2, 28),
        end: DateTime(2024, 3, 2),
        allDay: true,
        timezone: 'America/New_York',
      );
      expect(value.toFields(), {
        'all_day': true,
        'timezone': 'America/New_York',
        'start_date': '2024-02-28',
        'end_date': '2024-03-02',
      });
      expect(calendarAllDayLabel(value.toFields()), contains('2024年3月1日'));
      expect(value.toFields().containsKey('starts_at'), isFalse);
    },
  );
  test(
    'wall clock precision and historical fractional offsets are preserved',
    () {
      final value = DateTime(2026, 9, 8, 9, 12, 33, 456, 789);
      expect(
        calendarWallTime(
          calendarInstant(value, 'Asia/Shanghai'),
          'Asia/Shanghai',
        ),
        value,
      );
      expect(
        calendarWallTime(
          calendarInstant(value, 'Asia/Kathmandu'),
          'Asia/Kathmandu',
        ),
        value,
      );
    },
  );
  test('IANA conversion refuses a DST gap and selects earlier ambiguous occurrence', () {
    expect(
      () => calendarInstant(DateTime(2026, 3, 8, 2, 30), 'America/New_York'),
      throwsFormatException,
    );
    expect(
      calendarInstant(DateTime(2026, 11, 1, 1, 30), 'America/New_York'),
      DateTime.utc(2026, 11, 1, 5, 30),
    );
    expect(
      calendarInstant(DateTime(2026, 9, 8, 9), 'Asia/Shanghai'),
      DateTime.utc(2026, 9, 8, 1),
    );
    expect(
      calendarWallTime(DateTime.utc(2026, 9, 8, 1), 'Asia/Shanghai'),
      DateTime(2026, 9, 8, 9),
    );
  });
  for (final height in [420.0, 700.0]) {
    testWidgets(
      'mobile time page at 320 x $height / 130% has real date wheels and cancel discards all-day draft',
      (tester) async {
        final context = await host(tester, height: height);
        final identity = ChangeNotifier();
        addTearDown(identity.dispose);
        final future = showCalendarTimePage(
          context,
          schedule: CalendarSchedule(
            start: DateTime(2026, 9, 8, 9),
            end: DateTime(2026, 9, 8, 10),
          ),
          valid: () => true,
          identity: identity,
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
              .mode,
          CupertinoDatePickerMode.dateAndTime,
        );
        await tester.tap(find.byKey(const ValueKey('calendar-time-all-day')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
              .mode,
          CupertinoDatePickerMode.date,
        );
        expect(find.text('9月8日'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('返回日程'));
        await tester.pumpAndSettle();
        expect(await future, isNull);
      },
    );
  }
  testWidgets(
    'time page completes one inclusive selected date as next-day exclusive API end',
    (tester) async {
      final context = await host(tester);
      final identity = ChangeNotifier();
      addTearDown(identity.dispose);
      final future = showCalendarTimePage(
        context,
        schedule: CalendarSchedule(
          start: DateTime(2026, 9, 8, 9),
          end: DateTime(2026, 9, 8, 10),
        ),
        valid: () => true,
        identity: identity,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-time-all-day')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      final value = (await future)!;
      expect(value.toFields()['start_date'], '2026-09-08');
      expect(value.toFields()['end_date'], '2026-09-09');
    },
  );
  testWidgets(
    'captured complete callback cannot export a schedule after identity changes',
    (tester) async {
      final context = await host(tester);
      final identity = ChangeNotifier();
      addTearDown(identity.dispose);
      var valid = true;
      final future = showCalendarTimePage(
        context,
        schedule: CalendarSchedule(
          start: DateTime(2026, 9, 8, 9),
          end: DateTime(2026, 9, 8, 10),
        ),
        valid: () => valid,
        identity: identity,
      );
      await tester.pumpAndSettle();
      final complete = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '完成'))
          .onPressed!;
      valid = false;
      identity.notifyListeners();
      complete();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDatePicker), findsNothing);
      expect(find.textContaining('身份或日程权限已改变'), findsOneWidget);
      await tester.tap(find.byTooltip('返回日程'));
      await tester.pumpAndSettle();
      expect(await future, isNull);
    },
  );
  testWidgets(
    'repeat custom mobile uses real frequency wheels and weekend selector without saving on parent cancel',
    (tester) async {
      final context = await host(tester);
      final identity = ChangeNotifier();
      addTearDown(identity.dispose);
      final future = showCalendarRepeatPicker(
        context,
        start: DateTime(2026, 9, 8),
        current: null,
        valid: () => true,
        identity: identity,
      );
      await tester.pumpAndSettle();
      expect(find.text('选择重复'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('calendar-repeat-custom')));
      await tester.pumpAndSettle();
      tester
          .widget<CupertinoPicker>(
            find.byKey(const ValueKey('calendar-repeat-frequency-wheel')),
          )
          .onSelectedItemChanged!(1);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('calendar-repeat-week-cell-8')),
      );
      await tester.tap(
        find.byKey(const ValueKey('calendar-repeat-week-cell-8')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect((await future)!.rule, {
        'frequency': 'weekly',
        'interval': 1,
        'weekdays': [6, 7],
      });
    },
  );
  testWidgets(
    'mobile monthly date and ordinal tabs represent the actual mutually exclusive contract',
    (tester) async {
      final context = await host(tester);
      final identity = ChangeNotifier();
      addTearDown(identity.dispose);
      final future = showCalendarRepeatPicker(
        context,
        start: DateTime(2026, 9, 8),
        current: {'frequency': 'monthly', 'interval': 1, 'month_day': 8},
        valid: () => true,
        identity: identity,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-repeat-custom')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('星期'));
      await tester.tap(find.text('星期'));
      await tester.pumpAndSettle();
      tester
          .widget<CupertinoPicker>(
            find.byKey(const ValueKey('calendar-repeat-ordinal-wheel')),
          )
          .onSelectedItemChanged!(5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      final rule = (await future)!.rule!;
      expect(rule['ordinal_weekday'], {'ordinal': -1, 'weekday': 2});
      expect(rule.containsKey('month_day'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'all-day occurrences occupy their band and never enter hourly positioning',
    (tester) async {
      final state = CalendarFixture();
      final now = DateTime.now();
      final event =
          {
              ...state.calendarEvents.first,
              'all_day': true,
              'start_date': calendarDate(now),
              'end_date': calendarDate(calendarDay(now, 2)),
              'timezone': 'Asia/Shanghai',
              'occurrence_id': 'occ-all',
              'recurrence': {'frequency': 'daily', 'interval': 1},
            }
            ..remove('starts_at')
            ..remove('ends_at');
      state.calendarEvents = [event];
      state.calendarOccurrences = [event];
      await mountCalendar(tester, state, width: 320, scale: 1.3);
      expect(
        find.byKey(const ValueKey('calendar-all-day-band')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('calendar-all-day-occ-all-${now.day}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('calendar-event-occ-all-${now.day}')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'occurrence cancellation asks scope and confirmation and sends one real operation',
    (tester) async {
      final state = CalendarFixture();
      final master = state.calendarEvents.first;
      master['recurrence'] = {
        'frequency': 'weekly',
        'interval': 1,
        'weekdays': [DateTime.now().weekday],
      };
      final event = {...master, 'occurrence_id': 'occ-1', 'base_revision': 1};
      state.calendarOccurrences = [event];
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(event));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消日程'));
      await tester.pumpAndSettle();
      expect(find.text('此及以后'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('calendar-scope-occurrence')));
      await tester.pumpAndSettle();
      expect(state.cancellations, isEmpty);
      await tester.tap(find.text('确认取消'));
      await tester.pumpAndSettle();
      expect(state.cancellations, [
        {'id': 'early', 'scope': 'occurrence', 'occurrence_id': 'occ-1'},
      ]);
    },
  );
  testWidgets(
    'occurrence editor preserves instance id and excludes series recurrence changes',
    (tester) async {
      final state = CalendarFixture();
      final master = state.calendarEvents.first;
      master['recurrence'] = {'frequency': 'daily', 'interval': 1};
      final event = {
        ...master,
        'occurrence_id': 'occ-edit',
        'base_revision': 1,
      };
      state.calendarOccurrences = [event];
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(event));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-scope-occurrence')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('calendar-event-title')),
        '只改本次',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(state.updated.single['scope'], 'occurrence');
      expect(state.updated.single['occurrence_id'], 'occ-edit');
      expect(state.updated.single.containsKey('recurrence'), isFalse);
    },
  );
  testWidgets(
    'identity switch during scope selection cannot mutate or expose previous event draft',
    (tester) async {
      final state = CalendarFixture();
      final master = state.calendarEvents.first;
      master['recurrence'] = {'frequency': 'daily', 'interval': 1};
      final event = {...master, 'occurrence_id': 'occ-old'};
      state.calendarOccurrences = [event];
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(event));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      final action = tester
          .widget<ListTile>(
            find.byKey(const ValueKey('calendar-scope-occurrence')),
          )
          .onTap!;
      state.generation++;
      state.changed();
      action();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-event-title')), findsNothing);
      expect(state.updated, isEmpty);
      expect(find.text('仅本次日程'), findsNothing);
    },
  );
  testWidgets(
    'moving an occurrence outside the loaded range closes the successful editor',
    (tester) async {
      final state = LeavingRangeFixture();
      final master = state.calendarEvents.first;
      master['recurrence'] = {'frequency': 'daily', 'interval': 1};
      final now = DateTime.now();
      final event = {...master, 'occurrence_id': 'move-away'};
      state.calendarOccurrences = [event];
      final key = await mountCalendar(tester, state, width: 402, use24: true);
      unawaited(key.currentState!.openEvent(event));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-scope-occurrence')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-start-time-entry')));
      await tester.pumpAndSettle();
      tester
          .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
          .onDateTimeChanged(DateTime(now.year, now.month + 1, now.day, 9));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(state.updated, hasLength(1));
      expect(find.text('日程草稿已过期'), findsNothing);
      expect(find.byKey(const ValueKey('calendar-event-title')), findsNothing);
    },
  );
  testWidgets(
    'range errors remain visible and retry and pagination issue real range requests',
    (tester) async {
      final state = CalendarFixture();
      await mountCalendar(tester, state, width: 402);
      expect(state.rangeLoads.single['timezone'], 'Asia/Shanghai');
      state.calendarOccurrencesError = 'network unavailable';
      state.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(state.rangeLoads.last['force'], isTrue);
      state.calendarOccurrencesError = null;
      state.calendarNextCursor = 'real-cursor';
      state.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多日程'));
      await tester.pumpAndSettle();
      expect(state.rangeLoads.last['append'], isTrue);
    },
  );
  testWidgets(
    'mobile repeat cutoff is a separate page and exclusive end conditions replace one another',
    (tester) async {
      final context = await host(tester, height: 420);
      final identity = ChangeNotifier();
      addTearDown(identity.dispose);
      final future = showCalendarRepeatEndPage(
        context,
        start: DateTime(2026, 9, 8),
        rule: {
          'frequency': 'weekly',
          'interval': 2,
          'weekdays': [2],
        },
        valid: () => true,
        identity: identity,
      );
      await tester.pumpAndSettle();
      expect(find.text('选择截止时间'), findsOneWidget);
      expect(find.byType(CupertinoDatePicker), findsNothing);
      await tester.tap(find.byKey(const ValueKey('calendar-repeat-never-end')));
      await tester.pumpAndSettle();
      tester
          .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
          .onDateTimeChanged(DateTime(2026, 10, 12));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      final rule = (await future)!.rule!;
      expect(rule, {
        'frequency': 'weekly',
        'interval': 2,
        'weekdays': [2],
        'until_date': '2026-10-12',
      });
      expect(tester.takeException(), isNull);
      final canceled = showCalendarRepeatEndPage(
        context,
        start: DateTime(2026, 9, 8),
        rule: rule,
        valid: () => true,
        identity: identity,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await canceled, isNull);
    },
  );
  testWidgets(
    'series master exceptions map offers explicit reset even without exception_count',
    (tester) async {
      final state = CalendarFixture();
      final master = state.calendarEvents.first;
      master['recurrence'] = {'frequency': 'daily', 'interval': 1};
      master['exceptions'] = {
        '2026-09-08': {'title': '单次调整'},
      };
      final event = {
        ...master,
        'occurrence_id': 'exception-instance',
        'base_revision': 1,
      }..remove('exceptions');
      state.calendarOccurrences = [event];
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(event));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-scope-series')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重设已单独修改的日程'));
      await tester.tap(find.text('重设已单独修改的日程'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(state.updated.single['reset_exceptions'], isTrue);
    },
  );
  testWidgets(
    'meeting-linked calendar retains timed editing and disables unsupported series modes',
    (tester) async {
      final state = CalendarFixture();
      final event = state.calendarEvents.first;
      event['meeting_id'] = 'linked-meeting';
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(event));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消日程'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('calendar-all-day')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('calendar-repeat-entry')),
            )
            .onTap,
        isNull,
      );
      expect(state.updated, isEmpty);
    },
  );
  testWidgets(
    'title-only edit preserves the later original DST overlap instant',
    (tester) async {
      final state = CalendarFixture();
      final event = state.calendarEvents.first;
      event.addAll({
        'timezone': 'America/New_York',
        'starts_at': '2026-11-01T06:30:33.456Z',
        'ends_at': '2026-11-01T07:30:33.456Z',
      });
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(event));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('calendar-event-title')),
        '只编辑标题',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(state.updated.single['starts_at'], '2026-11-01T06:30:33.456Z');
      expect(state.updated.single['ends_at'], '2026-11-01T07:30:33.456Z');
    },
  );
  for (final width in [320.0, 1100.0]) {
    testWidgets(
      'native interval 999 and count 10000 remain editable without giant menus at $width',
      (tester) async {
        final context = await host(tester, width: width);
        final identity = ChangeNotifier();
        addTearDown(identity.dispose);
        final future = showCalendarRepeatPicker(
          context,
          start: DateTime(2026, 9, 8),
          current: {'frequency': 'daily', 'interval': 999, 'count': 10000},
          valid: () => true,
          identity: identity,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('calendar-repeat-custom')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(width < 700 ? '完成' : '确定'));
        await tester.pumpAndSettle();
        expect((await future)!.rule, {
          'frequency': 'daily',
          'interval': 999,
          'count': 10000,
        });
      },
    );
  }
  testWidgets(
    'stored far-future time and cutoff stay readable and cancellable',
    (tester) async {
      final context = await host(tester);
      final identity = ChangeNotifier();
      addTearDown(identity.dispose);
      final future = showCalendarTimePage(
        context,
        schedule: CalendarSchedule(
          start: DateTime(2045, 6, 20),
          end: DateTime(2045, 6, 21),
          allDay: true,
        ),
        valid: () => true,
        identity: identity,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('返回日程'));
      await tester.pumpAndSettle();
      expect(await future, isNull);
      final cutoff = showCalendarRepeatEndPage(
        context,
        start: DateTime(2026, 9, 8),
        rule: {'frequency': 'daily', 'interval': 1, 'until_date': '2200-01-01'},
        valid: () => true,
        identity: identity,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await cutoff, isNull);
    },
  );
  testWidgets(
    'late cancellation does not pop the calendar after the detail was closed',
    (tester) async {
      final state = SlowCancelFixture();
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(state.calendarEvents.first));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消日程'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pump(const Duration(milliseconds: 30));
      state.cancellation.complete();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeCalendar), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(state.cancellations, hasLength(1));
    },
  );
  testWidgets(
    'late series read does not open a draft after its detail was closed',
    (tester) async {
      final state = SlowSeriesFixture();
      final master = state.calendarEvents.first;
      master['recurrence'] = {'frequency': 'daily', 'interval': 1};
      final event = {...master, 'occurrence_id': 'slow-series'};
      state.calendarOccurrences = [event];
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(event));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑日程'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-scope-series')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pump(const Duration(milliseconds: 30));
      state.seriesRead.complete(master);
      await tester.pumpAndSettle();
      expect(find.byType(OfficeCalendar), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-event-title')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'confirmed cancellation refresh does not flash an unavailable error',
    (tester) async {
      final state = CancelRefreshFixture();
      final key = await mountCalendar(tester, state);
      unawaited(key.currentState!.openEvent(state.calendarEvents.first));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消日程'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认取消'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('日程已不可用'), findsNothing);
      expect(find.text('正在取消日程…'), findsWidgets);
      state.finish.complete();
      await tester.pumpAndSettle();
      expect(find.text('正在取消日程…'), findsNothing);
      expect(find.byType(OfficeCalendar), findsOneWidget);
    },
  );
  testWidgets('cutoff Cancel stays on one line at 320 / 130%', (tester) async {
    final context = await host(tester);
    final identity = ChangeNotifier();
    addTearDown(identity.dispose);
    final future = showCalendarRepeatEndPage(
      context,
      start: DateTime(2026, 9, 8),
      rule: {'frequency': 'daily', 'interval': 1},
      valid: () => true,
      identity: identity,
    );
    await tester.pumpAndSettle();
    final cancelText = tester.widget<Text>(find.text('取消'));
    expect(cancelText.maxLines, 1);
    expect(tester.getSize(find.text('取消')).height, lessThan(32));
    expect(tester.widget<AppBar>(find.byType(AppBar)).leadingWidth, 80);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await future, isNull);
  });
  testWidgets(
    'mobile title focus is released before time navigation and stays released on return',
    (tester) async {
      final state = CalendarFixture();
      final key = await mountCalendar(tester, state, width: 402);
      unawaited(key.currentState!.createEvent());
      await tester.pumpAndSettle();
      await tester.showKeyboard(
        find.byKey(const ValueKey('calendar-event-title')),
      );
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.byKey(const ValueKey('calendar-start-time-entry')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(
        find.byKey(const ValueKey('calendar-event-title')),
        findsOneWidget,
      );
      expect(state.created, isEmpty);
    },
  );
  testWidgets('desktop repeat preset is compact and anchored below its entry', (
    tester,
  ) async {
    final context = await host(tester, width: 1100, height: 800, scale: 1);
    final identity = ChangeNotifier();
    addTearDown(identity.dispose);
    final future = showCalendarRepeatPicker(
      context,
      start: DateTime(2026, 9, 8),
      current: null,
      valid: () => true,
      identity: identity,
      anchor: const Rect.fromLTWH(120, 120, 240, 40),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final first = find.byKey(const ValueKey('calendar-repeat-preset-0'));
    expect(tester.getTopLeft(first).dx, closeTo(120, 1));
    expect(tester.getTopLeft(first).dy, greaterThan(160));
    expect(tester.getSize(first).width, lessThanOrEqualTo(260));
    await tester.tap(find.byKey(const ValueKey('calendar-repeat-preset-1')));
    await tester.pumpAndSettle();
    expect((await future)!.rule, {'frequency': 'daily', 'interval': 1});
  });
}
