import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_theme.dart';

class BusinessHeader extends StatelessWidget {
  const BusinessHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 22, 18, 18),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 5),
                Text(
                  subtitle!,
                  style: const TextStyle(fontSize: 11, color: mutedColor),
                ),
              ],
            ],
          ),
        ),
        ...actions,
      ],
    ),
  );
}

class BusinessError extends StatelessWidget {
  const BusinessError(this.message, {super.key});
  final String? message;
  @override
  Widget build(BuildContext context) => message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            message!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        );
}

class BusinessCard extends StatelessWidget {
  const BusinessCard({
    super.key,
    required this.child,
    this.color = Colors.white,
  });
  final Widget child;
  final Color color;
  @override
  Widget build(BuildContext context) => Material(
    color: color,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: borderColor),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

String fullOfficeTime(dynamic value) {
  final date = DateTime.tryParse(str(value))?.toLocal();
  if (date == null) return '—';
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

Future<String?> chooseOfficeRoom(
  BuildContext context,
  OfficeState state,
) async {
  final rooms = officeBusinessRooms(state);
  if (rooms.isEmpty) {
    notifyOffice(context, '请先创建或加入一个工作群。');
    return null;
  }
  final id = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('选择工作会话'),
      children: rooms
          .map(
            (room) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, str(room['id'])),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(str(room['name'])),
              ),
            ),
          )
          .toList(),
    ),
  );
  return id;
}

List<Json> officeBusinessRooms(OfficeState state) =>
    state.libraryRooms.isNotEmpty ? state.libraryRooms : state.rooms;

String officeRoomName(OfficeState state, String? roomId) => str(
  officeBusinessRooms(state)
      .where((r) => r['id'] == roomId)
      .firstOrNull?['name'],
  '工作会话',
);

List<Json> officeRoomPeople(OfficeState state, String roomId) {
  final room = officeBusinessRooms(state)
      .where((r) => r['id'] == roomId)
      .firstOrNull;
  if (room?['members'] is List) return maps(room!['members']);
  if (roomId == state.selectedRoomId) return maps(state.detail?['members']);
  final ids = (room?['member_ids'] as List? ?? []).map(str).toSet();
  return state.principals.where((p) => ids.contains(personId(p))).toList();
}

List<Json> officeRoomDocuments(OfficeState state, String roomId) => state
    .allDocuments
    .where(
      (d) =>
          d['room_id'] == roomId ||
          (d['room_ids'] as List? ?? []).contains(roomId),
    )
    .map((d) => {...d, 'room_id': roomId})
    .toList();

Future<List<String>?> chooseOfficePeople(
  BuildContext context,
  OfficeState state, {
  List<String> selected = const [],
  bool single = false,
  List<Json>? people,
  String title = '选择成员',
}) async {
  final values = selected.toSet();
  var query = '';
  return showDialog<List<String>>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, change) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          height: 370,
          child: Column(
            children: [
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索人或 Agent',
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
                onChanged: (value) => change(() => query = value),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: (people ?? state.principals)
                      .where(
                        (p) =>
                            str(p['name'])
                                .toLowerCase()
                                .contains(query.toLowerCase()),
                      )
                      .map(
                        (p) => Material(
                          color: Colors.transparent,
                          child: CheckboxListTile(
                            value: values.contains(personId(p)),
                            onChanged: (checked) => change(() {
                              if (single) values.clear();
                              checked == true
                                  ? values.add(personId(p))
                                  : values.remove(personId(p));
                            }),
                            contentPadding: EdgeInsets.zero,
                            secondary: PersonAvatar(
                              name: str(p['name']),
                              agent: p['kind'] == 'agent',
                              size: 31,
                            ),
                            title: Text(
                              str(p['name']),
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              p['kind'] == 'agent' ? 'Agent' : '成员',
                              style: const TextStyle(
                                fontSize: 10,
                                color: mutedColor,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, values.toList()),
            child: Text('确定${values.isEmpty ? '' : ' (${values.length})'}'),
          ),
        ],
      ),
    ),
  );
}
