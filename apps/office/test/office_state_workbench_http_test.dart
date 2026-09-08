import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:active_office/office_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real loopback HTTP contract server. Its response gates reproduce delayed
/// authenticated requests without timers, MockClient or production credentials.
class WorkbenchHttpService {
  late HttpServer server;
  final states = <OfficeState>[];
  final requests = <({String actor, String method, String path, Json body})>[];
  final recents = <String, List<String>>{};
  final favorites = <String, List<String>>{};
  final denied = <String>{};
  final gates = <ResponseGate>[];
  final shutdown = Completer<void>();
  bool omitRecents = false;
  String get endpoint => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serve(request)));
  }

  Future<OfficeState> connect(String actor) async {
    final state = OfficeState();
    states.add(state);
    await state.connect(endpoint, 'synthetic-$actor');
    return state;
  }

  ResponseGate hold(String actor, String method, String path) {
    final gate = ResponseGate(actor, method, path);
    gates.add(gate);
    return gate;
  }

  Json view(String actor) => {
    'apps': [
      for (final id in ['docs', 'tasks', 'calendar', 'mail'])
        {'id': id, 'name': id, 'route': '/office#$id', 'available': true},
      {'id': 'reports', 'name': 'reports', 'available': false},
    ],
    'favorites': [
      ...favorites[actor] ?? ['docs'],
    ],
    if (!omitRecents) 'recents': [...recents[actor] ?? []],
  };

  Future<void> _serve(HttpRequest request) async {
    try {
      final authorization = request.headers.value('authorization');
      final actor = switch (authorization) {
        'Bearer synthetic-human' => 'human',
        'Bearer synthetic-agent' => 'agent',
        _ => '',
      };
      if (actor.isEmpty) {
        request.response.statusCode = 401;
        request.response.write('{}');
        await request.response.close();
        return;
      }
      final path = request.uri.path.replaceFirst('/api/im', '');
      final content = await utf8.decoder.bind(request).join();
      final body = content.isEmpty
          ? <String, dynamic>{}
          : Json.from(jsonDecode(content));
      requests.add((
        actor: actor,
        method: request.method,
        path: path,
        body: body,
      ));
      Json result;
      var status = 200;
      if (path.startsWith('/workbench')) {
        if (denied.contains(actor)) {
          status = 403;
          result = {'code': 'app_policy_denied', 'plugin_id': 'workbench'};
        } else {
          if (request.method == 'PATCH') {
            favorites[actor] = List<String>.from(body['favorites']);
          }
          if (request.method == 'POST') {
            final id = body['app_id'] as String;
            recents[actor] = <String>{id, ...?recents[actor]}.take(32).toList();
          }
          if (request.method == 'DELETE') recents[actor] = [];
          result = view(actor);
        }
      } else {
        result = switch (path) {
          '/me' => {
            'principal': {'id': actor, 'name': actor, 'kind': actor},
          },
          '/rooms' => {'rooms': [], 'cursor': 1},
          '/principals' => {'principals': []},
          '/agents' || '/agent-store' => {'agents': []},
          '/library' => {'documents': [], 'tasks': [], 'rooms': []},
          '/meetings' => {'meetings': []},
          '/calendar' => {'events': []},
          '/attendance' => {'records': []},
          '/approval-templates' => {'templates': []},
          '/approvals' => {'requests': []},
          '/mail/folders' => {'folders': []},
          '/mail' => {'items': []},
          '/settings' => {
            'settings': {'revision': 1},
          },
          '/auth/account' => {'account': null},
          '/contacts' => {'contacts': []},
          '/enterprise' => {
            'capabilities': {'access_admin': false},
          },
          '/plugins' => {'plugins': []},
          '/capabilities' => {'capabilities': []},
          '/presence' => {
            'presence': {'status': 'online'},
          },
          '/events' => {'events': [], 'cursor': 1},
          _ => {'code': 'unexpected_fixture_route'},
        };
        if (result['code'] != null) status = 404;
      }
      if (path == '/events') await shutdown.future;
      for (final gate in gates) {
        if (!gate.entered.isCompleted &&
            gate.actor == actor &&
            gate.method == request.method &&
            gate.path == path) {
          gate.entered.complete();
          await gate.release.future;
          break;
        }
      }
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    } on HttpException {
      if (!shutdown.isCompleted) rethrow;
    } on SocketException {
      if (!shutdown.isCompleted) rethrow;
    }
  }

  Future<void> close() async {
    for (final state in states) {
      state.disconnect();
      state.dispose();
    }
    shutdown.complete();
    for (final gate in gates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
    await server.close(force: true);
  }
}

