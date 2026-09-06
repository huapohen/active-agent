import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/mobile_navigation.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class HeldRequest {
  HeldRequest(this.method, this.path);
  final String method, path;
  final started = Completer<http.Request>();
  final result = Completer<http.Response>();
}

/// Only the authenticated settings/account methods are under test. Startup
/// catalogs are omitted while real connect, password login and transport run.
class SettingsTransportOffice extends OfficeState {
  SettingsTransportOffice(SettingsService service)
    : super(client: MockClient(service.call));
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshBusiness() async {
    settings = {'revision': 7, 'marker': endpoint};
    accountInfo = {'username': 'account-${me!['id']}'};
    accountSessions = [
      {'id': 'session-${me!['id']}'},
    ];
  }
}

class SettingsService {
  final calls = <http.Request>[];
  final holds = <HeldRequest>[];
  final events = <Completer<http.Response>>[];
  int revision = 7;
  HeldRequest hold(String method, String path) {
    final held = HeldRequest(method, path);
    holds.add(held);
    return held;
  }

  Future<http.Response> call(http.Request request) async {
    calls.add(request);
    final path = request.url.path.replaceFirst('/api/im', '');
    final held = holds
        .where((h) => h.method == request.method && h.path == path)
        .firstOrNull;
    if (held != null) {
      holds.remove(held);
      held.started.complete(request);
      return held.result.future;
    }
    final id = request.headers['authorization']?.split('-').last ?? 'public';
    if (path == '/me') {
      return response({
        'principal': {
          'id': id,
          'name': 'Fixture $id',
          'kind': id.contains('agent') ? 'agent' : 'human',
        },
      });
    }
    if (path == '/presence' || path == '/auth/logout') return response({});
    if (path == '/events') {
      final pending = Completer<http.Response>();
      events.add(pending);
      return pending.future;
    }
    if (path == '/auth/login') {
      return response({
        'token': 'synthetic-updated',
        'session_id': 'new-session',
      });
    }
    if (path == '/auth/account') {
      return response({
        'account': {'username': 'server-$id'},
      });
    }
    if (path == '/auth/sessions') {
      return response({
        'sessions': [
          {'id': 'server-session-$id'},
        ],
      });
    }
    if (path.startsWith('/auth/sessions/')) return response({'revoked': true});
    if (path == '/settings') {
      if (request.method == 'PATCH') {
        final data = jsonDecode(request.body) as Map;
        if (data['base_revision'] != revision) {
          return response({'code': 'settings_conflict'}, 409);
        }
        revision++;
        return response({
          'settings': {...data, 'revision': revision},
        });
      }
      return response({
        'settings': {
          'revision': revision,
          'mobile_nav': ['messages', 'mail'],
          'show_message_preview': false,
        },
      });
    }
    throw StateError('Unexpected fixture route ${request.method} $path');
  }

  void finish() {
    for (final event in events) {
      if (!event.isCompleted) {
        event.complete(response({'events': [], 'cursor': 0}));
      }
    }
  }
}

Matcher get expired =>
    throwsA(isA<OfficeException>().having((e) => e.status, 'status', 401));

class NavigationIdentityOffice extends OfficeState {
  NavigationIdentityOffice({this.conflict = false}) {
    endpoint = 'https://navigation.example';
    me = {'id': 'self', 'name': 'Fixture member', 'kind': 'human'};
    connected = true;
    settings = {
      'revision': 7,
      'mobile_nav': ['messages', 'agents', 'docs', 'workbench'],
    };
  }
  bool conflict;
  final writes = <Json>[];
  int generation = 0;
  @override
  int get identityGeneration => generation;
  Completer<Json>? delayedRead;
  Completer<void>? delayedSave;
  final readStarted = Completer<void>();
  final saveStarted = Completer<void>();
  void switchIdentity(String id) {
    generation++;
    me = {'id': id, 'name': 'Fixture $id', 'kind': 'agent'};
    settings = {
      'revision': 7,
      'mobile_nav': ['mail', 'calendar'],
    };
    notifyListeners();
  }

  void temporaryOffline() {
    connected = false;
    notifyListeners();
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/settings' && delayedRead != null) {
      readStarted.complete();
      return delayedRead!.future;
    }
    if (path == '/settings') {
      return {
        'settings': {
          'revision': 10,
          'mobile_nav': ['mail', 'calendar'],
        },
      };
    }
    throw StateError('Unexpected navigation fixture request');
  }

  @override
  Future<void> saveSettings(Json changes, {int? baseRevision}) async {
    if (delayedSave != null) {
      writes.add({...changes, 'base_revision': baseRevision});
      saveStarted.complete();
      return delayedSave!.future;
    }
    writes.add({...changes, 'base_revision': baseRevision});
    if (conflict && baseRevision != 10) throw OfficeException(409, '设置版本冲突');
    settings = {...settings, ...changes, 'revision': (baseRevision ?? 7) + 1};
    notifyListeners();
  }
}

