import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'mobile_navigation.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

const defaultOfficeDesktopNavigation = [
  'messages',
  'agents',
  'contacts',
  'docs',
  'tasks',
  'workbench',
  'meetings',
  'calendar',
  'mail',
  'attendance',
  'approvals',
  'minutes',
];

List<OfficeNavigationItem> officeDesktopNavigation(
  OfficeState state, [
  List<dynamic>? configured,
]) {
  final raw = configured ?? state.settings['desktop_nav'];
  final ids = raw is List ? raw : defaultOfficeDesktopNavigation;
  final available = {
    for (final item in officeNavigationItems)
      if (item.id != 'enterprise') item.id: item,
  };
  final selected = <OfficeNavigationItem>[];
  final seen = <String>{};
  for (final id in ids) {
    if (id is String && available.containsKey(id) && seen.add(id)) {
      selected.add(available[id]!);
    }
  }
  return selected.isEmpty
      ? defaultOfficeDesktopNavigation.map((id) => available[id]!).toList()
      : selected;
}

/// Captures one person's explicit navigation draft and settings revision.
/// Reconnects preserve the draft; identity changes permanently retire it.
class _DesktopNavigationSession extends ChangeNotifier {
  _DesktopNavigationSession(this.state) {
    _identity = _currentIdentity;
    selected = officeDesktopNavigation(state).map((item) => item.id).toList();
    revision = (state.settings['revision'] as num?)?.toInt() ?? 1;
    state.addListener(_changed);
  }
  final OfficeState state;
  late final (int, String, String) _identity;
  late List<String> selected;
  late int revision;
  Json? latest;
  bool busy = false, conflict = false, _expired = false, _disposed = false;
  String? error;
  (int, String, String) get _currentIdentity =>
      (state.identityGeneration, state.endpoint, personId(state.me ?? {}));
  bool get valid =>
      !_disposed &&
      !_expired &&
      state.me != null &&
      _identity == _currentIdentity;
  bool get canEdit => valid && !busy;
  bool get canSave => canEdit && state.connected && !conflict;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    if (!valid) {
      _expired = true;
      selected = [];
      latest = null;
      error = null;
    }
    _notify();
  }

  void replace(List<String> value) {
    if (!canEdit) return;
    selected = [...value];
    _notify();
  }

  void move(int from, int to) {
    if (!canEdit || from == to || to < 0 || to >= selected.length) return;
    selected.insert(to, selected.removeAt(from));
    _notify();
  }

  Future<bool> save() async {
    if (!canSave) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await state.saveSettings({
        'desktop_nav': [...selected],
      }, baseRevision: revision);
      return valid;
    } catch (exception) {
      if (valid) {
        error = friendlyError(exception);
        conflict = exception is OfficeException && exception.status == 409;
      }
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> readLatest() async {
    if (!canEdit || !state.connected) return;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await state.officeRequest('/settings');
      if (valid) latest = Json.from(result['settings'] as Map);
    } catch (exception) {
      if (valid) error = friendlyError(exception);
    } finally {
      busy = false;
      _notify();
    }
  }

  void adopt({required bool useRemote}) {
    if (!canEdit || latest == null || !state.connected) return;
    if (useRemote) {
      selected = officeDesktopNavigation(
        state,
        latest!['desktop_nav'] as List? ?? defaultOfficeDesktopNavigation,
      ).map((item) => item.id).toList();
    }
    revision = (latest!['revision'] as num).toInt();
    latest = null;
    conflict = false;
    error = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    state.removeListener(_changed);
    super.dispose();
  }
}

Future<void> showOfficeDesktopNavigationEditor(
  BuildContext context,
  OfficeState state,
) async {
  final session = _DesktopNavigationSession(state);
  try {
    await _showEditor(context, session);
  } finally {
    session.dispose();
  }
}

Future<void> _showEditor(
  BuildContext context,
  _DesktopNavigationSession session,
) => showDialog<void>(
  context: context,
  builder: (_) => _DesktopNavigationEditor(session: session),
);

