import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../message_groups.dart';
import '../office_state.dart' show OfficeException;
import 'message_group_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

Future<void> showOfficeMessageGroupEditor(
  BuildContext context,
  OfficeMessageGroups controller,
) => showOfficeMessageGroupDialog(
  context,
  controller,
  useSafeArea: MediaQuery.sizeOf(context).width >= 760,
  builder: (_) => OfficeMessageGroupEditor(controller: controller),
);

class OfficeMessageGroupEditor extends StatefulWidget {
  const OfficeMessageGroupEditor({super.key, required this.controller});
  final OfficeMessageGroups controller;
  @override
  State<OfficeMessageGroupEditor> createState() =>
      _OfficeMessageGroupEditorState();
}

class _OfficeMessageGroupEditorState extends State<OfficeMessageGroupEditor> {
  late final String _identity;
  late int _revision;
  late List<String> _order;
  late Set<String> _hidden;
  late List<String> _shortcuts;
  late List<Json> _groups;
  late Map<String, String> _displayRules;
  final Set<String> _editedRuleIds = {};
  late bool _includeDisplayRules;
  @override
  void initState() {
    super.initState();
    _identity = widget.controller.identityKey;
    _revision = widget.controller.revision;
    _order = widget.controller.order;
    _hidden = Set<String>.from(widget.controller.snapshot['hidden_ids'] ?? []);
    _shortcuts = widget.controller.shortcuts;
    _groups = widget.controller.groups;
    _displayRules = Map<String, String>.from(
      widget.controller.snapshot['message_display_rules'] ?? {},
    );
    _includeDisplayRules = widget.controller.snapshot.containsKey(
      'message_display_rules',
    );
  }

