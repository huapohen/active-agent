import 'package:flutter/material.dart';

import 'office_theme.dart';

class OfficeMentionPicker extends StatefulWidget {
  const OfficeMentionPicker({
    super.key,
    required this.people,
    required this.selected,
    required this.mobile,
    required this.group,
  });
  final List<Json> people;
  final List<String> selected;
  final bool mobile, group;
  @override
  State<OfficeMentionPicker> createState() => _OfficeMentionPickerState();
}

class _OfficeMentionPickerState extends State<OfficeMentionPicker> {
  late final _selected = widget.selected.toSet();
  String _query = '', _kind = 'all';
  @override
  Widget build(BuildContext context) {
    final allIds = widget.people.map(personId).toSet();
    final everyone = allIds.isNotEmpty && _selected.containsAll(allIds);
    final people =
        widget.people
            .where(
              (p) =>
                  (_kind == 'all' || p['kind'] == _kind) &&
                  str(p['name']).toLowerCase().contains(_query.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => str(a['name']).compareTo(str(b['name'])));
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
                value: everyone,
                onChanged: (value) => setState(() {
                  value == true
                      ? _selected.addAll(allIds)
                      : _selected.removeAll(allIds);
                }),
                secondary: const CircleAvatar(
                  backgroundColor: selectedColor,
                  child: Icon(Icons.groups_outlined, color: accentColor),
                ),
                title: Text(
                  '所有人 (${allIds.length})',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  '提醒会话中全部成员与 Agent',
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
                        value: _selected.contains(personId(p)),
                        onChanged: (value) => setState(() {
                          value == true
                              ? _selected.add(personId(p))
                              : _selected.remove(personId(p));
                        }),
                        secondary: PersonAvatar(
                          name: str(p['name']),
                          agent: p['kind'] == 'agent',
                          size: 34,
                        ),
                        title: Text(
                          str(p['name']),
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
                      '已选择 ${_selected.length} 位',
                      style: const TextStyle(fontSize: 12, color: mutedColor),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _selected.toList()),
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
