import 'package:flutter/material.dart';

import 'office_theme.dart';

/// Explicit people and a group-wide mention are independent message semantics.
class OfficeMentionSelection {
  OfficeMentionSelection({
    required Iterable<String> selectedIds,
    this.mentionAll = false,
  }) : selectedIds = List<String>.unmodifiable(selectedIds.toSet());
  factory OfficeMentionSelection.fromDraft(Json draft, {required bool group}) =>
      OfficeMentionSelection(
        selectedIds: (draft['mentions'] as List? ?? []).map(str),
        mentionAll: group && draft['mention_all'] == true,
      );
  final List<String> selectedIds;
  final bool mentionAll;
}

class OfficeMentionPicker extends StatefulWidget {
  const OfficeMentionPicker({
    super.key,
    required this.people,
    required this.selected,
    required this.mobile,
    required this.group,
    this.mentionAll = false,
  });
  final List<Json> people;
  final List<String> selected;
  final bool mobile, group;
  final bool mentionAll;
  @override
  State<OfficeMentionPicker> createState() => _OfficeMentionPickerState();
}

class _OfficeMentionPickerState extends State<OfficeMentionPicker> {
  late final Set<String> _selected;
  late bool _mentionAll;
  String _query = '', _kind = 'all';
  @override
  void initState() {
    super.initState();
    final members = widget.people.map(personId).toSet();
    _selected = widget.selected.where(members.contains).toSet();
    _mentionAll = widget.group && widget.mentionAll;
  }

  @override
  Widget build(BuildContext context) {
    final allIds = widget.people.map(personId).toSet();
    final people =
        widget.people
            .where(
              (p) =>
                  (_kind == 'all' || p['kind'] == _kind) &&
                  ('${officeDisplayName(p)} ${str(p['name'])}')
                      .toLowerCase()
                      .contains(_query.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) => officeDisplayName(a).compareTo(officeDisplayName(b)),
          );
    final body = SafeArea(
      child: Material(
        color: Colors.white,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 14, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '取消选择',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                  const Expanded(
                    child: Text(
                      '选择成员',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 42),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 9, 18, 11),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索人或 Agent',
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: ['all', 'human', 'agent']
                    .map(
                      (kind) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            const {
                              'all': '全部',
                              'human': '成员',
                              'agent': 'Agent',
                            }[kind]!,
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: kind == _kind,
                          showCheckmark: false,
                          onSelected: (_) => setState(() => _kind = kind),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 7),
            if (widget.group && _query.isEmpty)
              CheckboxListTile(
                key: const ValueKey('mention-all-choice'),
                value: _mentionAll,
                onChanged: (value) =>
                    setState(() => _mentionAll = value == true),
                secondary: const CircleAvatar(
                  backgroundColor: selectedColor,
                  child: Icon(Icons.groups_outlined, color: accentColor),
                ),
                title: Text(
                  '@所有人 (${allIds.length})',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  '群内通知遵守个人偏好；也可另外明确提及成员或 Agent。',
                  style: TextStyle(fontSize: 10, color: mutedColor),
                ),
              ),
            const Divider(height: 15),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '会话内成员',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: people
                    .map(
                      (p) => CheckboxListTile(
                        key: ValueKey('mention-person-${personId(p)}'),
                        value: _selected.contains(personId(p)),
                        onChanged: (value) => setState(() {
                          value == true
                              ? _selected.add(personId(p))
                              : _selected.remove(personId(p));
                        }),
                        secondary: PersonAvatar(
                          name: officeDisplayName(p),
                          agent: p['kind'] == 'agent',
                          size: 34,
                        ),
                        title: Text(
                          officeDisplayName(p),
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          p['kind'] == 'agent' ? 'Agent · 共同参与的工作伙伴' : '工作成员',
                          style: const TextStyle(
                            fontSize: 10,
                            color: mutedColor,
                          ),
                        ),
                        controlAffinity: ListTileControlAffinity.trailing,
                      ),
                    )
                    .toList(),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_mentionAll ? '@所有人 · ' : ''}明确提及 ${_selected.length} 位',
                      style: const TextStyle(fontSize: 12, color: mutedColor),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      OfficeMentionSelection(
                        selectedIds: _selected,
                        mentionAll: widget.group && _mentionAll,
                      ),
                    ),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return widget.mobile
        ? Dialog.fullscreen(child: body)
        : Dialog(
            alignment: Alignment.bottomCenter,
            insetPadding: const EdgeInsets.fromLTRB(28, 28, 28, 145),
            child: SizedBox(width: 480, height: 470, child: body),
          );
  }
}