Future<void> openNavigation(
  WidgetTester tester,
  NavigationIdentityOffice office,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOfficeNavigationEditor(context, office),
            child: const Text('打开编辑器'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开编辑器'));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    office.dispose();
  });
}

void main() {
  for (final operation in ['account', 'sessions', 'reload', 'save']) {
    test(
      '$operation rejects a late response from the prior identity and endpoint',
      () async {
        final service = SettingsService();
        final office = SettingsTransportOffice(service);
        addTearDown(() {
          office.dispose();
          service.finish();
        });
        await office.connect('https://a.example', 'synthetic-human');
        final held = service.hold(
          operation == 'save' ? 'PATCH' : 'GET',
          switch (operation) {
            'account' => '/auth/account',
            'sessions' => '/auth/sessions',
            _ => '/settings',
          },
        );
        final pending = switch (operation) {
          'account' => office.getAccount(),
          'sessions' => office.loadAccountSessions(),
          'reload' => office.reloadSettings(),
          _ => office.saveSettings({'text_scale': 1.3}),
        };
        final rejected = expectLater(pending, expired);
        await held.started.future;
        await office.connect('https://b.example', 'synthetic-agent');
        held.result.complete(
          response({
            'account': {'username': 'private-old-account'},
            'sessions': [
              {'id': 'private-old-session'},
            ],
            'settings': {'revision': 99, 'marker': 'private-old-setting'},
          }),
        );
        await rejected;
        expect(office.me!['id'], 'agent');
        expect(office.endpoint, 'https://b.example');
        expect(office.accountInfo['username'], 'account-agent');
        expect(office.accountSessions.single['id'], 'session-agent');
        expect(office.settings, {'revision': 7, 'marker': 'https://b.example'});
      },
    );
  }

  test('A to B to A still rejects the original settings response with an equal revision', () async {
    final service = SettingsService();
    final office = SettingsTransportOffice(service);
    addTearDown(() {
      office.dispose();
      service.finish();
    });
    await office.connect('https://a.example', 'synthetic-human');
    final originalGeneration = office.identityGeneration;
    final held = service.hold('PATCH', '/settings');
    final rejected = expectLater(
      office.saveSettings({
        'mobile_nav': ['mail'],
      }),
      expired,
    );
    await held.started.future;
    await office.connect('https://a.example', 'synthetic-agent');
    await office.connect('https://a.example', 'synthetic-human');
    held.result.complete(
      response({
        'settings': {
          'revision': 8,
          'mobile_nav': ['mail'],
        },
      }),
    );
    await rejected;
    expect(office.identityGeneration, greaterThan(originalGeneration));
    expect(office.me!['id'], 'human');
    expect(office.settings['revision'], 7);
    expect(office.settings.containsKey('mobile_nav'), false);
  });

  test('Settings HTTP CAS preserves state until reload and explicit new revision save', () async {
    final service = SettingsService();
    final office = SettingsTransportOffice(service);
    addTearDown(() {
      office.dispose();
      service.finish();
    });
    await office.connect('https://a.example', 'synthetic-agent');
    service.revision = 10;
    await expectLater(
      office.saveSettings({'text_scale': 1.15}),
      throwsA(isA<OfficeException>().having((e) => e.status, 'status', 409)),
    );
    expect(office.settings['revision'], 7);
    expect(office.settings.containsKey('text_scale'), false);
    await office.reloadSettings();
    expect(office.settings['revision'], 10);
    await office.saveSettings({'text_scale': 1.15}, baseRevision: 10);
    expect(office.settings['revision'], 11);
    expect(office.settings['text_scale'], 1.15);
    final bodies = service.calls
        .where((r) => r.method == 'PATCH')
        .map((r) => jsonDecode(r.body) as Map)
        .toList();
    expect(bodies.map((b) => b['base_revision']).toList(), [7, 10]);
  });

  for (final stage in ['account', 'login', 'connect']) {
    test(
      'Password change late $stage completion cannot reconnect over another identity',
      () async {
        final service = SettingsService();
        final office = SettingsTransportOffice(service);
        addTearDown(() {
          office.dispose();
          service.finish();
        });
        await office.connect('https://a.example', 'synthetic-human');
        final held = service.hold(
          stage == 'connect' ? 'GET' : 'POST',
          switch (stage) {
            'account' => '/auth/account',
            'login' => '/auth/login',
            _ => '/me',
          },
        );
        final rejected = expectLater(
          office.setAccount(
            'fixture.user',
            'fixture-password-only',
            currentPassword: 'fixture-current-only',
          ),
          expired,
        );
        await held.started.future;
        await office.connect('https://b.example', 'synthetic-agent');
        held.result.complete(
          response({
            'account': {'username': 'fixture.user'},
            'token': 'synthetic-updated',
            'session_id': 'new-session',
            'principal': {'id': 'updated', 'kind': 'human'},
          }),
        );
        await rejected;
        expect(office.me!['id'], 'agent');
        expect(office.endpoint, 'https://b.example');
        expect(office.connected, true);
        final logins = service.calls
            .where((r) => r.url.path.endsWith('/auth/login'))
            .toList();
        expect(logins.length, stage == 'account' ? 0 : 1);
        expect(logins.every((r) => r.url.host == 'a.example'), true);
      },
    );
  }

  test('Password change succeeds on original endpoint and late session revoke cannot sign out B', () async {
    final service = SettingsService();
    final office = SettingsTransportOffice(service);
    addTearDown(() {
      office.dispose();
      service.finish();
    });
    await office.connect('https://a.example', 'synthetic-human');
    final before = office.identityGeneration;
    await office.setAccount('fixture.user', 'fixture-password-only');
    expect(office.identityGeneration, greaterThan(before));
    expect(office.me!['id'], 'updated');
    final held = service.hold('DELETE', '/auth/sessions/new-session');
    final rejected = expectLater(office.revokeSession('new-session'), expired);
    await held.started.future;
    await office.loginWithPassword(
      'https://b.example',
      'fixture.other',
      'fixture-other-password',
    );
    held.result.complete(response({'revoked': true}));
    await rejected;
    expect(office.endpoint, 'https://b.example');
    expect(office.connected, true);
    expect(office.me, isNotNull);
    await office.revokeSession('new-session');
    expect(office.me, isNull);
  });

  for (final width in [390.0, 1512.0]) {
    testWidgets(
      'Navigation draft permanently locks across A B A with equal settings revisions $width',
      (tester) async {
        final office = NavigationIdentityOffice();
        final originalId = office.me!['id'] as String;
        await openNavigation(tester, office, width);
        await tester.tap(find.byTooltip('上移Agent'));
        await tester.pump();
        office.temporaryOffline();
        await tester.pump();
        expect(find.text('底栏编辑已锁定'), findsNothing);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
              .onPressed,
          isNull,
        );
        expect(find.byTooltip('上移消息'), findsOneWidget);
        office.switchIdentity('other');
        office.switchIdentity(originalId);
        await tester.pumpAndSettle();
        expect(find.text('底栏编辑已锁定'), findsOneWidget);
        expect(find.text('保存'), findsNothing);
        expect(find.text('添加功能'), findsNothing);
        expect(office.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'A late navigation conflict preview stays hidden after identity switch',
    (tester) async {
      final office = NavigationIdentityOffice(conflict: true);
      office.delayedRead = Completer<Json>();
      await openNavigation(tester, office, 390);
      await tester.tap(find.byTooltip('上移Agent'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('读取最新设置'));
      await tester.tap(find.text('读取最新设置'));
      await tester.pump();
      await office.readStarted.future;
      office.switchIdentity('other');
      office.delayedRead!.complete({
        'settings': {
          'revision': 99,
          'mobile_nav': ['mail', 'calendar'],
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('底栏编辑已锁定'), findsOneWidget);
      expect(find.textContaining('服务器底栏'), findsNothing);
      expect(find.text('保留我的排序继续编辑'), findsNothing);
      expect(office.writes.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Late navigation save does not close or mutate a new identity editor context',
    (tester) async {
      final office = NavigationIdentityOffice();
      office.delayedSave = Completer<void>();
      await openNavigation(tester, office, 390);
      await tester.tap(find.text('保存'));
      await tester.pump();
      await office.saveStarted.future;
      office.switchIdentity('other');
      office.delayedSave!.complete();
      await tester.pumpAndSettle();
      expect(find.text('底栏编辑已锁定'), findsOneWidget);
      expect(office.settings['mobile_nav'], ['mail', 'calendar']);
      expect(office.writes.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
