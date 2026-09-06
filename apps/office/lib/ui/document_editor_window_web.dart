import 'package:web/web.dart' as web;

import 'document_editor_window.dart';

DocumentEditorWindow reserveDocumentEditorWindow() {
  final opened = web.window.open('about:blank', '_blank');
  if (opened == null) {
    throw Exception('浏览器拦截了编辑窗口，请允许本站弹窗后重试。');
  }
  try {
    opened.opener = null;
    return _BrowserEditorWindow(opened);
  } catch (_) {
    opened.close();
    rethrow;
  }
}

class _BrowserEditorWindow implements DocumentEditorWindow {
  _BrowserEditorWindow(this.window);
  final web.Window window;

  @override
  Future<void> navigate(Uri url) async {
    if (window.closed) {
      throw Exception('编辑窗口已关闭，请重新打开协作编辑器。');
    }
    window.location.replace(url.toString());
  }

  @override
  void close() {
    if (!window.closed) window.close();
  }
}
