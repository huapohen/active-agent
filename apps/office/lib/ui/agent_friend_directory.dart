import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_theme.dart';
import 'professional_identity.dart';

String agentFriendOrganization(Json person) =>
    str(person['organization_id'], str(person['organization_name'])).trim();
String agentFriendDepartment(Json person) =>
    str(person['department_id'], str(person['department_name'])).trim();
String agentFriendCategory(Json person) =>
    str(person['category_id'], str(person['category_name'])).trim();

class AgentFriendFilters {
  const AgentFriendFilters({
    this.organization,
    this.department,
    this.profession,
    this.jobTitle,
    this.category,
  });
  final String? organization, department, profession, jobTitle, category;
  bool get isEmpty =>
      organization == null && profession == null && category == null;

  bool matches(Json person, {String query = '', String? except}) =>
      professionalSearchText(person).contains(query.trim().toLowerCase()) &&
      (except == 'organization' ||
          ((organization == null ||
                  agentFriendOrganization(person) == organization) &&
              (department == null ||
                  agentFriendDepartment(person) == department))) &&
      (except == 'profession' ||
          ((profession == null ||
                  str(person['profession']).trim() == profession) &&
              (jobTitle == null ||
                  str(person['job_title']).trim() == jobTitle))) &&
      (except == 'category' ||
          category == null ||
          agentFriendCategory(person) == category);
}

class AgentFriendGroup {
  AgentFriendGroup(this.id, this.name);
  final String id, name;
  int count = 0;
  final Map<String, AgentFriendGroup> children = {};
}

/// These are groups of visible friends' actual appointment records, not an
/// invented corporate directory. Catalog source organizations are excluded.
List<AgentFriendGroup> agentFriendGroups(
  List<Json> people,
  AgentFriendFilters filters, {
  required String dimension,
  String query = '',
}) {
  final groups = <String, AgentFriendGroup>{};
  for (final person in people) {
    final id = switch (dimension) {
      'organization' => agentFriendOrganization(person),
      'profession' => str(person['profession']).trim(),
      _ => agentFriendCategory(person),
    };
    final name = switch (dimension) {
      'organization' => str(person['organization_name'], id),
      'profession' => id,
      _ => str(person['category_name'], id),
    };
    final empty = switch (dimension) {
      'organization' => '未分配组织',
      'profession' => '未填写职业',
      _ => '未分类',
    };
    final group = groups.putIfAbsent(
      id,
      () => AgentFriendGroup(id, name.isEmpty ? empty : name),
    );
    final matches = filters.matches(person, query: query, except: dimension);
    if (matches) group.count++;
    if (dimension != 'category') {
      final childId = dimension == 'organization'
          ? agentFriendDepartment(person)
          : str(person['job_title']).trim();
      final childName = dimension == 'organization'
          ? str(person['department_name'], childId)
          : childId;
      final child = group.children.putIfAbsent(
        childId,
        () => AgentFriendGroup(
          childId,
          childName.isEmpty
              ? dimension == 'organization'
                    ? '未分配部门'
                    : '未填写职位'
              : childName,
        ),
      );
      if (matches) child.count++;
    }
  }
  final result = groups.values.toList();
  result.sort((a, b) {
    if (a.id.isEmpty != b.id.isEmpty) return a.id.isEmpty ? 1 : -1;
    return a.name.compareTo(b.name);
  });
  return result;
}

class OfficeAgentFriendDirectory extends StatefulWidget {
  const OfficeAgentFriendDirectory({
    super.key,
    required this.state,
    required this.friends,
    required this.others,
    required this.itemBuilder,
    required this.otherBuilder,
    required this.onExploreStore,
  });
  final OfficeState state;
  final List<Json> friends, others;
  final Widget Function(Json person) itemBuilder, otherBuilder;
  final VoidCallback onExploreStore;

  @override
  State<OfficeAgentFriendDirectory> createState() =>
      _OfficeAgentFriendDirectoryState();
}