class ResponseGate {
  ResponseGate(this.actor, this.method, this.path);
  final String actor, method, path;
  final entered = Completer<void>(), release = Completer<void>();
}

void main() {
  late WorkbenchHttpService service;
  setUp(() async {
    service = WorkbenchHttpService();
    await service.start();
  });
  tearDown(() => service.close());

  test('real HTTP human and agent recents remain personal through refresh, favorites and clearing', () async {
    final human = await service.connect('human');
    final agent = await service.connect('agent');
    expect(human.appRecents, isEmpty);
    expect(agent.appRecents, isEmpty);
    expect(
      service.requests.where(
        (r) => r.method == 'POST' && r.path == '/workbench/recents',
      ),
      isEmpty,
    );
    for (final id in ['docs', 'calendar', 'docs']) {
      await human.recordWorkbenchVisit(id);
    }
    await agent.recordWorkbenchVisit('tasks');
    expect(human.appRecents, ['docs', 'calendar']);
    expect(agent.appRecents, ['tasks']);
    await human.setAppFavorites(['mail']);
    expect(human.appRecents, ['docs', 'calendar']);
    expect(human.appFavorites, ['mail']);
    await human.refreshOffice();
    await agent.refresh();
    expect(human.appRecents, ['docs', 'calendar']);
    expect(agent.appRecents, ['tasks']);
    await human.clearWorkbenchRecents();
    expect(human.appRecents, isEmpty);
    expect(human.appFavorites, ['mail']);
    expect(agent.appRecents, ['tasks']);
    expect(service.recents['agent'], ['tasks']);
    expect(
      service.requests
          .where((r) => r.path == '/workbench/recents')
          .every((r) => !r.body.containsKey('principal_id')),
      isTrue,
    );
  });

  test('a delayed prior identity response and queued intent cannot write into the next identity', () async {
    final state = await service.connect('human');
    final gate = service.hold('human', 'POST', '/workbench/recents');
    final first = expectLater(
      state.recordWorkbenchVisit('docs'),
      throwsA(isA<OfficeException>().having((e) => e.status, 'status', 401)),
    );
    await gate.entered.future;
    final queued = expectLater(
      state.recordWorkbenchVisit('calendar'),
      throwsA(isA<OfficeException>().having((e) => e.status, 'status', 401)),
    );
    await state.connect(service.endpoint, 'synthetic-agent');
    expect(state.appRecents, isEmpty);
    // The new identity has a separate queue and does not wait for the old HTTP response.
    await state.recordWorkbenchVisit('tasks');
    gate.release.complete();
    await Future.wait([first, queued]);
    expect(state.me?['id'], 'agent');
    expect(state.appRecents, ['tasks']);
    expect(service.recents['human'], ['docs']);
    expect(service.recents['agent'], ['tasks']);
    expect(
      service.requests.where((r) => r.body['app_id'] == 'calendar'),
      isEmpty,
    );
  });

  test(
    'A to B to A still rejects the first A generation delayed response',
    () async {
      final state = await service.connect('human');
      final gate = service.hold('human', 'POST', '/workbench/recents');
      final stale = expectLater(
        state.recordWorkbenchVisit('docs'),
        throwsA(isA<OfficeException>()),
      );
      await gate.entered.future;
      await state.connect(service.endpoint, 'synthetic-agent');
      await state.connect(service.endpoint, 'synthetic-human');
      await state.recordWorkbenchVisit('tasks');
      gate.release.complete();
      await stale;
      expect(state.me?['id'], 'human');
      expect(state.appRecents, ['tasks', 'docs']);
    },
  );

  for (final scope in ['all', 'office']) {
    test(
      '$scope refresh started before a visit cannot overwrite its successful recent snapshot',
      () async {
        final state = await service.connect('human');
        final gate = service.hold('human', 'GET', '/workbench');
        final refresh = scope == 'all'
            ? state.refresh()
            : state.refreshOffice();
        await gate.entered.future;
        await state.recordWorkbenchVisit('docs');
        gate.release.complete();
        await refresh;
        expect(state.appRecents, ['docs']);
        expect(service.recents['human'], ['docs']);
      },
    );
  }

  test(
    'later refresh wins over an older response even with no local mutation',
    () async {
      final state = await service.connect('human');
      final gate = service.hold('human', 'GET', '/workbench');
      final stale = state.refreshOffice();
      await gate.entered.future;
      service.recents['human'] = ['mail'];
      await state.refresh();
      gate.release.complete();
      await stale;
      expect(state.appRecents, ['mail']);
    },
  );

  test('workbench mutations follow click order and ignore background snapshots while pending', () async {
    final state = await service.connect('human');
    final gate = service.hold('human', 'POST', '/workbench/recents');
    final first = state.recordWorkbenchVisit('docs');
    await gate.entered.future;
    final second = state.recordWorkbenchVisit('calendar');
    final favorite = state.setAppFavorites(['mail']);
    final readsBefore = service.requests
        .where((r) => r.path == '/workbench' && r.method == 'GET')
        .length;
    await state.refreshOffice();
    expect(
      service.requests.where((r) => r.body['app_id'] == 'calendar'),
      isEmpty,
    );
    expect(
      service.requests
          .where((r) => r.path == '/workbench' && r.method == 'GET')
          .length,
      readsBefore,
    );
    gate.release.complete();
    await Future.wait([first, second, favorite]);
    expect(state.appRecents, ['calendar', 'docs']);
    expect(state.appFavorites, ['mail']);
    expect(
      service.requests
          .where((r) => r.path.startsWith('/workbench') && r.method != 'GET')
          .map((r) => r.method),
      ['POST', 'POST', 'PATCH'],
    );
  });

  test('unknown and unavailable apps are not recorded, and failed writes do not poison later visits', () async {
    final state = await service.connect('human');
    for (final app in ['missing', 'reports']) {
      await expectLater(
        state.recordWorkbenchVisit(app),
        throwsA(isA<OfficeException>()),
      );
    }
    expect(
      service.requests.where((r) => r.path == '/workbench/recents'),
      isEmpty,
    );
    await state.recordWorkbenchVisit('docs');
    expect(state.appRecents, ['docs']);
    service.denied.add('human');
    await expectLater(
      state.recordWorkbenchVisit('mail'),
      throwsA(isA<OfficeException>().having((e) => e.status, 'status', 403)),
    );
    expect(state.appRecents, isEmpty);
    expect(state.appFavorites, isEmpty);
    expect(state.apps, isEmpty);
    service.denied.clear();
    await state.refreshOffice();
    await state.recordWorkbenchVisit('calendar');
    expect(state.appRecents, ['calendar', 'docs']);
  });

  test(
    'older contract omits recents safely and disconnect clears personal usage',
    () async {
      service.omitRecents = true;
      final state = await service.connect('human');
      expect(state.appRecents, isEmpty);
      service.omitRecents = false;
      await state.recordWorkbenchVisit('docs');
      state.disconnect();
      expect(state.appRecents, isEmpty);
      expect(state.appFavorites, isEmpty);
    },
  );
}
