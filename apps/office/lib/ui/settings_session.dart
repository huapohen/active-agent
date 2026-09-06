import 'package:flutter/foundation.dart';

import '../office_state.dart' hide Json;
import 'office_theme.dart';

/// One settings visit belongs to one authenticated session, including A→B→A.
class OfficeSettingsSession extends ChangeNotifier {
  OfficeSettingsSession(this.state) {
    _identity = _identityKey;
    values = Json.from(state.settings);
    state.addListener(_changed);
  }
  final OfficeState state;
  late final String _identity;
  late Json values;
  Json? latest;
  bool busy = false, conflict = false, _expired = false, _disposed = false;
  String? error;
  String get _identityKey =>
      '${state.identityGeneration}|${state.endpoint}|${personId(state.me ?? {})}';
  bool get valid =>
      !_expired && !_disposed && state.me != null && _identity == _identityKey;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    if (!valid) {
      _expired = true;
      values = {};
      latest = null;
      error = null;
    } else if (!busy && !conflict) {
      values = Json.from(state.settings);
    }
    _notify();
  }

  Future<void> save(Json changes) async {
    if (!valid || !state.connected || busy || conflict) return;
    busy = true;
    error = null;
    _notify();
    try {
      await state.saveSettings(
        changes,
        baseRevision: (values['revision'] as num?)?.toInt() ?? 1,
      );
      if (!valid) return;
      values = Json.from(state.settings);
    } catch (exception) {
      if (valid) {
        error = exception.toString();
        conflict = exception is OfficeException && exception.status == 409;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> readLatest() async {
    if (!valid || !state.connected || busy) return;
    busy = true;
    _notify();
    try {
      final response = await state.officeRequest('/settings');
      if (valid) latest = Json.from(response['settings'] as Map);
    } catch (exception) {
      if (valid) error = exception.toString();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> adoptLatest() async {
    if (!valid || !state.connected || busy || latest == null) return;
    busy = true;
    _notify();
    try {
      await state.reloadSettings();
      if (!valid) return;
      values = Json.from(state.settings);
      latest = null;
      conflict = false;
      error = null;
    } catch (exception) {
      if (valid) error = exception.toString();
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    state.removeListener(_changed);
    super.dispose();
  }
}