class _OfficeAgentFriendDirectoryState
    extends State<OfficeAgentFriendDirectory> {
  final _query = TextEditingController();
  final _changes = ValueNotifier<int>(0);
  AgentFriendFilters _filters = const AgentFriendFilters();
  late (OfficeState, int, String, String) _identity;
  BuildContext? _sheetContext;
  (OfficeState, int, String, String) get _currentIdentity => (
    widget.state,
    widget.state.identityGeneration,
    widget.state.endpoint,
    personId(widget.state.me ?? {}),
  );

  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    widget.state.addListener(_stateChanged);
  }

  @override
  void didUpdateWidget(covariant OfficeAgentFriendDirectory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.removeListener(_stateChanged);
      widget.state.addListener(_stateChanged);
    }
    _syncIdentity();
  }

  void _syncIdentity() {
    if (_identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _filters = const AgentFriendFilters();
    _query.clear();
    final sheet = _sheetContext;
    if (sheet != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (sheet.mounted && ModalRoute.of(sheet)?.isCurrent == true) {
          Navigator.pop(sheet);
        }
      });
    }
  }

  void _stateChanged() {
    if (!mounted) return;
    setState(_syncIdentity);
    _changes.value++;
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
    _query.dispose();
    _changes.dispose();
    super.dispose();
  }

  void _select(String dimension, String? id, [String? child]) {
    if (!mounted || _identity != _currentIdentity) return;
    setState(() {
      _filters = AgentFriendFilters(
        organization: dimension == 'organization' ? id : _filters.organization,
        department: dimension == 'organization' ? child : _filters.department,
        profession: dimension == 'profession' ? id : _filters.profession,
        jobTitle: dimension == 'profession' ? child : _filters.jobTitle,
        category: dimension == 'category' ? id : _filters.category,
      );
    });
    _changes.value++;
  }

  void _reset() {
    if (!mounted || _identity != _currentIdentity) return;
    setState(() {
      _filters = const AgentFriendFilters();
      _query.clear();
    });
    _changes.value++;
  }

  Future<void> _showFilters() async {
    final identity = _identity;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        _sheetContext = context;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .78,
            child: ValueListenableBuilder<int>(
              valueListenable: _changes,
              builder: (context, _, _) => identity != _currentIdentity
                  ? const Center(child: Text('工作身份已变化，请重新打开筛选。'))
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  '筛选 Agent 好友',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('完成'),
                              ),
                            ],
                          ),
                        ),
                        Expanded(child: _tree()),
                      ],
                    ),
            ),
          ),
        );
      },
    );
    _sheetContext = null;
  }

  Widget _tree() {
    final identity = _identity;
    return ListView(
      key: const ValueKey('agent-friends-tree'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        ListTile(
          key: const ValueKey('agent-friends-reset-tree'),
          dense: true,
          selected: _filters.isEmpty,
          leading: const Icon(Icons.people_outline, size: 19),
          title: const Text('全部好友'),
          trailing: Text('${widget.friends.length}'),
          onTap: () {
            if (identity == _currentIdentity) _reset();
          },
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 2, 12, 10),
          child: Text(
            '按好友任职信息分组',
            style: TextStyle(fontSize: 10, color: mutedColor),
          ),
        ),
        for (final dimension in ['organization', 'profession', 'category'])
          ExpansionTile(
            key: ValueKey('agent-friends-dimension-$dimension'),
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            title: Text(
              switch (dimension) {
                'organization' => '公司 / 组织',
                'profession' => '职业 / 职位',
                _ => '工作分类',
              },
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            children: [
              for (final group in agentFriendGroups(
                widget.friends,
                _filters,
                dimension: dimension,
                query: _query.text,
              ))
                _group(dimension, group, identity),
            ],
          ),
      ],
    );
  }

  Widget _group(
    String dimension,
    AgentFriendGroup group,
    (OfficeState, int, String, String) identity,
  ) {
    final selected = switch (dimension) {
      'organization' => _filters.organization == group.id,
      'profession' => _filters.profession == group.id,
      _ => _filters.category == group.id,
    };
    final childId = dimension == 'organization'
        ? _filters.department
        : _filters.jobTitle;
    Widget choice(AgentFriendGroup node, {bool child = false}) => ListTile(
      key: ValueKey(
        'agent-filter-$dimension-${Uri.encodeComponent(group.id)}${child ? '/${Uri.encodeComponent(node.id)}' : ''}',
      ),
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.only(left: child ? 28 : 12, right: 10),
      selected:
          selected &&
          (child
              ? childId == node.id
              : childId == null || dimension == 'category'),
      title: Text(
        node.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Text(
        '${node.count}',
        style: const TextStyle(fontSize: 10, color: mutedColor),
      ),
      onTap: () {
        if (identity == _currentIdentity) {
          _select(dimension, group.id, child ? node.id : null);
        }
      },
    );
    if (group.children.isEmpty) return choice(group);
    final children = group.children.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return ExpansionTile(
      key: ValueKey('agent-friends-expand-$dimension-${group.id}'),
      tilePadding: const EdgeInsets.only(left: 8, right: 8),
      initiallyExpanded: selected,
      title: choice(group),
      children: children.map((node) => choice(node, child: true)).toList(),
    );
  }

  Widget _selectionChips() {
    String label(String dimension, String id, String? child) {
      final group = agentFriendGroups(
        widget.friends,
        _filters,
        dimension: dimension,
      ).where((group) => group.id == id).firstOrNull;
      final name = group?.name ?? (id.isEmpty ? '未分配' : id);
      return child == null
          ? name
          : '$name / ${group?.children[child]?.name ?? (child.isEmpty ? '未填写' : child)}';
    }

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final entry in [
          ('organization', _filters.organization, _filters.department),
          ('profession', _filters.profession, _filters.jobTitle),
          ('category', _filters.category, null),
        ])
          if (entry.$2 != null)
            InputChip(
              key: ValueKey('agent-friends-selected-${entry.$1}'),
              label: Text(
                label(entry.$1, entry.$2!, entry.$3),
                style: const TextStyle(fontSize: 10),
              ),
              onDeleted: () => _select(entry.$1, null),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 760;
      final friends = widget.friends
          .where((person) => _filters.matches(person, query: _query.text))
          .toList();
      final others = widget.others
          .where((person) => _filters.matches(person, query: _query.text))
          .toList();
      final filtered = !_filters.isEmpty || _query.text.trim().isNotEmpty;
      final entries = <Widget Function()>[
        if (friends.isEmpty)
          () => EmptyOffice(
            title: filtered ? '没有匹配的 Agent 好友' : '遇见你的下一位工作伙伴',
            subtitle: filtered
                ? '调整搜索或分类，找到需要的工作伙伴。'
                : '从 Agent 商店添加伙伴，或关联现有 Agent 身份。',
            icon: Icons.auto_awesome_outlined,
            action: TextButton(
              onPressed: filtered ? _reset : widget.onExploreStore,
              child: Text(filtered ? '重置筛选' : '探索 Agent 商店'),
            ),
          ),
        for (final person in friends)
          () => KeyedSubtree(
            key: ValueKey('agent-friend-row-${personId(person)}'),
            child: widget.itemBuilder(person),
          ),
        if (others.isNotEmpty) ...[
          () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 15),
            child: Text(
              '工作空间中的其他 Agent',
              style: TextStyle(fontSize: 12, color: mutedColor),
            ),
          ),
          for (final person in others) () => widget.otherBuilder(person),
        ],
      ];
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
            child: Row(
              children: [
                Expanded(
                  child: OfficeSearch(
                    controller: _query,
                    hint: '查找 Agent 好友',
                    onChanged: (_) {
                      setState(() {});
                      _changes.value++;
                    },
                  ),
                ),
                const SizedBox(width: 8),
                if (!desktop)
                  IconButton(
                    key: const ValueKey('agent-friends-open-filters'),
                    tooltip: '筛选 Agent 好友',
                    onPressed: _showFilters,
                    icon: const Icon(Icons.filter_list, size: 20),
                  ),
                TextButton(
                  key: const ValueKey('agent-friends-reset'),
                  onPressed: filtered ? _reset : null,
                  child: const Text('重置'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 9),
            child: Row(
              children: [
                Expanded(child: _selectionChips()),
                Text(
                  '${friends.length} / ${widget.friends.length} 位好友',
                  key: const ValueKey('agent-friends-result-count'),
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (desktop) ...[
                  SizedBox(width: 246, child: _tree()),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: ListView.builder(
                    key: const ValueKey('agent-friends-results'),
                    padding: const EdgeInsets.all(22),
                    itemCount: entries.length,
                    itemBuilder: (context, index) => entries[index](),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
