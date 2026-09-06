import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'agent_autonomy.dart';
import 'business_widgets.dart';
import 'companion_identity.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

Future<void> showAgentPersonality(
  BuildContext context,
  OfficeState state,
  Json person,
) async {
  final selection = await showDialog<Json>(
    context: context,
    builder: (_) => _AgentPersonalityRoom(state: state, person: person),
  );
  if (selection == null || !context.mounted) return;
  await showAgentAutonomy(
    context,
    state,
    Json.from(selection['member']),
    roomId: str(selection['room_id']),
    roomRevision: (selection['revision'] as num?)?.toInt(),
    canEdit: selection['can_edit'] == true,
  );
}

class _AgentPersonalityRoom extends StatefulWidget {
  const _AgentPersonalityRoom({required this.state, required this.person});
  final OfficeState state;
  final Json person;
  @override
  State<_AgentPersonalityRoom> createState() => _AgentPersonalityRoomState();
}

class _AgentPersonalityRoomState extends State<_AgentPersonalityRoom> {
  late String? _room =
      widget.state.rooms.any(
        (room) => room['id'] == widget.state.selectedRoomId,
      )
      ? widget.state.selectedRoomId
      : widget.state.rooms.firstOrNull?['id'] as String?;
  Json? _detail;
  String? _error;
  bool _loading = false;
  int _load = 0;
  Json? get member =>
      maps(_detail?['members'])
          .where((item) => personId(item) == personId(widget.person))
          .firstOrNull;

  @override
  void initState() {
    super.initState();
    if (_room != null) _readRoom();
  }

  Future<void> _readRoom() async {
    final generation = ++_load;
    setState(() {
      _loading = true;
      _detail = null;
      _error = null;
    });
    try {
      final detail = await widget.state.officeRequest(
        '/rooms/${Uri.encodeComponent(_room!)}',
      );
      if (mounted && generation == _load) setState(() => _detail = detail);
    } catch (error) {
      if (mounted && generation == _load) {
        setState(() => _error = friendlyError(error));
      }
    } finally {
      if (mounted && generation == _load) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${str(widget.person['name'])} · 人格与参与'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '每位 Agent 都具备主动参与能力。先选择一个共同工作会话，配置该会话中的参与方式与动作范围。',
              style: TextStyle(fontSize: 12, height: 1.8, color: mutedColor),
            ),
            const SizedBox(height: 16),
            if (_room == null)
              const Text('先和这位 Agent 发起私聊，或邀请加入工作群。')
            else
              DropdownButtonFormField<String>(
                initialValue: _room,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '工作会话'),
                items: widget.state.rooms
                    .map(
                      (room) => DropdownMenuItem(
                        value: str(room['id']),
                        child: Text(
                          str(room['name']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  setState(() => _room = value);
                  _readRoom();
                },
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 18),
                child: LinearProgressIndicator(),
              )
            else if (_detail != null && member == null)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  '这位 Agent 尚未加入该会话。可以选择其他会话，或先在会话成员中邀请。',
                  style: TextStyle(fontSize: 12, height: 1.8),
                ),
              ),
            BusinessError(_error),
            if (_error != null)
              TextButton(onPressed: _readRoom, child: const Text('重新读取会话')),
            CompanionCapabilities(person: widget.person),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      FilledButton(
        onPressed: member == null || _loading
            ? null
            : () {
                final self = maps(_detail?['members'])
                    .where(
                      (item) =>
                          personId(item) == personId(widget.state.me ?? {}),
                    )
                    .firstOrNull;
                Navigator.pop(context, {
                  'room_id': _room,
                  'revision': (_detail?['room'] as Map?)?['revision'],
                  'member': {...widget.person, ...member!},
                  'can_edit':
                      self?['role'] == 'owner' ||
                      personId(widget.person) ==
                          personId(widget.state.me ?? {}),
                });
              },
        child: const Text('打开会话人格配置'),
      ),
    ],
  );
}
