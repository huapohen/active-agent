import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart';

import 'office_state.dart';
import 'ui/login.dart';
import 'ui/office_shell.dart';
import 'ui/office_theme.dart';

void main() {
  runApp(const ActiveOfficeApp());
}

class ActiveOfficeApp extends StatefulWidget {
  const ActiveOfficeApp({super.key, this.state});
  final OfficeState? state;
  @override
  State<ActiveOfficeApp> createState() => _ActiveOfficeAppState();
}

class _ActiveOfficeAppState extends State<ActiveOfficeApp> {
  late final OfficeState state = widget.state ?? OfficeState();
  String get initialEndpoint {
    const configured = String.fromEnvironment('OFFICE_ENDPOINT');
    if (configured.isNotEmpty) {
      return configured;
    }
    if (kIsWeb) {
      return Uri.base.origin;
    }
    return defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:3218'
        : 'http://127.0.0.1:3218';
  }

  @override
  void dispose() {
    if (widget.state == null) {
      state.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '人机 · Active Office',
      debugShowCheckedModeBanner: false,
      theme: officeTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => AnimatedBuilder(
        animation: state,
        builder: (context, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(
              (state.settings['text_scale'] as num? ?? 1).toDouble().clamp(
                .85,
                1.3,
              ),
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) => state.me == null
            ? OfficeLogin(
                endpoint: state.endpoint.isEmpty
                    ? initialEndpoint
                    : state.endpoint,
                onConnect: state.connect,
                onLogin: state.loginWithPassword,
                discoverProviders: state.discoverAuthProviders,
                startExternalLogin: state.startExternalLogin,
                exchangeExternalLogin: state.exchangeExternalLogin,
              )
            : OfficeShell(state: state),
      ),
    );
  }
}