  Json? _latest;
  String? _error;
  bool _busy = false, _conflict = false;
  Json item(String id) => _groups.firstWhere((group) => group['id'] == id);

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.controller.assertIdentity(_identity);
      await widget.controller.saveLayout(
        baseRevision: _revision,
        order: _order,
        hiddenIds: _hidden.toList(),
        shortcutIds: _shortcuts,
        messageDisplayRules: _includeDisplayRules || _editedRuleIds.isNotEmpty
            ? _displayRules
            : null,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = friendlyError(error);
          _conflict = error is OfficeException && error.status == 409;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readLatest() async {
    setState(() => _busy = true);
    try {
      widget.controller.assertIdentity(_identity);
      final latest = await widget.controller.readLatest();
      if (mounted) setState(() => _latest = latest);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _adopt() => setState(() {
    final current = List<String>.from(_latest!['order']);
    _groups = maps(_latest!['groups']);
    _order = [
      ..._order.where(current.contains),
      ...current.where((id) => !_order.contains(id)),
    ];
    _hidden = _hidden.where(current.contains).toSet()..remove('messages');
    _shortcuts = [
      'messages',
      ..._shortcuts.where((id) => id != 'messages' && current.contains(id)),
    ];
    final latestRules = Map<String, String>.from(
      _latest!['message_display_rules'] ?? {},
    );
    for (final id in _editedRuleIds.where(current.contains)) {
      latestRules[id] = _displayRules[id]!;
    }
    _editedRuleIds.removeWhere((id) => !current.contains(id));
    _displayRules = latestRules;
    _includeDisplayRules = _latest!.containsKey('message_display_rules');
    _revision = (_latest!['revision'] as num).toInt();
    _latest = null;
    _conflict = false;
    _error = null;
  });

  void _move(List<String> section, int old, int next) {
    if (section[old] == 'messages' ||
        (section.contains('messages') && next == 0)) {
      return;
    }
    final sorted = [...section];
    sorted.insert(next, sorted.removeAt(old));
    var cursor = 0;
    setState(
      () => _order = [
        for (final id in _order) section.contains(id) ? sorted[cursor++] : id,
      ],
    );
  }

  Future<void> _configureDisplay(String id) async {
    await showOfficeMessageGroupDialog(
      context,
      widget.controller,
      useSafeArea: MediaQuery.sizeOf(context).width >= 760,
      builder: (_) => _MessageGroupDisplaySettings(
        controller: widget.controller,
        group: id == 'labels' ? null : item(id),
        labels: _groups.where((group) => group['type'] == 'label').toList(),
        rules: _displayRules,
        onApply: (rules, appliedIds) {
          widget.controller.assertIdentity(_identity);
          if (!mounted) return;
          setState(() {
            _editedRuleIds.addAll(appliedIds);
            _displayRules = rules;
          });
        },
      ),
    );
  }

  Future<void> _addShortcut() async {
    final choices = [
      for (final id in _order)
        if (!_shortcuts.contains(id) && item(id)['available'] != false)
          item(id),
    ];
    await showOfficeMessageGroupDialog(
      context,
      widget.controller,
      useSafeArea: MediaQuery.sizeOf(context).width >= 760,
      builder: (pickerContext) => _MessageGroupSheet(
        title: '选择常用分组',
        onCancel: () => Navigator.pop(pickerContext),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Material(
              color: Colors.white,
              child: Column(
                children: [
                  for (final group in choices)
                    ListTile(
                      key: ValueKey('shortcut-choice-${group['id']}'),
                      minTileHeight: 45,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      title: Text(
                        str(group['name']),
                        style: const TextStyle(fontSize: 15),
                      ),
                      onTap: () {
                        widget.controller.assertIdentity(_identity);
                        if (!_busy && _shortcuts.length < 8 && mounted) {
                          setState(() => _shortcuts.add(str(group['id'])));
                        }
                        Navigator.pop(pickerContext);
                      },
                    ),
                  if (choices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        '所有可用分组均已添加',
                        style: TextStyle(color: mutedColor),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shortcut(String id) {
    final removable = id != 'messages';
    final name = str(item(id)['name']);
    return Container(
      key: ValueKey('shortcut-$id'),
      height: 32,
      padding: EdgeInsets.only(left: 16, right: removable ? 6 : 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Semantics(
              container: true,
              child: Tooltip(
                message: name,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
          if (removable)
            IconButton(
              tooltip: '移除常用分组${item(id)['name']}',
              onPressed: _busy
                  ? null
                  : () => setState(() => _shortcuts.remove(id)),
              icon: const Icon(Icons.close, size: 14, color: accentColor),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 32),
            ),
        ],
      ),
    );
  }

  Widget _section(String title, List<String> ids, {bool hidden = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 5),
            child: Text(
              title,
              style: const TextStyle(fontSize: 12, color: mutedColor),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ReorderableListView(
              shrinkWrap: true,
              primary: false,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (old, next) => _move(ids, old, next),
              children: [
                for (var index = 0; index < ids.length; index++)
                  _groupRow(ids, index, hidden: hidden),
              ],
            ),
          ),
        ],
      );

  Widget _groupRow(List<String> ids, int index, {required bool hidden}) {
    final id = ids[index];
    final name = str(item(id)['name']);
    final fixed = id == 'messages';
    final hasSettings =
        item(id)['type'] == 'label' ||
        const {
          'labels',
          'direct',
          'groups',
          'documents',
          'topics',
          'agents',
        }.contains(id);
    final subtitle = hasSettings && id != 'labels'
        ? '在“消息”分组中：${_displayRuleSubtitle(_displayRules[id])}'
        : null;
    return Material(
      key: ValueKey(id),
      color: Colors.white,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: subtitle == null ? 44 : 64),
        child: Row(
          children: [
            const SizedBox(width: 11),
            IconButton(
              tooltip: '${hidden ? '展示' : '隐藏'}$name',
              style: IconButton.styleFrom(
                minimumSize: const Size(36, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _busy || fixed
                  ? null
                  : () => setState(() {
                      if (hidden) {
                        _hidden.remove(id);
                      } else {
                        _hidden.add(id);
                      }
                    }),
              icon: Icon(
                hidden ? Icons.add_circle : Icons.remove_circle,
                size: 24,
                color: fixed
                    ? const Color(0xffc5c8cc)
                    : hidden
                    ? const Color(0xff34b565)
                    : const Color(0xffff4052),
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 44),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Container(
                constraints: BoxConstraints(
                  minHeight: subtitle == null ? 44 : 64,
                ),
                decoration: BoxDecoration(
                  border: index < ids.length - 1
                      ? const Border(
                          bottom: BorderSide(color: Color(0xfff5f6f7)),
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(fontSize: 15),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xffa9aeb5),
                                ),
                                maxLines: 2,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (hasSettings)
                      IconButton(
                        tooltip: '设置$name消息展示',
                        style: IconButton.styleFrom(
                          minimumSize: const Size(40, 44),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: _busy ? null : () => _configureDisplay(id),
                        icon: const Icon(
                          Icons.settings_outlined,
                          size: 21,
                          color: mutedColor,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 44,
                        ),
                      ),
                    if (!fixed && !hidden)
                      Semantics(
                        customSemanticsActions: _busy
                            ? null
                            : {
                                if (index > (ids.contains('messages') ? 1 : 0))
                                  CustomSemanticsAction(label: '上移$name'): () =>
                                      _move(ids, index, index - 1),
                                if (index < ids.length - 1)
                                  CustomSemanticsAction(label: '下移$name'): () =>
                                      _move(ids, index, index + 1),
                              },
                        child: Tooltip(
                          message: '拖动$name调整顺序',
                          child: ReorderableDragStartListener(
                            index: index,
                            enabled: !_busy,
                            child: const SizedBox(
                              width: 48,
                              height: 44,
                              child: Icon(
                                Icons.menu,
                                size: 23,
                                color: Color(0xffc9cdd2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!fixed && !hidden) const SizedBox(width: 6),
                    if (fixed || hidden) const SizedBox(width: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = _order
        .where((id) => item(id)['type'] == 'label' && !_hidden.contains(id))
        .toList();
    return _MessageGroupSheet(
      title: '编辑分组',
      onCancel: _busy ? null : () => Navigator.pop(context),
      onSave: _busy ? null : _save,
      saving: _busy,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Text(
            '常用分组',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final id in _shortcuts) _shortcut(id),
            Tooltip(
              message: _shortcuts.length >= 8 ? '最多8个常用分组' : '添加常用分组',
              child: SizedBox(
                width: 56,
                height: 32,
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: _busy || _shortcuts.length >= 8
                        ? null
                        : _addShortcut,
                    child: const Icon(Icons.add, size: 20, color: mutedColor),
                  ),
                ),
              ),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 38, 16, 0),
          child: Text(
            '侧栏分组',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        _section(
          '显示',
          _order
              .where(
                (id) => item(id)['type'] == 'builtin' && !_hidden.contains(id),
              )
              .toList(),
        ),
        if (labels.isNotEmpty) _section('标签顺序', labels),
        _section('隐藏', _order.where(_hidden.contains).toList(), hidden: true),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          ),
        if (_conflict)
          TextButton(
            onPressed: _busy ? null : _readLatest,
            child: const Text('读取最新分组'),
          ),
        if (_latest != null) ...[
          const Text(
            '服务器分组已更新。保留仍存在的本地排序与选择，新建分组追加到末尾。',
            style: TextStyle(fontSize: 11, height: 1.7),
          ),
          TextButton(
            onPressed: _busy ? null : _adopt,
            child: const Text('保留我的编辑并采用新版本'),
          ),
        ],
      ],
    );
  }
}

/// A fixed title and actions stay visible while long group lists scroll.
class _MessageGroupSheet extends StatelessWidget {
  const _MessageGroupSheet({
    required this.title,
    required this.onCancel,
    required this.children,
    this.onSave,
    this.saving = false,
    this.saveLabel = '保存',
  });
  final String title;
  final VoidCallback? onCancel, onSave;
  final bool saving;
  final String saveLabel;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final mobile = media.size.width < 760;
    final top = media.padding.top + 12;
    return Dialog(
      alignment: mobile ? Alignment.bottomCenter : Alignment.center,
      insetPadding: mobile
          ? EdgeInsets.only(top: top)
          : const EdgeInsets.all(32),
      backgroundColor: const Color(0xfff3f4f5),
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: const Radius.circular(13),
          bottom: Radius.circular(mobile ? 0 : 13),
        ),
      ),
      child: SizedBox(
        key: ValueKey('message-group-sheet-$title'),
        width: mobile ? media.size.width : 620,
        height: mobile ? media.size.height - top : media.size.height * .85,
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: inkColor,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: onCancel,
                      style: TextButton.styleFrom(
                        foregroundColor: inkColor,
                        textStyle: const TextStyle(fontSize: 15),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  if (onSave != null || saving)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: onSave,
                        style: TextButton.styleFrom(
                          textStyle: const TextStyle(fontSize: 15),
                        ),
                        child: Text(saving ? '保存中…' : saveLabel),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  0,
                  16,
                  20 + media.padding.bottom,
                ),
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _displayRuleLabels = <String, String>{
  'always': '始终显示',
  'unread': '有新消息时展示',
  'important': '有重要新消息时展示',
  'never': '始终不展示',
};

String _displayRuleSubtitle(String? rule) => rule == null
    ? '跟随其他分组设置'
    : rule == 'always'
    ? '始终展示'
    : _displayRuleLabels[rule] ?? '跟随其他分组设置';

class _MessageGroupDisplaySettings extends StatefulWidget {
  const _MessageGroupDisplaySettings({
    required this.controller,
    required this.group,
    required this.labels,
    required this.rules,
    required this.onApply,
  });
  final OfficeMessageGroups controller;
  final Json? group;
  final List<Json> labels;
  final Map<String, String> rules;
  final void Function(Map<String, String> rules, Set<String> appliedIds)
  onApply;
  @override
  State<_MessageGroupDisplaySettings> createState() =>
      _MessageGroupDisplaySettingsState();
}

class _MessageGroupDisplaySettingsState
    extends State<_MessageGroupDisplaySettings> {
  late final _identity = widget.controller.identityKey;
  late Map<String, String> _rules = Map.of(widget.rules);
  final Set<String> _appliedIds = {};

  String _value(Json group) => _rules[str(group['id'])] ?? 'always';

  Future<void> _openLabel(Json label) => showOfficeMessageGroupDialog(
    context,
    widget.controller,
    useSafeArea: MediaQuery.sizeOf(context).width >= 760,
    builder: (_) => _MessageGroupDisplaySettings(
      controller: widget.controller,
      group: label,
      labels: widget.labels,
      rules: _rules,
      onApply: (rules, appliedIds) {
        widget.controller.assertIdentity(_identity);
        if (mounted) {
          setState(() {
            _rules = rules;
            _appliedIds.addAll(appliedIds);
          });
        }
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    return _MessageGroupSheet(
      title: '消息展示设置',
      onCancel: () => Navigator.pop(context),
      saveLabel: '完成',
      onSave: () {
        widget.controller.assertIdentity(_identity);
        if (group != null) {
          _rules[str(group['id'])] = _value(group);
          _appliedIds.add(str(group['id']));
        }
        widget.onApply(Map.of(_rules), Set.of(_appliedIds));
        Navigator.pop(context);
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 5),
          child: Text(
            '设置“${group == null ? '标签' : str(group['name'])}”下的会话在“消息”分组中的展示效果',
            style: const TextStyle(fontSize: 12, color: mutedColor),
          ),
        ),
        if (group != null)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '完成后应用当前选项',
              style: TextStyle(fontSize: 12, color: mutedColor),
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Material(
            color: Colors.white,
            child: Column(
              children: group == null
                  ? [
                      for (final label in widget.labels)
                        ListTile(
                          key: ValueKey('label-display-${label['id']}'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          minTileHeight: 60,
                          title: Text(
                            str(label['name']),
                            style: const TextStyle(fontSize: 15),
                          ),
                          subtitle: Text(
                            _displayRuleSubtitle(_rules[str(label['id'])]),
                            style: const TextStyle(
                              fontSize: 11,
                              color: mutedColor,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right,
                            size: 20,
                            color: mutedColor,
                          ),
                          onTap: () => _openLabel(label),
                        ),
                      if (widget.labels.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text(
                            '暂无标签',
                            style: TextStyle(color: mutedColor),
                          ),
                        ),
                    ]
                  : [
                      for (final entry in _displayRuleLabels.entries)
                        Semantics(
                          selected: _value(group) == entry.key,
                          inMutuallyExclusiveGroup: true,
                          child: InkWell(
                            key: ValueKey('display-rule-${entry.key}'),
                            onTap: () => setState(
                              () => _rules[str(group['id'])] = entry.key,
                            ),
                            child: SizedBox(
                              height: 44,
                              child: Row(
                                children: [
                                  const SizedBox(width: 16),
                                  Container(
                                    width: 20,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: _value(group) == entry.key
                                            ? accentColor
                                            : const Color(0xffaeb2b8),
                                        width: _value(group) == entry.key
                                            ? 6
                                            : 1.5,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      entry.value,
                                      style: const TextStyle(fontSize: 15),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
            ),
          ),
        ),
      ],
    );
  }
}
