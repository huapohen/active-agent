import 'package:url_launcher/url_launcher.dart';

import 'document_editor_window.dart';

DocumentEditorWindow reserveDocumentEditorWindow() => _NativeEditorWindow();

class _NativeEditorWindow implements DocumentEditorWindow {
  @override
  Future<void> navigate(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw Exception('无法打开浏览器，请检查系统默认浏览器');
    }
  }

  @override
  void close() {}
}
