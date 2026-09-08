import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart';
import 'agent_catalog.dart';
import 'professional_identity.dart';
import 'office_theme.dart';
import 'companion_identity.dart';
import 'agent_personality.dart';
import 'agent_friend_directory.dart';

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
  List<Json> get _agentFriends => [
    ...s.agents.where((agent) => agent['system_agent_key'] == 'activate-agent'),
    ...s.agents.where(
      (agent) => agent['system_agent_key'] == 'desktop-companion',
    ),
    ...s.agents.where(
      (agent) => ![
        'activate-agent',
        'desktop-companion',
      ].contains(agent['system_agent_key']),
    ),
  ];
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
                ? _agentFriends
                : (_directory ? s.principals : s.contacts)
                      .where((p) => p['kind'] == 'human')
                      .toList())
            .where(
              (p) => professionalSearchText(p).contains(_query.toLowerCase()),
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
                      widget.agent ? '你的工作伙伴，共同参与、主动推进。' : '找到工作伙伴，开始一次讨论。',
                      style: TextStyle(
                        fontSize: officeFontSize(
                          context,
                          desktop: 11,
                          mobile: 14,
                        ),
                        color: mutedColor,
                      ),
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
                    style: TextStyle(
                      fontSize: officeFontSize(
                        context,
                        desktop: 12,
                        mobile: 14,
                      ),
                    ),
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
                  label: Text(
                    'Agent 好友',
                    style: TextStyle(
                      fontSize: officeFontSize(
                        context,
                        desktop: 11,
                        mobile: 14,
                      ),
                    ),
                  ),
                  selected: !_store,
                  onSelected: (_) => setState(() => _store = false),
                  side: BorderSide.none,
                  showCheckmark: false,
                ),
                const SizedBox(width: 9),
                ChoiceChip(
                  label: Text(
                    'Agent 商店',
                    style: TextStyle(
                      fontSize: officeFontSize(
                        context,
                        desktop: 11,
                        mobile: 14,
                      ),
                    ),
                  ),
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
                  label: Text(
                    '我的联系人',
                    style: TextStyle(
                      fontSize: officeFontSize(
                        context,
                        desktop: 11,
                        mobile: 14,
                      ),
                    ),
                  ),
                  selected: !_directory,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _directory = false),
                ),
                ChoiceChip(
                  label: Text(
                    '工作空间成员',
                    style: TextStyle(
                      fontSize: officeFontSize(
                        context,
                        desktop: 11,
                        mobile: 14,
                      ),
                    ),
                  ),
                  selected: _directory,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _directory = true),
                ),
              ],
            ),
          ),
        if (!_store && !widget.agent)
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
              ? AgentCatalog(
                  state: s,
                  onInstalled: () => setState(() => _store = false),
                )
              : widget.agent
              ? OfficeAgentFriendDirectory(
                  state: s,
                  friends: _agentFriends,
                  others: available,
                  itemBuilder: _person,
                  otherBuilder: _otherAgent,
                  onExploreStore: () => setState(() => _store = true),
                )
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
                  ],
                ),
        ),
      ],
    );
  }

  Widget _otherAgent(Json person) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: PersonAvatar(name: str(person['name']), agent: true),
    title: Text(
      str(person['name']),
      style: TextStyle(
        fontSize: officeFontSize(context, desktop: 13, mobile: 17),
      ),
    ),
    trailing: TextButton(
      onPressed: _busy.contains(personId(person))
          ? null
          : () => _run(personId(person), () => s.addAgent(personId(person))),
      child: const Text('添加好友'),
    ),
  );

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
          if (isOfficeCompanion(p))
            CompanionAvatar(person: p, size: 41)
          else
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
                        style: TextStyle(
                          fontSize: officeFontSize(
                            context,
                            desktop: 13,
                            mobile: 17,
                          ),
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
                    fontSize: officeFontSize(context, desktop: 10, mobile: 14),
                    color: online ? const Color(0xff34a575) : mutedColor,
                  ),
                ),
                ProfessionalIdentity(person: p),
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
              child: Text(
                '发消息',
                style: TextStyle(
                  fontSize: officeFontSize(context, desktop: 11, mobile: 14),
                ),
              ),
            ),
          if (canAddContact || canInvite || p['kind'] == 'agent')
            PopupMenuButton<String>(
              tooltip: '成员操作',
              iconSize: 18,
              onSelected: (action) => _run(id, () async {
                if (action == 'contact') {
                  await s.addContact(id);
                  if (mounted) notifyOffice(context, '已添加联系人');
                } else if (action == 'personality') {
                  await showAgentPersonality(context, s, p);
                } else {
                  await s.invite(id);
                  if (mounted) notifyOffice(context, '已邀请到当前工作群');
                }
              }),
              itemBuilder: (_) => [
                if (p['kind'] == 'agent')
                  const PopupMenuItem(
                    value: 'personality',
                    child: Text('人格与参与'),
                  ),
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
}
