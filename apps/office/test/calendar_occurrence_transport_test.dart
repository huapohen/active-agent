import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _CalendarTransportState extends OfficeState {
  _CalendarTransportState({required super.client});
  bool failRefresh = false;
  @override
  Future<void> refresh() async {
    if (failRefresh) {
      throw StateError('Synthetic unrelated library refresh failure');
    }
  }

  @override
  Future<void> refreshBusiness() async {}
}

http.Response _json(Json value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Future<_CalendarTransportState> _state(
  Future<http.Response> Function(http.Request) handle,
) async {
  final presence = Completer<http.Response>();
  final state = _CalendarTransportState(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/presence')) return presence.future;
      if (request.url.path.endsWith('/me')) {
        return _json({
          'principal': {'id': 'human-calendar'},
        });
      }
      return handle(request);
    }),
  );
  addTearDown(() {
    state.dispose();
    if (!presence.isCompleted) presence.complete(_json({}, 403));
  });
  await state.connect('https://office.example', 'synthetic-calendar-token');
  return state;
}

final _from = DateTime.utc(2026, 9, 1), _to = DateTime.utc(2026, 10, 1);
Json _occurrence(String id, [String title = '人和 Agent 周会']) => {
  'id': 'calendar-series',
  'event_id': 'calendar-series',
  'occurrence_id': id,
  'base_revision': 7,
  'title': title,
};

