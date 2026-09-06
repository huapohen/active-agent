import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'agent_autonomy.dart';
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

String _roomIdentity(OfficeState state) =>
    '${state.endpoint}|${personId(state.me ?? {})}|${state.connected}';

/// All actions retain the room and identity that opened this route.
Future<void> showOfficeRoomDetails(
  BuildContext context,
  OfficeState state, {
  required String roomId,
  VoidCallback? onSearch,
  VoidCallback? onDocuments,
  VoidCallback? onTasks,
  VoidCallback? onRecords,
  VoidCallback? onMembers,
  VoidCallback? onChanged,
}) {
  Widget details() => OfficeRoomDetails(
    state: state,
    roomId: roomId,
    onSearch: onSearch,
    onDocuments: onDocuments,
    onTasks: onTasks,
    onRecords: onRecords,
    onMembers: onMembers,
    onChanged: onChanged,
  );
  if (MediaQuery.sizeOf(context).width < 720) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => details(), fullscreenDialog: true),
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭会话详情',
    barrierColor: Colors.black26,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, animation, secondaryAnimation) => Align(
      alignment: Alignment.centerRight,
      child: SizedBox(width: 400, child: details()),
    ),
    transitionBuilder: (_, animation, secondaryAnimation, child) =>
        SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        ),
  );
}

class OfficeRoomDetails extends StatefulWidget {
  const OfficeRoomDetails({
    super.key,
    required this.state,
    required this.roomId,
    this.onSearch,
    this.onDocuments,
    this.onTasks,
    this.onRecords,
    this.onMembers,
    this.onChanged,
  });
  final OfficeState state;
  final String roomId;
  final VoidCallback? onSearch, onDocuments, onTasks, onRecords, onMembers;
  final VoidCallback? onChanged;

  @override
  State<OfficeRoomDetails> createState() => _OfficeRoomDetailsState();
}

class _OfficeRoomDetailsState extends State<OfficeRoomDetails> {
  late final String _identity;
  Json? _detail, _profile, _announcement;
  String? _error, _profileError;
  bool _loading = true, _saving = false, _expired = false;
  int _generation = 0;
  Timer? _refresh;
  String _memberQuery = '';
  String get _path => '/rooms/${Uri.encodeComponent(widget.roomId)}';
  Json get _room => Json.from(_detail?['room'] as Map? ?? {});
  List<Json> get _members => maps(_detail?['members']);
  List<Json> get _visibleMembers => _members
      .where(
        (member) => '${str(member['name'])} ${personId(member)}'
            .toLowerCase()
            .contains(_memberQuery.trim().toLowerCase()),
      )
      .take(_memberQuery.trim().isEmpty ? 8 : _members.length)
      .toList();
  bool get _group => _room['kind'] != 'direct';
  bool get _valid =>
      !_expired &&
      widget.state.connected &&
      _identity == _roomIdentity(widget.state);

  @override
  void initState() {
    super.initState();
    _identity = _roomIdentity(widget.state);
    widget.state.addListener(_stateChanged);
    _load();
  }

  void _stateChanged() {
    if (!_valid) {
      _refresh?.cancel();
      _generation++;
      setState(() {
        _expired = true;
        _detail = _profile = _announcement = null;
      });
      return;
    }
    _refresh?.cancel();
    _refresh = Timer(const Duration(milliseconds: 250), _load);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    widget.state.removeListener(_stateChanged);
    super.dispose();
  }

  bool _accept(int generation) =>
      mounted && _valid && generation == _generation;

  Future<void> _load() async {
    if (!_valid || !mounted) return;
    final generation = ++_generation;
    try {
      final detail = await widget.state.officeRequest(_path);
      if (!_accept(generation)) return;
      setState(() {
        _detail = detail;
        _error = null;
        _loading = false;
      });
      // Direct conversations have no group profile/announcement protocol.
      if ((detail['room'] as Map?)?['kind'] == 'direct') return;
      try {
        final results = await Future.wait([
          widget.state.officeRequest('$_path/profile'),
          widget.state.officeRequest('$_path/announcement'),
        ]);
        if (!_accept(generation)) return;
        setState(() {
          _profile = results[0];
          _announcement = results[1];
          _profileError = null;
        });
      } catch (error) {
        if (!_accept(generation)) return;
        if (error is OfficeException &&
            [401, 403, 404].contains(error.status)) {
          rethrow;
        }
        setState(() {
          _profile = _announcement = null;
          _profileError = friendlyError(error);
        });
      }
    } catch (error) {
      if (!_accept(generation)) return;
      setState(() {
        _error = friendlyError(error);
        _loading = false;
        // A failed access check must not keep private content on screen.
        if (error is OfficeException &&
            [401, 403, 404].contains(error.status)) {
          _detail = _profile = _announcement = null;
        }
      });
    }
  }

