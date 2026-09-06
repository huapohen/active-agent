import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

Future<void> showAgentCollaboration(
  BuildContext context,
  OfficeState state, {
  required void Function(List<String>) onMention,
  required VoidCallback onRecords,
  VoidCallback? onStore,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: Colors.white,
  constraints: const BoxConstraints(maxWidth: 650),
  builder: (context) => _AgentCollaboration(
    state: state,
    onMention: onMention,
    onRecords: onRecords,
    onStore: onStore,
  ),
);

class _AgentCollaboration extends StatefulWidget {
  const _AgentCollaboration({
    required this.state,
    required this.onMention,
    required this.onRecords,
    this.onStore,
  });
  final OfficeState state;
  final void Function(List<String>) onMention;
  final VoidCallback onRecords;
  final VoidCallback? onStore;
  @override
  State<_AgentCollaboration> createState() => _AgentCollaborationState();
}

class _AgentCollaborationState extends State<_AgentCollaboration> {
  bool _busy = false;
  String? _error;
  OfficeState get s => widget.state;
  Future<void> _add(bool direct) async {
    if (direct) {
      Navigator.pop(context);
      await OfficeDialogs.createRoom(
        context,
        s,
        memberIds: maps(s.detail?['members']).map(personId).toList(),
      );
      return;
    }
    final ids = await chooseOfficePeople(
      context,
      s,
      title: '添加 Agent 到当前群',
      people: s.principals
          .where(
            (p) =>
                p['kind'] == 'agent' &&
                !maps(s.detail?['members'])
                    .any((m) => personId(m) == personId(p)),
          )
          .toList(),
    );
    if (ids == null || ids.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      for (final id in ids) {
        await s.invite(id);
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: s,
    builder: (context, _) {
      final members = maps(s.detail?['members']),
          agents = maps(s.detail?['members'])
              .where((p) => p['kind'] == 'agent')
              .toList();
      final self = members
          .where((p) => personId(p) == personId(s.me ?? {}))
          .firstOrNull;
      final owner = self?['role'] == 'owner',
          direct = (s.detail?['room'] as Map?)?['kind'] == 'direct';
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 17, 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome_outlined,
                      color: accentColor,
                      size: 23,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Agent 协作',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭 Agent 协作',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  direct ? '在当前私聊中共同工作，或邀请伙伴组成协作群。' : 'Agent 与成员共用文档、任务和工作上下文。',
                  style: const TextStyle(
                    fontSize: 11,
                    color: mutedColor,
                    height: 1.7,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: [
                    if (direct || owner)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _add(direct),
                        icon: const Icon(Icons.person_add_alt, size: 16),
                        label: Text(direct ? '创建混合协作群' : '添加 Agent'),
                      ),
                    if (widget.onStore != null)
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onStore!();
                        },
                        icon: const Icon(Icons.storefront_outlined, size: 16),
                        label: const Text('Agent 商店'),
                      ),
                    OutlinedButton.icon(
                      onPressed: s.moduleAvailable('tasks')
                          ? () => OfficeDialogs.task(context, s)
                          : null,
                      icon: const Icon(Icons.add_task, size: 16),
                      label: const Text('分派任务'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onRecords();
                      },
                      icon: const Icon(Icons.history, size: 16),
                      label: const Text('工作记录与成果'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 30),
              Expanded(
                child: agents.isEmpty
                    ? const EmptyOffice(
                        title: '当前会话还没有 Agent',
                        subtitle: '从已有伙伴中邀请，或在商店中选择适合的 Agent。',
                        icon: Icons.auto_awesome_outlined,
                      )
                    : ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        children: agents
                            .map(
                              (agent) => Padding(
                                padding: const EdgeInsets.only(bottom: 15),
                                child: BusinessCard(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          PersonAvatar(
                                            name: str(agent['name']),
                                            agent: true,
                                            size: 37,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  str(agent['name']),
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                Text(
                                                  (agent['presence'] is Map &&
                                                          agent['presence']['status'] ==
                                                              'online')
                                                      ? '在线'
                                                      : '离线',
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    color: mutedColor,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () {
                                              widget.onMention([
                                                personId(agent),
                                              ]);
                                              Navigator.pop(context);
                                            },
                                            child: const Text('@ 协作'),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      if (owner ||
                                          personId(agent) ==
                                              personId(s.me ?? {}))
                                        DropdownButtonFormField<String>(
                                          initialValue: str(
                                            agent['mode'],
                                            'mentions',
                                          ),
                                          decoration: const InputDecoration(
                                            labelText: '参与方式',
                                          ),
                                          items: const [
                                            DropdownMenuItem(
                                              value: 'active',
                                              child: Text('主动参与'),
                                            ),
                                            DropdownMenuItem(
                                              value: 'mentions',
                                              child: Text('被提及时参与'),
                                            ),
                                            DropdownMenuItem(
                                              value: 'paused',
                                              child: Text('暂停参与'),
                                            ),
                                          ],
                                          onChanged: _busy
                                              ? null
                                              : (mode) async {
                                                  if (mode == null) return;
                                                  setState(() {
                                                    _busy = true;
                                                    _error = null;
                                                  });
                                                  try {
                                                    await s.setParticipation(
                                                      personId(agent),
                                                      mode,
                                                    );
                                                  } catch (e) {
                                                    if (mounted) {
                                                      setState(
                                                        () => _error =
                                                            friendlyError(e),
                                                      );
                                                    }
                                                  } finally {
                                                    if (mounted) {
                                                      setState(
                                                        () => _busy = false,
                                                      );
                                                    }
                                                  }
                                                },
                                        )
                                      else
                                        Text(
                                          '参与方式：${statusName(agent['mode'])}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: mutedColor,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: BusinessError(_error),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
            ],
          ),
        ),
      );
    },
  );
}