void main() {
  test('late detail cannot restore masters after same-identity calendar policy revocation', () async {
    final detail = Completer<http.Response>();
    final state = await _state(
      (request) async => request.url.path.endsWith('/occurrences')
          ? _json({
              'error': 'denied',
              'code': 'app_policy_denied',
              'plugin_id': 'calendar',
            }, 403)
          : detail.future,
    );
    final reading = state.calendarEventDetail('calendar-series');
    final rejected = expectLater(reading, throwsA(isA<OfficeException>()));
    await state.loadCalendarOccurrences(from: _from, to: _to);
    detail.complete(
      _json({
        'event': {
          'id': 'calendar-series',
          'room_id': 'room-company',
          'revision': 1,
        },
      }),
    );
    await rejected;
    expect(state.calendarEvents, isEmpty);
    expect(state.calendarViewEvents, isEmpty);
    expect(state.moduleAvailable('calendar'), isFalse);
  });

  test(
    'late detail cannot restore an event after leaving its known room',
    () async {
      final detail = Completer<http.Response>();
      final state = await _state((_) => detail.future);
      state.rooms = [
        {'id': 'room-company'},
      ];
      final reading = state.calendarEventDetail('calendar-series');
      final rejected = expectLater(reading, throwsA(isA<OfficeException>()));
      state.rooms = [];
      detail.complete(
        _json({
          'event': {
            'id': 'calendar-series',
            'room_id': 'room-company',
            'revision': 1,
          },
        }),
      );
      await rejected;
      expect(state.calendarViewEvents, isEmpty);
    },
  );

  test('successful creation recovers calendar when unrelated refresh fails with an old read pending', () async {
    final old = Completer<http.Response>();
    var reads = 0, writes = 0;
    final state = await _state((request) async {
      if (request.method == 'POST') {
        writes++;
        return _json({
          'event': {'id': 'calendar-created'},
        });
      }
      reads++;
      return reads == 1
          ? old.future
          : _json({
              'occurrences': [_occurrence('created')],
            });
    });
    final reading = state.loadCalendarOccurrences(from: _from, to: _to);
    state.failRefresh = true;
    final created = await state.createCalendarEvent(
      roomId: 'room-company',
      title: '写入已确认',
      allDay: true,
      startDate: '2026-09-08',
      endDate: '2026-09-09',
      timezone: 'Asia/Shanghai',
    );
    expect(created['id'], 'calendar-created');
    expect(writes, 1);
    expect(reads, 2);
    expect(state.calendarOccurrencesLoading, isFalse);
    expect(state.calendarViewEvents.single['occurrence_id'], 'created');
    old.complete(
      _json({
        'occurrences': [_occurrence('old')],
      }),
    );
    await reading;
    expect(state.calendarViewEvents.single['occurrence_id'], 'created');
  });

  test(
    'visible window is encoded and pagination keeps distinct series instances',
    () async {
      final requests = <http.Request>[];
      final state = await _state((request) async {
        requests.add(request);
        return request.url.queryParameters.containsKey('cursor')
            ? _json({
                'occurrences': [
                  _occurrence('second', '已更新'),
                  _occurrence('third'),
                ],
                'truncated': false,
                'next_cursor': null,
              })
            : _json({
                'occurrences': [_occurrence('first'), _occurrence('second')],
                'truncated': true,
                'next_cursor': 'page + / =',
              });
      });
      state.calendarEvents = [
        {
          'id': 'calendar-series',
          'recurrence': {'frequency': 'weekly'},
        },
      ];
      await state.loadCalendarOccurrences(
        from: _from,
        to: _to,
        timezone: 'America/New_York',
      );
      expect(requests.single.url.queryParameters, {
        'from': _from.toIso8601String(),
        'to': _to.toIso8601String(),
        'timezone': 'America/New_York',
        'limit': '500',
      });
      expect(state.calendarOccurrencesTruncated, isTrue);
      await state.loadCalendarOccurrences(
        from: _from,
        to: _to,
        timezone: 'America/New_York',
        append: true,
      );
      expect(requests.last.url.queryParameters['cursor'], 'page + / =');
      expect(state.calendarViewEvents.map((e) => e['occurrence_id']), [
        'first',
        'second',
        'third',
      ]);
      expect(state.calendarViewEvents[1]['title'], '已更新');
      expect(state.calendarEvents, hasLength(1));
      expect(state.calendarNextCursor, isNull);
    },
  );

  test(
    'late response from previous month cannot overwrite the current month',
    () async {
      final old = Completer<http.Response>();
      final state = await _state(
        (request) async =>
            request.url.queryParameters['from'] == _from.toIso8601String()
            ? old.future
            : _json({
                'occurrences': [_occurrence('october')],
              }),
      );
      final first = state.loadCalendarOccurrences(from: _from, to: _to);
      await state.loadCalendarOccurrences(
        from: _to,
        to: DateTime.utc(2026, 11, 1),
      );
      old.complete(
        _json({
          'occurrences': [_occurrence('september')],
        }),
      );
      await first;
      expect(state.calendarViewEvents.single['occurrence_id'], 'october');
      expect(state.calendarOccurrencesLoading, isFalse);
    },
  );

  test(
    'old identity response cannot restore calendar after disconnect',
    () async {
      final old = Completer<http.Response>();
      final state = await _state((_) => old.future);
      final reading = state.loadCalendarOccurrences(from: _from, to: _to);
      state.disconnect();
      old.complete(
        _json({
          'occurrences': [_occurrence('private-old')],
        }),
      );
      await reading;
      expect(state.calendarOccurrences, isNull);
      expect(state.calendarViewEvents, isEmpty);
    },
  );

  test('policy revocation clears masters, occurrences and cursor', () async {
    var revoked = false;
    final state = await _state(
      (_) async => revoked
          ? _json({
              'error': 'denied',
              'code': 'app_policy_denied',
              'plugin_id': 'calendar',
            }, 403)
          : _json({
              'occurrences': [_occurrence('private')],
              'truncated': true,
              'next_cursor': 'next',
            }),
    );
    state.calendarEvents = [
      {'id': 'calendar-series'},
    ];
    await state.loadCalendarOccurrences(from: _from, to: _to);
    revoked = true;
    await state.loadCalendarOccurrences(from: _from, to: _to, force: true);
    expect(state.calendarViewEvents, isEmpty);
    expect(state.calendarNextCursor, isNull);
    expect(state.moduleAvailable('calendar'), isFalse);
    expect(state.calendarOccurrencesLoading, isFalse);
  });

  test(
    'missing instance identities and repeated cursors surface errors',
    () async {
      var malformed = true;
      final state = await _state(
        (request) async => malformed
            ? _json({
                'occurrences': [
                  {'id': 'calendar-series'},
                ],
              })
            : _json({
                'occurrences': [_occurrence('first')],
                'next_cursor': 'same',
                'truncated': true,
              }),
      );
      await state.loadCalendarOccurrences(from: _from, to: _to);
      expect(state.calendarOccurrencesError, contains('稳定标识'));
      malformed = false;
      await state.loadCalendarOccurrences(from: _from, to: _to, force: true);
      await state.loadCalendarOccurrences(from: _from, to: _to, append: true);
      expect(state.calendarOccurrencesError, contains('分页状态无效'));
      expect(state.calendarNextCursor, isNull);
    },
  );

  test('window range bounds reject before sending a request', () async {
    var sent = 0;
    final state = await _state((_) async {
      sent++;
      return _json({});
    });
    await expectLater(
      state.loadCalendarOccurrences(from: _from, to: _from),
      throwsA(isA<OfficeException>()),
    );
    await expectLater(
      state.loadCalendarOccurrences(
        from: _from,
        to: _from.add(const Duration(days: 367)),
      ),
      throwsA(isA<OfficeException>()),
    );
    expect(sent, 0);
  });

  test('all-day create carries exclusive dates and recurrence without fabricated times', () async {
    late http.Request sent;
    final state = await _state((request) async {
      sent = request;
      return _json({
        'event': {'id': 'calendar-new'},
      });
    });
    final recurrence = {
      'frequency': 'weekly',
      'interval': 2,
      'weekdays': [1, 5],
    };
    await state.createCalendarEvent(
      roomId: 'room-company',
      title: '共同休息日',
      allDay: true,
      timezone: 'Asia/Shanghai',
      startDate: '2026-09-08',
      endDate: '2026-09-10',
      recurrence: recurrence,
      attendeeIds: ['human-calendar', 'agent-calendar'],
    );
    final body = jsonDecode(sent.body) as Map;
    expect(body['all_day'], true);
    expect(body['end_date'], '2026-09-10');
    expect(body['recurrence'], recurrence);
    expect(body.containsKey('starts_at'), isFalse);
    expect(body['client_id'], isNotEmpty);
  });

  test(
    'uncertain occurrence edit retries same intent id and CAS version',
    () async {
      final attempts = <Json>[];
      final state = await _state((request) async {
        attempts.add(Json.from(jsonDecode(request.body)));
        if (attempts.length == 1) return _json({'error': 'unavailable'}, 503);
        return _json({'event': _occurrence('first')});
      });
      final event = _occurrence('first');
      Future<void> update() => state.updateCalendarEvent(
        event,
        {'title': '单次改名'},
        scope: 'occurrence',
        occurrenceId: 'first',
      );
      await expectLater(update(), throwsA(isA<OfficeException>()));
      await update();
      expect(attempts[0], attempts[1]);
      expect(attempts[1]['base_revision'], 7);
      expect(attempts[1]['scope'], 'occurrence');
      expect(attempts[1]['occurrence_id'], 'first');
      await update();
      expect(attempts[2]['client_id'], isNot(attempts[1]['client_id']));
    },
  );

  test(
    'cancel and RSVP send explicit occurrence scope and master revision',
    () async {
      final requests = <http.Request>[];
      final state = await _state((request) async {
        requests.add(request);
        return _json({'event': _occurrence('first')});
      });
      final event = _occurrence('first');
      await state.cancelCalendarEvent(
        event,
        scope: 'occurrence',
        occurrenceId: 'first',
      );
      await state.respondCalendarEvent(
        'calendar-series',
        'accepted',
        event: event,
        scope: 'series',
      );
      expect(requests[0].method, 'DELETE');
      expect(jsonDecode(requests[0].body), containsPair('base_revision', 7));
      expect(
        jsonDecode(requests[0].body),
        containsPair('occurrence_id', 'first'),
      );
      expect(requests[1].url.path, endsWith('/respond'));
      expect(jsonDecode(requests[1].body), containsPair('scope', 'series'));
      expect(jsonDecode(requests[1].body), isNot(contains('principal_id')));
    },
  );

  test('single occurrence detail encodes original anchor verbatim', () async {
    late http.Request request;
    final state = await _state((value) async {
      request = value;
      return _json({'event': _occurrence('original')});
    });
    final result = await state.calendarEventDetail(
      'calendar-series',
      occurrenceId: 'original:2026-11-01T01:30+01:00',
    );
    expect(
      request.url.queryParameters['occurrence_id'],
      'original:2026-11-01T01:30+01:00',
    );
    expect(result['occurrence_id'], 'original');
  });
}
