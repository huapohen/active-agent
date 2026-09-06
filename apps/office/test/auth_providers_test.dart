import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/auth_providers.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class PublicAuthOffice extends OfficeState {
  PublicAuthOffice({super.client});
  String? connectedToken;
  @override
  Future<void> connect(String server, String token) async =>
      connectedToken = token;
}

void main() {
  test('OIDC verifier stays in initiating client and exchange body', () async {
    final requests = <http.Request>[];
    final state = PublicAuthOffice(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/start')) {
          return http.Response(
            jsonEncode({
              'authorization_url':
                  'https://identity.example/authorize?state=single-use',
              'expires_in': 600,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'principal': {'id': 'mapped-agent', 'kind': 'agent'},
            'token': 'synthetic-session-token',
            'session_id': 'session-demo',
          }),
          200,
        );
      }),
    );
    final attempt = await state.startExternalLogin(
      'https://office.example',
      'corporate',
    );
    final start = jsonDecode(requests.first.body) as Map;
    expect(
      start['code_challenge'],
      base64UrlEncode(sha256.convert(utf8.encode(attempt.verifier)).bytes)
          .replaceAll('=', ''),
    );
    expect(start.containsKey('code_verifier'), isFalse);
    expect(attempt.verifier.length, 43);
    await state.exchangeExternalLogin(
      'https://office.example',
      attempt,
      'single-use-code',
    );
    expect(jsonDecode(requests.last.body)['code_verifier'], attempt.verifier);
    expect(requests.last.url.query, isEmpty);
    expect(requests.every((r) => r.headers['authorization'] == null), isTrue);
    expect(state.connectedToken, 'synthetic-session-token');
    state.dispose();
  });
  testWidgets(
    'Only configured provider opens actual authorization and exchanges code',
    (tester) async {
      Uri? opened;
      String? exchanged;
      bool? localPassword;
      const attempt = OfficeExternalLogin(
        providerId: 'company',
        authorizationUrl: 'https://identity.example/authorize?state=ephemeral',
        verifier: 'fixture-verifier',
        expiresIn: 600,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: OfficeAuthProviders(
                endpoint: 'https://office.example',
                discover: (_) async => {
                  'local_password': {'enabled': false},
                  'machine_token': {'enabled': true},
                  'providers': [
                    {'id': 'company', 'label': '企业身份', 'protocol': 'oidc'},
                  ],
                },
                start: (_, _) async => attempt,
                exchange: (_, received, code) async {
                  expect(identical(received, attempt), isTrue);
                  exchanged = code;
                },
                openUrl: (url) async {
                  opened = url;
                  return true;
                },
                onMethods: (password, token) => localPassword = password,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(localPassword, false);
      await tester.tap(find.text('使用企业身份登录'));
      await tester.pumpAndSettle();
      expect(opened?.host, 'identity.example');
      final input = find.byType(TextField);
      expect(tester.widget<TextField>(input).obscureText, true);
      await tester.enterText(input, 'returned-single-use-code');
      await tester.tap(find.text('验证并进入工作空间'));
      await tester.pumpAndSettle();
      expect(exchanged, 'returned-single-use-code');
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
