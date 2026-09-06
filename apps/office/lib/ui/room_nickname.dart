import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_theme.dart';

Future<bool?> showOfficeRoomNickname(
  BuildContext context,
  OfficeState state, {
  required String roomId,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _RoomNickname(state: state, roomId: roomId),
);

class _RoomNickname extends StatefulWidget {
  const _RoomNickname({required this.state, required this.roomId});
  final OfficeState state;
  final String roomId;
  @override
  State<_RoomNickname> createState() => _RoomNicknameState();
}

class _RoomNicknameState extends State<_RoomNickname> {
  late final String _identity;
  final _text = TextEditingController();
  int? _revision;
  bool _busy = true, _expired = false, _editable = false, _conflict = false;
  Json? _latest;
  String? _error;
  String _name = '';
  String get _key =>
      '${widget.state.endpoint}|${personId(widget.state.me ?? {})}|${widget.state.connected}';
  String get _path =>
      '/rooms/${Uri.encodeComponent(widget.roomId)}/membership-profile';
  bool get _valid => !_expired && widget.state.connected && _identity == _key;

  @override
  void initState() {
    super.initState();
    _identity = _key;
    widget.state.addListener(_identityChanged);
    _read();
  }

  void _identityChanged() {
    if (!_valid && mounted) setState(() => _expired = true);
  }

  @override
  void dispose() {
    widget.state.removeListener(_identityChanged);
    _text.dispose();
    super.dispose();
  }

  Future<void> _read({bool conflict = false}) async {
    if (!_valid) return;
    setState(() => _busy = true);
    try {
      final result = await widget.state.officeRequest(_path);
      if (!mounted || !_valid) return;
      final profile = Json.from(result['membership_profile'] as Map);
      setState(() {
        _editable = (result['permissions'] as Map?)?['can_edit'] == true;
        _name = str(profile['name']);
        if (conflict) {
          _latest = profile;
        } else {
          _revision = (profile['revision'] as num).toInt();
          _text.text = str(profile['nickname']);
          _error = null;
        }
      });
    } catch (error) {
      if (mounted && _valid) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_valid || !_editable || _busy || _conflict || _revision == null) {
      return;
    }
    if (_text.text.trim().runes.length > 40) {
      setState(() => _error = '群昵称最多 40 个字符');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.officeRequest(
        _path,
        method: 'PATCH',
        data: {'nickname': _text.text.trim(), 'base_revision': _revision},
      );
      if (mounted && _valid) Navigator.pop(context, true);
    } catch (error) {
      if (mounted && _valid) {
        setState(() {
          _error = error.toString();
          _conflict = error is OfficeException && error.status == 409;
          if (error is OfficeException &&
              [401, 403, 404].contains(error.status)) {
            _editable = false;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('我在本群的昵称'),
    content: SizedBox(
      width: 440,
      child: !_valid
          ? const Text('工作身份已变更，旧身份的昵称草稿已锁定。')
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_revision == null && _busy)
                    const LinearProgressIndicator(),
                  if (_revision != null) ...[
                    Text(
                      '工作身份：$_name',
                      style: const TextStyle(fontSize: 12, color: mutedColor),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _text,
                      enabled: !_busy && _editable,
                      maxLength: 40,
                      decoration: const InputDecoration(
                        labelText: '群昵称',
                        hintText: '留空恢复工作身份本名',
                      ),
                    ),
                    const Text(
                      '昵称仅用于本群；成员仍可辨认你的工作身份。',
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ],
                  BusinessError(_error),
                  if (_revision == null && !_busy)
                    TextButton(onPressed: _read, child: const Text('重新读取昵称')),
                  if (_conflict) ...[
                    const Text('昵称已被更新，已保留你的输入。请核对最新昵称后再保存。'),
                    TextButton(
                      onPressed: _busy ? null : () => _read(conflict: true),
                      child: const Text('读取最新昵称'),
                    ),
                  ],
                  if (_latest != null) ...[
                    Text(
                      '最新昵称：${str(_latest!['nickname']).isEmpty ? str(_latest!['name']) : str(_latest!['nickname'])}',
                    ),
                    TextButton(
                      onPressed: _busy || !_editable
                          ? null
                          : () => setState(() {
                              _revision = (_latest!['revision'] as num).toInt();
                              _latest = null;
                              _conflict = false;
                              _error = null;
                            }),
                      child: const Text('采用最新版本号，保留我的昵称'),
                    ),
                  ],
                ],
              ),
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed:
            !_valid || !_editable || _busy || _conflict || _revision == null
            ? null
            : _save,
        child: Text(_busy ? '处理中…' : '保存昵称'),
      ),
    ],
  );
}
