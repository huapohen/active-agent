import 'dart:async';

import 'package:flutter/foundation.dart';

import 'office_state.dart';

/// Personal navigation over authorized rooms; labels never grant membership.
class OfficeMessageGroups extends ChangeNotifier {
  OfficeMessageGroups(this.state) {
    _identity = identityKey;
    state.addListener(_scheduleRefresh);
  }
  final OfficeState state;
  Json snapshot = {};
  String selectedId = 'messages';
  String? error;
  bool loading = false, _disposed = false;
  Timer? _timer;
  late String _identity;
  int _generation = 0;
  String get identityKey =>
      '${state.endpoint}|${state.me?['id']}|${state.connected}';

  void assertIdentity(String expected) {
    _syncIdentity();
    if (expected != identityKey) throw OfficeException(409, '当前身份已变化，请重新打开分组');
  }

  void _syncIdentity() {
    if (_identity == identityKey) return;
    _identity = identityKey;
    _generation++;
    snapshot = {};
    selectedId = 'messages';
    error = null;
    loading = false;
    if (!_disposed) notifyListeners();
  }

  int get revision => (snapshot['revision'] as num?)?.toInt() ?? 0;
  bool get loaded => revision > 0;
  List<Json> get groups => (snapshot['groups'] as List? ?? [])
      .whereType<Map>()
      .map((item) => Json.from(item))
      .toList();
  List<String> get order => List<String>.from(snapshot['order'] ?? []);
  List<String> get shortcuts =>
      List<String>.from(snapshot['shortcut_ids'] ?? []);
  Json? group(String id) =>
      groups.where((item) => item['id'] == id).firstOrNull;
  List<Json> get visible => [
    for (final id in order)
      if (group(id) case final item? when item['visible'] == true) item,
  ];
  List<Json> get labels =>
      groups.where((item) => item['type'] == 'label').toList();
  List<Json> get filteredRooms {
    final selected = group(selectedId);
    if (selected == null) return state.rooms;
    final ids = Set<String>.from(selected['room_ids'] ?? []);
    return state.rooms.where((room) => ids.contains(room['id'])).toList();
  }

  void select(String id) {
    selectedId = id;
    if (!_disposed) notifyListeners();
  }

  void _scheduleRefresh() {
    _syncIdentity();
    _timer?.cancel();
    if (state.connected) {
      _timer = Timer(const Duration(milliseconds: 350), refresh);
    }
  }

  void _accept(Json value, int generation) {
    _syncIdentity();
    if (_disposed || generation != _generation) {
      throw OfficeException(409, '当前身份已变化，请重新打开分组');
    }
    if (value['revision'] is! num || value['groups'] is! List) {
      throw OfficeException(502, '分组响应不完整，请刷新后重试');
    }
    if (_disposed || (value['revision'] as num) < revision) return;
    snapshot = value;
    error = null;
    if (group(selectedId) == null ||
        (group(selectedId)?['visible'] != true &&
            !shortcuts.contains(selectedId))) {
      selectedId = 'messages';
    }
    notifyListeners();
  }

  Future<Json> readLatest() async {
    _syncIdentity();
    final generation = _generation;
    final result = await state.officeRequest('/message-groups');
    _accept(result, generation);
    return result;
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _syncIdentity();
    final generation = _generation;
    loading = true;
    notifyListeners();
    try {
      await readLatest();
    } catch (failure) {
      if (!_disposed && generation == _generation) error = failure.toString();
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<Json> write(String path, String method, Json data) async {
    _syncIdentity();
    final generation = _generation;
    final result = await state.officeRequest(path, method: method, data: data);
    _accept(result, generation);
    return result;
  }

  Future<Json> saveLayout({
    required int baseRevision,
    required List<String> order,
    required List<String> hiddenIds,
    required List<String> shortcutIds,
  }) => write('/message-groups', 'PATCH', {
    'base_revision': baseRevision,
    'order': order,
    'hidden_ids': hiddenIds,
    'shortcut_ids': shortcutIds,
  });

  Future<Json> createLabel({
    required int baseRevision,
    required String clientId,
    required String name,
    String? nameContains,
  }) => write('/message-groups', 'POST', {
    'base_revision': baseRevision,
    'client_id': clientId,
    'name': name,
    'name_contains': nameContains,
  });

  Future<Json> updateLabel(
    String id,
    Json changes, {
    required int baseRevision,
  }) => write('/message-groups/${Uri.encodeComponent(id)}', 'PATCH', {
    'base_revision': baseRevision,
    ...changes,
  });
  Future<Json> deleteLabel(String id, {required int baseRevision}) => write(
    '/message-groups/${Uri.encodeComponent(id)}',
    'DELETE',
    {'base_revision': baseRevision},
  );
  Future<Json> roomDetail(String id) async {
    final identity = identityKey;
    final result = await state.officeRequest(
      '/rooms/${Uri.encodeComponent(id)}',
    );
    assertIdentity(identity);
    return result;
  }

  Future<Json> updateRoom(
    String id,
    Json changes, {
    required int baseRevision,
  }) => write('/rooms/${Uri.encodeComponent(id)}/message-groups', 'PATCH', {
    'base_revision': baseRevision,
    ...changes,
  });

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    state.removeListener(_scheduleRefresh);
    super.dispose();
  }
}