Future<void> showOfficeDesktopNavigationMenu(
  BuildContext context,
  OfficeState state,
  OfficeNavigationItem item, {
  required Offset position,
  required VoidCallback onOpen,
}) async {
  final session = _DesktopNavigationSession(state);
  final openingSelection = [...session.selected];
  try {
    final edit = await showDialog<bool>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => _DesktopNavigationMenu(
        session: session,
        item: item,
        openingSelection: openingSelection,
        position: position,
        onOpen: onOpen,
      ),
    );
    if (edit == true && context.mounted && session.valid) {
      await _showEditor(context, session);
    }
  } finally {
    session.dispose();
  }
}

class _DesktopNavigationEditor extends StatelessWidget {
  const _DesktopNavigationEditor({required this.session});
  final _DesktopNavigationSession session;

  Future<void> _save(BuildContext context) async {
    if (await session.save() &&
        context.mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      if (!session.valid) return const _NavigationExpired();
      final selected = session.selected;
      return Dialog(
        child: SizedBox(
          width: 580,
          height: 680,
          child: Scaffold(
            backgroundColor: Colors.white,
            appBar: AppBar(
              title: const Text('编辑导航栏'),
              leading: IconButton(
                tooltip: '取消导航栏编辑',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
              actions: [
                TextButton(
                  onPressed: session.canSave ? () => _save(context) : null,
                  child: Text(session.busy ? '保存中…' : '保存'),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  '把常用应用放在左侧',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '已选 ${selected.length}/12 · 拖动或使用箭头排序，至少保留一项。移除后仍可从“更多”打开。',
                  style: const TextStyle(fontSize: 12, color: mutedColor),
                ),
                if (!session.state.connected)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('连接已中断，草稿已保留；重新连接后可以保存。'),
                  ),
                const SizedBox(height: 16),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: selected.length,
                  onReorderItem: session.canEdit ? session.move : (_, _) {},
                  itemBuilder: (context, index) {
                    final item = officeNavigationItems.firstWhere(
                      (item) => item.id == selected[index],
                    );
                    return Material(
                      key: ValueKey('desktop-nav-${item.id}'),
                      color: const Color(0xfff4f6fa),
                      child: ListTile(
                        leading: ReorderableDragStartListener(
                          index: index,
                          enabled: session.canEdit,
                          child: const Icon(Icons.drag_handle, size: 20),
                        ),
                        title: Text(
                          item.label,
                          style: const TextStyle(fontSize: 13),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '上移${item.label}',
                              onPressed: session.canEdit && index > 0
                                  ? () => session.move(index, index - 1)
                                  : null,
                              icon: const Icon(Icons.arrow_upward, size: 16),
                            ),
                            IconButton(
                              tooltip: '下移${item.label}',
                              onPressed:
                                  session.canEdit && index < selected.length - 1
                                  ? () => session.move(index, index + 1)
                                  : null,
                              icon: const Icon(Icons.arrow_downward, size: 16),
                            ),
                            IconButton(
                              tooltip: '移除${item.label}',
                              onPressed: session.canEdit && selected.length > 1
                                  ? () => session.replace(
                                      [...selected]..removeAt(index),
                                    )
                                  : null,
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                size: 18,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                const Text(
                  '添加应用',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in officeNavigationItems)
                      if (item.id != 'enterprise' &&
                          !selected.contains(item.id))
                        ActionChip(
                          label: Text(item.label),
                          avatar: Icon(item.icon, size: 17),
                          onPressed: session.canEdit && selected.length < 12
                              ? () => session.replace([...selected, item.id])
                              : null,
                        ),
                  ],
                ),
                TextButton(
                  onPressed: session.canEdit
                      ? () => session.replace(defaultOfficeDesktopNavigation)
                      : null,
                  child: const Text('恢复默认导航栏'),
                ),
                if (session.error != null)
                  Text(
                    session.error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                if (session.conflict && session.latest == null) ...[
                  const Text('设置已在其他客户端修改。你的选择与排序已保留，请读取最新设置再决定。'),
                  TextButton(
                    onPressed: session.canEdit && session.state.connected
                        ? session.readLatest
                        : null,
                    child: const Text('读取最新设置'),
                  ),
                ],
                if (session.latest != null) ...[
                  Text(
                    '服务器导航栏：${officeDesktopNavigation(session.state, session.latest!['desktop_nav'] as List? ?? defaultOfficeDesktopNavigation).map((item) => item.label).join(' / ')}',
                  ),
                  const Text('采用后继续编辑，点击“保存”才会写入。'),
                  TextButton(
                    onPressed: session.canEdit && session.state.connected
                        ? () => session.adopt(useRemote: true)
                        : null,
                    child: const Text('采用服务器导航继续编辑'),
                  ),
                  TextButton(
                    onPressed: session.canEdit && session.state.connected
                        ? () => session.adopt(useRemote: false)
                        : null,
                    child: const Text('保留我的导航继续编辑'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _NavigationExpired extends StatelessWidget {
  const _NavigationExpired();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导航栏操作已锁定'),
    content: const Text('工作身份已变化，请关闭后重新打开导航栏。'),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class _DesktopNavigationMenu extends StatelessWidget {
  const _DesktopNavigationMenu({
    required this.session,
    required this.item,
    required this.openingSelection,
    required this.position,
    required this.onOpen,
  });
  final _DesktopNavigationSession session;
  final OfficeNavigationItem item;
  final List<String> openingSelection;
  final Offset position;
  final VoidCallback onOpen;

  Future<void> _apply(BuildContext context, int? offset) async {
    if (!session.canSave) return;
    final index = openingSelection.indexOf(item.id);
    if (index < 0) return;
    final intended = [...openingSelection];
    if (offset == null) {
      if (intended.length == 1) return;
      intended.removeAt(index);
    } else {
      final target = index + offset;
      if (target < 0 || target >= intended.length) return;
      intended.insert(target, intended.removeAt(index));
    }
    session.replace(intended);
    if (await session.save() &&
        context.mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      if (!session.valid) return const _NavigationExpired();
      final size = MediaQuery.sizeOf(context);
      final width = (size.width - 24).clamp(0.0, 270.0).toDouble();
      final left = position.dx
          .clamp(12.0, (size.width - width - 12).clamp(12.0, double.infinity))
          .toDouble();
      final top = position.dy
          .clamp(12.0, (size.height - 320).clamp(12.0, double.infinity))
          .toDouble();
      final index = openingSelection.indexOf(item.id);
      final writable = session.canSave && index >= 0;
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: width,
            child: Material(
              elevation: 10,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (size.height - top - 12).clamp(
                    0.0,
                    double.infinity,
                  ),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                        child: Text(
                          item.label,
                          style: const TextStyle(
                            color: mutedColor,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      MenuItemButton(
                        leadingIcon: const Icon(Icons.open_in_new, size: 18),
                        onPressed: session.canEdit
                            ? () {
                                if (!session.valid) return;
                                Navigator.pop(context);
                                onOpen();
                              }
                            : null,
                        child: const Text('打开'),
                      ),
                      MenuItemButton(
                        leadingIcon: const Icon(Icons.arrow_upward, size: 18),
                        onPressed: writable && index > 0
                            ? () => _apply(context, -1)
                            : null,
                        child: const Text('上移'),
                      ),
                      MenuItemButton(
                        leadingIcon: const Icon(Icons.arrow_downward, size: 18),
                        onPressed:
                            writable && index < openingSelection.length - 1
                            ? () => _apply(context, 1)
                            : null,
                        child: const Text('下移'),
                      ),
                      MenuItemButton(
                        leadingIcon: const Icon(
                          Icons.remove_circle_outline,
                          size: 18,
                        ),
                        onPressed: writable && openingSelection.length > 1
                            ? () => _apply(context, null)
                            : null,
                        child: const Text('从导航栏移除'),
                      ),
                      const Divider(height: 1),
                      MenuItemButton(
                        leadingIcon: const Icon(Icons.tune, size: 18),
                        onPressed: session.canEdit
                            ? () => Navigator.pop(context, true)
                            : null,
                        child: const Text('编辑导航栏'),
                      ),
                      if (!session.state.connected)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('连接中断，暂时无法保存导航栏。'),
                        ),
                      if (session.error != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            session.error!,
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      if (session.conflict)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('导航修改已保留，请进入“编辑导航栏”读取并核对最新设置。'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
