import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:active_office/office_state.dart';

class Service {
  final String kind;
  bool loseFirstSend = false;
  int sends = 0;
  final List<Json> bodies = [];
  Service(this.kind);
  http.Response json(Object value, [int status = 200]) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  Future<http.Response> call(http.Request request) async {
    if (request.headers['authorization'] != 'Bearer private-test-identity') {
      return json({}, 401);
    }
    final path = request.url.path.replaceFirst('/api/im', '');
    if (path == '/presence') {
      return json({
        'presence': {'status': 'online'},
      });
    }
    if (path == '/me') {
      return json({
        'principal': {'id': 'me', 'name': '独立成员', 'kind': kind},
      });
    }
    if (path == '/rooms') {
      return json({
        'rooms': [
          {'id': 'room-1', 'name': '共同办公', 'unread_count': 0},
        ],
        'cursor': 1,
      });
    }
    if (path == '/principals') {
      return json({
        'principals': [
          {'id': 'me', 'kind': kind},
          {'id': 'peer', 'kind': 'human'},
        ],
      });
    }
    if (path == '/agents' || path == '/agent-store') {
      return json({'agents': []});
    }
    if (path == '/meetings') return json({'meetings': []});
    if (path == '/calendar') return json({'events': []});
    if (path == '/workbench') return json({'apps': [], 'favorites': []});
    if (path == '/library') return json({'documents': [], 'tasks': []});
    if (path == '/rooms/room-1') {
      return json({
        'room': {'id': 'room-1'},
        'members': [],
        'messages': [],
        'documents': [],
        'tasks': [],
        'runs': [],
      });
    }
    if (path == '/events') {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return json({'events': [], 'cursor': 1});
    }
    if (path == '/rooms/room-1/messages') {
      sends++;
      bodies.add(Json.from(jsonDecode(request.body)));
      if (loseFirstSend && sends == 1) {
        throw http.ClientException('Simulated lost response');
      }
      return json({
        'message': {
          'id': 'message-1',
          'author_id': 'me',
          'content': bodies.last['content'],
        },
        'duplicate': sends > 1,
      });
    }
    if (path == '/rooms/room-1/documents/doc-1') {
      return json({'code': 'conflict'}, 409);
    }
    return json({}, 404);
  }
}

void main() {
  test('a human and an agent log into the same state and use identical message capabilities', () async {
    for (final kind in ['human', 'agent']) {
      final service = Service(kind);
      // Each instance must have its own authenticated session, irrespective of kind.
      final office = OfficeState(client: MockClient(service.call));
      await office.connect('http://localhost:3218', 'private-test-identity');
      expect(office.me?['kind'], kind);
      expect(office.selectedRoomId, 'room-1');
      final message = await office.send('共同推进', mentions: ['peer']);
      expect(message['author_id'], 'me');
      expect(service.bodies.single['mentions'], ['peer']);
      expect(service.bodies.single.containsKey('author_id'), false);
      office.disconnect();
      office.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 130));
    }
  });
  test(
    'ambiguous send retries reuse one identity and do not duplicate intent',
    () async {
      final service = Service('agent')..loseFirstSend = true;
      final office = OfficeState(client: MockClient(service.call));
      await office.connect('http://localhost', 'private-test-identity');
      await expectLater(
        office.send('Review this', mentions: ['peer']),
        throwsA(isA<OfficeException>()),
      );
      await office.send('Review this', mentions: ['peer']);
      expect(service.bodies[0]['client_id'], service.bodies[1]['client_id']);
      office.disconnect();
      office.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 130));
    },
  );
  test(
    'document revision conflict is surfaced to preserve the editors draft',
    () async {
      final office = OfficeState(client: MockClient(Service('human').call));
      await office.connect('http://localhost', 'private-test-identity');
      await expectLater(
        office.saveDocument(
          id: 'doc-1',
          title: '工作依据',
          content: '本地草稿',
          baseRevision: 1,
        ),
        throwsA(isA<OfficeException>().having((e) => e.status, 'status', 409)),
      );
      office.disconnect();
      office.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 130));
    },
  );
  test(
    'credentials in service URL are rejected before any network call',
    () async {
      final office = OfficeState(
        client: MockClient((_) async => throw StateError('Must not connect')),
      );
      await expectLater(
        office.connect(
          'https://user:password@example.com',
          'private-test-identity',
        ),
        throwsA(isA<OfficeException>()),
      );
      office.dispose();
    },
  );
}
