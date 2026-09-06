import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficePeople extends StatefulWidget {
  const OfficePeople({
    super.key,
    required this.state,
    required this.agent,
    required this.onConversation,
    this.initialStore = false,
  });
  final OfficeState state;
  final bool agent;
  final bool initialStore;
  final VoidCallback onConversation;
  @override
  State<OfficePeople> createState() => _OfficePeopleState();
}

class _OfficePeopleState extends State<OfficePeople> {
  String _query = '';
  late bool _store = widget.initialStore;
  bool _directory = false;
  final Set<String> _busy = {};
  OfficeState get s => widget.state;
  Future<void> _run(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await action();
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final people =
        (widget.agent
                ? s.agents
                : (_directory ? s.principals : s.contacts)
                      .where((p) => p['kind'] == 'human')
                      .toList())
            .where(
              (p) =>
                  str(p['name']).toLowerCase().contains(_query.toLowerCase()),
            )
            .toList();
    final available = s.principals
        .where(
          (p) =>
              p['kind'] == 'agent' &&
              !s.agents.any((a) => personId(a) == personId(p)),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(25, 23, 25, 18),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.agent ? 'Agent' : '通讯录',
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.agent ? '你的工作伙伴，同席参与、主动推进。' : '找到工作伙伴，开始一次讨论。',
                      style: const TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ],
                ),
              ),
              if (widget.agent)
                OutlinedButton.icon(
                  onPressed: () => setState(() => _store = !_store),
                  icon: Icon(
                    _store ? Icons.people_outline : Icons.storefront_outlined,
                    size: 17,
                  ),
                  label: Text(
                    _store ? 'Agent 好友' : 'Agent 商店',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        if (widget.agent)
          Padding(
            padding: const EdgeInsets.fromLTRB(25, 0, 25, 14),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Agent 好友', style: TextStyle(fontSize: 11)),
                  selected: !_store,
                  onSelected: (_) => setState(() => _store = false),
                  side: BorderSide.none,
                  showCheckmark: false,
                ),
                const SizedBox(width: 9),
                ChoiceChip(
                  label: const Text('Agent 商店', style: TextStyle(fontSize: 11)),
                  selected: _store,
                  onSelected: (_) => setState(() => _store = true),
                  side: BorderSide.none,
                  showCheckmark: false,
                ),
              ],
            ),
          ),
        if (!widget.agent)
          Padding(
            padding: const EdgeInsets.fromLTRB(25, 0, 25, 14),
            child: Wrap(
              spacing: 9,
              children: [
                ChoiceChip(
                  label: const Text('我的联系人', style: TextStyle(fontSize: 11)),
                  selected: !_directory,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _directory = false),
                ),
                ChoiceChip(
                  label: const Text('工作空间成员', style: TextStyle(fontSize: 11)),
                  selected: _directory,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _directory = true),
                ),
              ],
            ),
          ),
        if (!_store)
          Padding(
            padding: const EdgeInsets.fromLTRB(25, 0, 25, 14),
            child: OfficeSearch(
              hint: widget.agent ? '查找 Agent 好友' : '搜索工作成员',
              onChanged: (q) => setState(() => _query = q),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _store && widget.agent
              ? _catalog()
              : ListView(
                  padding: const EdgeInsets.all(22),
                  children: [
                    if (people.isEmpty)
                      EmptyOffice(
                        title: widget.agent
                            ? '遇见你的下一位工作伙伴'
                            : _directory
                            ? '还没有其他工作成员'
                            : '你的联系人',
                        subtitle: widget.agent
                            ? '从 Agent 商店添加伙伴，或关联现有 Agent 身份。'
                            : _directory
                            ? '工作空间管理员创建身份后，成员会出现在这里。'
                            : '在工作空间成员中选择伙伴，添加到联系人。',
                        icon: widget.agent
                            ? Icons.auto_awesome_outlined
                            : Icons.people_outline,
                        action: widget.agent
                            ? TextButton(
                                onPressed: () => setState(() => _store = true),
                                child: const Text('探索 Agent 商店'),
                              )
                            : null,
                      ),
                    ...people.map((p) => _person(p)),
                    if (widget.agent && available.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      const Text(
                        '工作空间中的其他 Agent',
                        style: TextStyle(fontSize: 12, color: mutedColor),
                      ),
                      const SizedBox(height: 12),
                      ...available.map(
                        (p) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: PersonAvatar(
                            name: str(p['name']),
                            agent: true,
                          ),
                          title: Text(
                            str(p['name']),
                            style: const TextStyle(fontSize: 13),
                          ),
                          trailing: TextButton(
                            onPressed: _busy.contains(personId(p))
                                ? null
                                : () => _run(
                                    personId(p),
                                    () => s.addAgent(personId(p)),
                                  ),
                            child: const Text('添加好友'),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _person(Json p) {
    final id = personId(p), self = id == personId(s.me ?? {});
    final presence = p['presence'] is Map ? p['presence'] as Map : {};
    final canAddContact =
        !self &&
        p['kind'] != 'agent' &&
        !s.contacts.any((c) => personId(c) == id);
    final canInvite =
        !self &&
        s.selectedRoomId != null &&
        (s.detail?['room'] as Map?)?['kind'] != 'direct';
    final online = presence['status'] == 'online';
    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          PersonAvatar(
            name: str(p['name']),
            agent: p['kind'] == 'agent',
            size: 41,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${str(p['name'])}${self ? '（你）' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IdentityBadge(agent: p['kind'] == 'agent'),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  online
                      ? '在线'
                      : p['kind'] == 'agent'
                      ? 'Agent 工作身份 · ${p['relationship'] == 'installed' ? '来自 Agent 商店' : '工作伙伴'}'
                      : '独立工作身份',
                  style: TextStyle(
                    fontSize: 10,
                    color: online ? const Color(0xff34a575) : mutedColor,
                  ),
                ),
              ],
            ),
          ),
          if (!self)
            FilledButton(
              onPressed: _busy.contains(id)
                  ? null
                  : () => _run(id, () async {
                      await s.openDirect(id);
                      widget.onConversation();
                    }),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
              ),
              child: const Text('发消息', style: TextStyle(fontSize: 11)),
            ),
          if (canAddContact || canInvite)
            PopupMenuButton<String>(
              tooltip: '成员操作',
              iconSize: 18,
              onSelected: (action) => _run(id, () async {
                if (action == 'contact') {
                  await s.addContact(id);
                  if (mounted) notifyOffice(context, '已添加联系人');
                } else {
                  await s.invite(id);
                  if (mounted) notifyOffice(context, '已邀请到当前工作群');
                }
              }),
              itemBuilder: (_) => [
                if (canAddContact)
                  const PopupMenuItem(value: 'contact', child: Text('添加联系人')),
                if (canInvite)
                  const PopupMenuItem(value: 'invite', child: Text('邀请到当前工作群')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _catalog() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xffedf2ff), Color(0xfff4f0fe)],
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '为工作，找到合适的 Agent',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 10),
            Text(
              '添加为好友，开始私聊，或邀请加入项目工作群。\nAgent 通过原生协议使用整个办公空间，与人共享相同的工作能力。',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xff8a92a7),
                height: 1.9,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const Text(
        '工作空间提供的 Agent',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 15),
      if (s.catalog.isEmpty)
        const Text(
          '商店暂时没有可添加的 Agent。',
          style: TextStyle(fontSize: 12, color: mutedColor),
        ),
      ...s.catalog.map((a) {
        final id = str(a['id']);
        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PersonAvatar(name: str(a['name']), agent: true, size: 44),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          str(a['name']),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '原生 Agent · 独立工作身份',
                          style: TextStyle(fontSize: 10, color: mutedColor),
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    onPressed: _busy.contains(id)
                        ? null
                        : () => _run(id, () async {
                            await s.installAgent(id);
                            if (mounted) {
                              notifyOffice(context, '已添加为 Agent 好友');
                              setState(() => _store = false);
                            }
                          }),
                    child: Text(
                      _busy.contains(id) ? '正在添加' : '添加好友',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              Text(
                str(a['description']),
                style: const TextStyle(
                  fontSize: 12,
                  color: mutedColor,
                  height: 1.8,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 5,
                children: (a['skills'] as List? ?? [])
                    .map(
                      (skill) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xfff3f5fa),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          str(skill),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xff7d89a7),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              if (a['instructions'] != null)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    '查看工作约定',
                    style: TextStyle(fontSize: 11, color: accentColor),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        str(a['instructions']),
                        style: const TextStyle(
                          fontSize: 11,
                          color: mutedColor,
                          height: 1.8,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      }),
    ],
  );
}