  Future<void> _preference(String key, bool value) async {
    if (!_valid || _saving) return;
    _refresh?.cancel();
    ++_generation;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.state.officeRequest(
        '$_path/preferences',
        method: 'PATCH',
        data: {key: value},
      );
      if (!mounted || !_valid) return;
      if (result['room'] is Map) {
        setState(() => _detail = {...?_detail, 'room': result['room']});
      }
      widget.onChanged?.call();
    } catch (error) {
      if (mounted && _valid) {
        setState(() => _error = friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _navigate(VoidCallback action) {
    if (!_valid) return;
    Navigator.of(context).pop();
    action();
  }

  Future<void> _edit(bool announcement) async {
    final response = announcement ? _announcement : _profile;
    if (!_valid || response == null) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RoomTextEditor(
        state: widget.state,
        roomId: widget.roomId,
        initial: response,
        announcement: announcement,
      ),
    );
    if (!mounted || !_valid || saved != true) return;
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _agent(Json member) async {
    if (!_valid) return;
    final self = personId(widget.state.me ?? {});
    final owner = _members.any(
      (member) => personId(member) == self && member['role'] == 'owner',
    );
    await showAgentAutonomy(
      context,
      widget.state,
      member,
      roomId: widget.roomId,
      canEdit: owner || personId(member) == self,
      roomRevision: (_room['revision'] as num?)?.toInt(),
    );
    if (mounted && _valid) await _load();
  }

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 9),
          child: Text(
            title,
            style: const TextStyle(color: mutedColor, fontSize: 12),
          ),
        ),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    ),
  );

  Widget _link(String title, IconData icon, VoidCallback action) => ListTile(
    dense: true,
    leading: Icon(icon, size: 20),
    title: Text(title),
    trailing: const Icon(Icons.chevron_right, size: 18),
    onTap: () => _navigate(action),
  );

  Widget _toggle(String title, String key, String roomKey, IconData icon) =>
      SwitchListTile(
        key: ValueKey('room-preference-$key'),
        dense: true,
        secondary: Icon(icon, size: 20),
        title: Text(title),
        value: _room[roomKey] == true,
        onChanged: _saving ? null : (value) => _preference(key, value),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff5f6f8),
    appBar: AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      title: Text(
        _detail == null || _group ? '群聊详情' : '会话详情',
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      actions: [
        if (_valid)
          IconButton(
            tooltip: '刷新详情',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        IconButton(
          tooltip: '关闭会话详情',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: !_valid
          ? const Center(child: Text('工作身份已变更，请关闭后重新打开会话详情。'))
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
              children: [
                if (_error != null) BusinessError(_error),
                if (_detail == null)
                  TextButton(onPressed: _load, child: const Text('重新读取')),
                if (_detail != null) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PersonAvatar(
                        name: str(_room['name']),
                        group: _group,
                        size: 48,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              str(_room['name']),
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '${_members.where((m) => m['kind'] != 'agent').length} 位人类 · ${_members.where((m) => m['kind'] == 'agent').length} 位 Agent',
                              style: const TextStyle(
                                fontSize: 12,
                                color: mutedColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  _section('共同成员 · ${_members.length}', [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: '搜索群成员',
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                        onChanged: (value) =>
                            setState(() => _memberQuery = value),
                      ),
                    ),
                    if (_visibleMembers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('没有匹配的成员'),
                      ),
                    for (final member in _visibleMembers)
                      ListTile(
                        dense: true,
                        leading: PersonAvatar(
                          name: str(member['name']),
                          agent: member['kind'] == 'agent',
                          size: 32,
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                str(member['name']),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            IdentityBadge(agent: member['kind'] == 'agent'),
                          ],
                        ),
                        subtitle: Text(
                          member['role'] == 'owner' ? '会话负责人' : '工作成员',
                          style: const TextStyle(fontSize: 10),
                        ),
                        trailing: member['kind'] == 'agent'
                            ? IconButton(
                                tooltip: '${str(member['name'])} · 人格与参与',
                                onPressed: () => _agent(member),
                                icon: const Icon(Icons.tune, size: 18),
                              )
                            : null,
                      ),
                    if (widget.onMembers != null)
                      _link('查看全部成员', Icons.people_outline, widget.onMembers!),
                  ]),
                  if (_group)
                    _section('群资料', [
                      ListTile(
                        title: const Text('群名称与介绍'),
                        subtitle: Text(
                          str(
                            (_profile?['profile'] as Map?)?['description'] ??
                                _room['description'],
                            '尚未填写群介绍',
                          ),
                        ),
                        trailing:
                            (_profile?['permissions'] as Map?)?['can_edit'] ==
                                true
                            ? IconButton(
                                tooltip: '编辑群资料',
                                onPressed: () => _edit(false),
                                icon: const Icon(Icons.edit_outlined, size: 18),
                              )
                            : null,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        title: const Text('群公告'),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            str(
                                  (_announcement?['announcement']
                                      as Map?)?['content'],
                                ).isEmpty
                                ? '暂无群公告'
                                : str(
                                    (_announcement?['announcement']
                                        as Map?)?['content'],
                                  ),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        trailing:
                            (_announcement?['permissions']
                                    as Map?)?['can_edit'] ==
                                true
                            ? IconButton(
                                tooltip: '编辑群公告',
                                onPressed: () => _edit(true),
                                icon: const Icon(Icons.edit_outlined, size: 18),
                              )
                            : null,
                        onTap: _announcement == null
                            ? null
                            : () => _viewAnnouncement(),
                      ),
                      if (_profileError != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: BusinessError(_profileError),
                        ),
                    ]),
                  if ([
                    widget.onSearch,
                    widget.onDocuments,
                    widget.onTasks,
                    widget.onRecords,
                  ].any((action) => action != null))
                    _section('会话内容', [
                      if (widget.onSearch != null)
                        _link('查找聊天内容', Icons.search, widget.onSearch!),
                      if (widget.onDocuments != null)
                        _link(
                          _group ? '群文档' : '会话文档',
                          Icons.description_outlined,
                          widget.onDocuments!,
                        ),
                      if (widget.onTasks != null)
                        _link('任务', Icons.task_alt, widget.onTasks!),
                      if (widget.onRecords != null)
                        _link('工作记录', Icons.history, widget.onRecords!),
                    ]),
                  _section('个人会话设置', [
                    _toggle(
                      '置顶聊天',
                      'pinned',
                      'is_pinned',
                      Icons.push_pin_outlined,
                    ),
                    _toggle(
                      '收藏会话',
                      'favorite',
                      'is_favorite',
                      Icons.star_border,
                    ),
                    _toggle(
                      '消息免打扰',
                      'muted',
                      'muted',
                      Icons.notifications_off_outlined,
                    ),
                  ]),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 10, 4, 0),
                    child: Text(
                      '个人设置仅对当前工作身份生效。',
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ListTile(
                    title: const Text('会话 ID', style: TextStyle(fontSize: 12)),
                    subtitle: Text(
                      widget.roomId,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      tooltip: '复制会话 ID',
                      icon: const Icon(Icons.copy_outlined, size: 17),
                      onPressed: () async {
                        if (!_valid) return;
                        await Clipboard.setData(
                          ClipboardData(text: widget.roomId),
                        );
                        if (context.mounted && _valid) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('会话 ID 已复制')),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
    ),
  );

  Future<void> _viewAnnouncement() => showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: widget.state,
      builder: (_, _) => AlertDialog(
        title: const Text('群公告'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              !_valid
                  ? '工作身份已变更，请重新打开。'
                  : str(
                      (_announcement?['announcement'] as Map?)?['content'],
                      '暂无群公告',
                    ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}

class _RoomTextEditor extends StatefulWidget {
  const _RoomTextEditor({
    required this.state,
    required this.roomId,
    required this.initial,
    required this.announcement,
  });
  final OfficeState state;
  final String roomId;
  final Json initial;
  final bool announcement;
  @override
  State<_RoomTextEditor> createState() => _RoomTextEditorState();
}

class _RoomTextEditorState extends State<_RoomTextEditor> {
  late final String _identity;
  late final TextEditingController _name, _text;
  late int _revision;
  bool _busy = false, _conflict = false, _expired = false, _canEdit = false;
  String? _error;
  Json? _latest;
  final _form = GlobalKey<FormState>();
  String get _key => widget.announcement ? 'announcement' : 'profile';
  String get _path => '/rooms/${Uri.encodeComponent(widget.roomId)}/$_key';
  bool get _valid =>
      !_expired &&
      widget.state.connected &&
      _identity == _roomIdentity(widget.state);

  @override
  void initState() {
    super.initState();
    _identity = _roomIdentity(widget.state);
    final value = Json.from(widget.initial[_key] as Map);
    _revision = (value['revision'] as num).toInt();
    _name = TextEditingController(text: str(value['name']));
    _text = TextEditingController(
      text: str(value[widget.announcement ? 'content' : 'description']),
    );
    _canEdit = (widget.initial['permissions'] as Map?)?['can_edit'] == true;
    widget.state.addListener(_stateChanged);
  }

  void _stateChanged() {
    if (!_valid && mounted) setState(() => _expired = true);
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_valid ||
        !_canEdit ||
        _busy ||
        _conflict ||
        !_form.currentState!.validate()) {
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
        data: {
          'base_revision': _revision,
          if (!widget.announcement) 'name': _name.text.trim(),
          widget.announcement ? 'content' : 'description': _text.text,
        },
      );
      if (mounted && _valid) Navigator.pop(context, true);
    } catch (error) {
      if (mounted && _valid) {
        setState(() {
          _error = friendlyError(error);
          _conflict = error is OfficeException && error.status == 409;
          if (error is OfficeException &&
              [401, 403, 404].contains(error.status)) {
            _canEdit = false;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readLatest() async {
    if (!_valid || _busy) return;
    setState(() => _busy = true);
    try {
      final latest = await widget.state.officeRequest(_path);
      if (mounted && _valid) {
        setState(() {
          _latest = latest;
          _canEdit = (latest['permissions'] as Map?)?['can_edit'] == true;
        });
      }
    } catch (error) {
      if (mounted && _valid) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _adopt() {
    if (!_valid || !_canEdit || _latest == null) return;
    setState(() {
      _revision = ((_latest![_key] as Map)['revision'] as num).toInt();
      _latest = null;
      _conflict = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.announcement ? '编辑群公告' : '编辑群资料'),
    content: SizedBox(
      width: 520,
      child: !_valid
          ? const Text('工作身份已变更，旧身份的草稿已锁定。请关闭后重新打开。')
          : SingleChildScrollView(
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!widget.announcement) ...[
                      TextFormField(
                        controller: _name,
                        enabled: !_busy && _canEdit,
                        decoration: const InputDecoration(labelText: '群名称'),
                        maxLength: 100,
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '请填写群名称'
                            : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _text,
                      enabled: !_busy && _canEdit,
                      minLines: widget.announcement ? 5 : 3,
                      maxLines: widget.announcement ? 12 : 6,
                      maxLength: widget.announcement ? 20000 : 4000,
                      decoration: InputDecoration(
                        labelText: widget.announcement ? '公告内容' : '群介绍',
                        alignLabelWithHint: true,
                      ),
                    ),
                    if (widget.announcement)
                      const Text(
                        '留空并保存可清空群公告。',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    if (!_canEdit) const Text('当前工作身份没有编辑权限。'),
                    BusinessError(_error),
                    if (_conflict) ...[
                      const Text('内容已被更新。你的草稿已保留，请读取最新内容并核对后再保存。'),
                      TextButton(
                        onPressed: _busy ? null : _readLatest,
                        child: const Text('读取最新内容'),
                      ),
                    ],
                    if (_latest != null) ...[
                      const Divider(),
                      const Text(
                        '服务端最新内容',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (!widget.announcement)
                        Text(str((_latest![_key] as Map)['name'])),
                      SelectableText(
                        str(
                          (_latest![_key] as Map)[widget.announcement
                              ? 'content'
                              : 'description'],
                        ),
                      ),
                      TextButton(
                        onPressed: _busy || !_canEdit ? null : _adopt,
                        child: const Text('采用最新版本号，保留我的草稿'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: !_valid || _busy || _conflict || !_canEdit ? null : _save,
        child: Text(_busy ? '保存中…' : '保存'),
      ),
    ],
  );
}
