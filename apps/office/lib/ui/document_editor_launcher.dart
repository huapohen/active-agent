import 'document_editor_window.dart';
import 'document_editor_window_native.dart'
    if (dart.library.js_interop) 'document_editor_window_web.dart'
    as platform;

/// Reserve the browser window synchronously while the click is still active.
/// Failure cleans up only that window; the office tab and its login stay alive.
Future<void> openOfficeDocumentEditor(
  Future<Uri> Function() issueTicket, {
  DocumentEditorWindow Function()? reserveWindow,
}) async {
  final target = (reserveWindow ?? platform.reserveDocumentEditorWindow)();
  try {
    final url = await issueTicket();
    await target.navigate(url);
  } catch (_) {
    target.close();
    rethrow;
  }
}
