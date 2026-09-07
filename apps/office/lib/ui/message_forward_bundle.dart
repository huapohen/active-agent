import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'attachments.dart' show fileSizeText;
import 'mentions.dart';
import 'office_dialogs.dart' show friendlyError;
import 'office_emoji.dart';
import 'office_rich_text.dart';
import 'office_theme.dart';

String _roomPath(String id) => '/rooms/${Uri.encodeComponent(id)}';
Json _copy(Json value) => Json.from(jsonDecode(jsonEncode(value)) as Map);
final _pendingBundles = Expando<Map<String, Json>>('pending-forward-bundles');
Widget _previewText(String content) => DefaultTextStyle.merge(
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  child: OfficeEmojiText(
    content: content,
    selectable: false,
    style: const TextStyle(fontSize: 12, color: mutedColor),
  ),
);

Future<T?> _panel<T>(BuildContext context, Widget child) {
  if (MediaQuery.sizeOf(context).width < 720) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final keyboard = MediaQuery.viewInsetsOf(context).bottom;
          final available = (constraints.maxHeight - keyboard).clamp(
            0.0,
            double.infinity,
          );
          return Padding(
            padding: EdgeInsets.only(bottom: keyboard),
            child: SizedBox(
              height: (MediaQuery.sizeOf(context).height * .9).clamp(
                0.0,
                available,
              ),
              child: child,
            ),
          );
        },
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 590,
        height: MediaQuery.sizeOf(context).height * .86,
        child: child,
      ),
    ),
  );
}

/// Returns a validated backend delivery receipt, never synthetic text messages.
Future<Json?> showOfficeMergedForward(
  BuildContext context,
  OfficeState state,
  String sourceRoomId,
  List<Json> messages,
) => _panel<Json>(
  context,
  OfficeMergedForwardComposer(
    state: state,
    sourceRoomId: sourceRoomId,
    messages: messages,
  ),
);

Future<void> showOfficeForwardBundleDetails(
  BuildContext context,
  OfficeState state,
  String roomId,
  Json message,
) async {
  await _panel<void>(
    context,
    OfficeForwardBundleDetails(state: state, roomId: roomId, message: message),
  );
}

Json _verifyBundleResponse(
  Json response, {
  required String roomId,
  required String messageId,
  required String bundleId,
}) {
  final raw = response['bundle'];
  if (response['room_id'] != roomId ||
      response['message_id'] != messageId ||
      raw is! Map ||
      raw['id'] != bundleId ||
      raw['snapshot_policy'] != 'shared_copy' ||
      raw['items'] is! List ||
      raw['message_count'] != (raw['items'] as List).length) {
    throw const FormatException('聊天记录来源校验失败');
  }
  var count = 0;
  void validateItems(List<dynamic> values, int depth) {
    if (values.any((value) => value is! Map)) {
      throw const FormatException('聊天记录条目不完整');
    }
    final items = maps(values);
    if (depth > 3 || (count += items.length) > 200) {
      throw const FormatException('嵌套聊天记录超过显示范围');
    }
    for (final item in items) {
      if (str(item['source_message_id']).isEmpty ||
          item['source_revision'] is! int ||
          (item['source_revision'] as int) < 1 ||
          DateTime.tryParse(str(item['source_at'])) == null ||
          item['author'] is! Map ||
          str((item['author'] as Map)['id']).isEmpty ||
          item['content'] is! String ||
          !['text', 'forward_bundle'].contains(item['kind']) ||
          (item['kind'] == 'text' && item['forward_bundle'] != null) ||
          item['attachments'] is! List) {
        throw const FormatException('聊天记录条目不完整');
      }
      if ((item['attachments'] as List).any((value) => value is! Map)) {
        throw const FormatException('聊天记录附件不完整');
      }
      for (final a in maps(item['attachments'])) {
        if (a['room_id'] != roomId || str(a['id']).isEmpty) {
          throw const FormatException('附件不属于当前会话');
        }
      }
      if (item['kind'] == 'forward_bundle') {
        final nested = item['forward_bundle'];
        if (nested is! Map ||
            nested['items'] is! List ||
            nested['message_count'] != (nested['items'] as List).length) {
          throw const FormatException('嵌套聊天记录不完整');
        }
        validateItems(nested['items'] as List, depth + 1);
      }
    }
  }

  validateItems(raw['items'] as List, 1);
  return _copy(Json.from(raw));
}

/// Copies only an authenticated target-room share. Source-room access is not
/// required: the server returns the bounded snapshot already shared there.
Future<String> officeForwardBundleCopyText(
  OfficeState state,
  String roomId,
  Json message,
) async {
  final identity = (
    state.identityGeneration,
    state.endpoint,
    personId(state.me ?? {}),
  );
  void check() {
    if (state.me == null ||
        identity !=
            (
              state.identityGeneration,
              state.endpoint,
              personId(state.me ?? {}),
            )) {
      throw StateError('工作身份已变更，请重新复制');
    }
  }

  check();
  final messageId = str(message['id']);
  final bundleId = str((message['forward_bundle'] as Map?)?['id']);
  if (roomId.isEmpty ||
      messageId.isEmpty ||
      bundleId.isEmpty ||
      _hiddenCard(message)) {
    throw const FormatException('聊天记录引用不可用');
  }
  final current = await state.officeRequest(
    '${_roomPath(roomId)}/messages/${Uri.encodeComponent(messageId)}',
  );
  check();
  final card = current['message'];
  if (card is! Map ||
      card['id'] != messageId ||
      (card['room_id'] != null && card['room_id'] != roomId) ||
      card['kind'] != 'forward_bundle' ||
      _hiddenCard(Json.from(card)) ||
      (card['forward_bundle'] as Map?)?['id'] != bundleId) {
    throw const FormatException('聊天记录当前状态已变更，请刷新后重试');
  }
  final response = await state.officeRequest(
    '${_roomPath(roomId)}/messages/${Uri.encodeComponent(messageId)}/forward-bundle',
  );
  check();
  final bundle = _verifyBundleResponse(
    response,
    roomId: roomId,
    messageId: messageId,
    bundleId: bundleId,
  );
  final lines = <String>['[${str(bundle['title'], '聊天记录')}]'];
  if (str(card['content']).isNotEmpty) lines.add(str(card['content']));
  void append(List<Json> items, int depth) {
    final indent = '  ' * depth;
    for (final item in items) {
      lines.add(
        '$indent${officeDisplayName(Json.from(item['author'] as Map))} · ${str(item['source_at'])}',
      );
      if (str(item['content']).isNotEmpty) {
        lines.add('$indent${str(item['content'])}');
      }
      for (final attachment in maps(item['attachments'])) {
        lines.add('$indent[附件] ${str(attachment['filename'], '附件')}');
      }
      if (item['forward_bundle'] is Map) {
        final nested = Json.from(item['forward_bundle'] as Map);
        lines.add('$indent[${str(nested['title'], '聊天记录')}]');
        append(maps(nested['items']), depth + 1);
      }
    }
  }

  append(maps(bundle['items']), 0);
  check();
  return lines.join('\n');
}

abstract class _BundleScope<T extends StatefulWidget> extends State<T> {
  OfficeState get office;
  String get scopeRoom;
  late final OfficeState boundOffice;
  late final (int, String, String, String) identity;
  bool expired = false, closed = false;
  int generation = 0;
  bool get current =>
      mounted &&
      !expired &&
      identical(office, boundOffice) &&
      office.me != null &&
      identity ==
          (
            office.identityGeneration,
            office.endpoint,
            personId(office.me ?? {}),
            scopeRoom,
          );
  void clearPrivate();
  void changed() {}
  @override
  void initState() {
    super.initState();
    boundOffice = office;
    identity = (
      office.identityGeneration,
      office.endpoint,
      personId(office.me ?? {}),
      scopeRoom,
    );
    boundOffice.addListener(_changed);
  }

  void invalidate() {
    expired = true;
    generation++;
    clearPrivate();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!current) {
        invalidate();
      } else {
        changed();
      }
    });
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!current) invalidate();
  }

  void close([Object? result]) {
    if (!mounted || closed || ModalRoute.of(context)?.isCurrent != true) return;
    closed = true;
    Navigator.of(context).pop(current ? result : null);
  }

  @override
  void dispose() {
    generation++;
    boundOffice.removeListener(_changed);
    super.dispose();
  }
}

class OfficeMergedForwardComposer extends StatefulWidget {
  const OfficeMergedForwardComposer({
    super.key,
    required this.state,
    required this.sourceRoomId,
    required this.messages,
  });
  final OfficeState state;
  final String sourceRoomId;
  final List<Json> messages;
  @override
  State<OfficeMergedForwardComposer> createState() => _MergedForwardState();
}

class _MergedForwardState extends _BundleScope<OfficeMergedForwardComposer> {
  final _comment = TextEditingController();
  late final List<String> _ids;
  late final String _pendingKey;
  List<Json> _sources = [], _rooms = [];
  final _targets = <String>{};
  final _mentions = <String, String>{};
  String _query = '';
  String? _error, _blocked;
  Json? _pending, _result;
  bool _busy = false, _ready = false, _multiple = false, _unknown = false;
  @override
  OfficeState get office => widget.state;
  @override
  String get scopeRoom => widget.sourceRoomId;
  bool get _editable =>
      current && !_busy && !_unknown && _blocked == null && _result == null;
  bool get _canSend =>
      current &&
      office.connected &&
      !_busy &&
      _blocked == null &&
      _result == null &&
      (_unknown || (_ready && _targets.isNotEmpty));

  @override
  void initState() {
    super.initState();
    _ids = List.unmodifiable(widget.messages.map((m) => str(m['id'])));
    _pendingKey = jsonEncode([
      identity.$1,
      identity.$2,
      identity.$3,
      scopeRoom,
      [..._ids]..sort(),
    ]);
    if (scopeRoom.isEmpty ||
        _ids.isEmpty ||
        _ids.length > 50 ||
        _ids.contains('') ||
        _ids.toSet().length != _ids.length) {
      _blocked = '请选择 1–50 条不同的来源消息。';
    } else {
      final saved = _pendingBundles[office]?[_pendingKey];
      if (saved != null) {
        _pending = _copy(Json.from(saved['payload'] as Map));
        _unknown = true;
        _targets.addAll((_pending!['target_room_ids'] as List).map(str));
        _comment.text = str(saved['comment_draft']);
        _mentions.addAll(
          Map<String, String>.from(saved['mention_labels'] as Map? ?? {}),
        );
        _multiple = _targets.length > 1;
      }
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant OfficeMergedForwardComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(widget.messages.map((m) => str(m['id'])).toList()) !=
        jsonEncode(_ids)) {
      invalidate();
    }
  }

  @override
  void clearPrivate() {
    _sources = [];
    _rooms = [];
    _targets.clear();
    _mentions.clear();
    _comment.clear();
    _result = _pending = null;
    _error = _blocked = null;
    _busy = _ready = _unknown = false;
  }

  @override
  void changed() {
    if (_unknown ||
        _result != null ||
        _sources.isEmpty ||
        (office.detail?['room'] as Map?)?['id'] != scopeRoom) {
      return;
    }
    final latest = maps(office.detail?['messages']);
    for (final source in _sources) {
      final value = latest.where((m) => m['id'] == source['id']).firstOrNull;
      if (value != null &&
          (_restriction(value) != null ||
              value['revision'] != source['revision'])) {
        _sources = [];
        _ready = false;
        generation++;
        _busy = false;
        _error = '来源消息已变化，请刷新并重新核对。';
        break;
      }
    }
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  String? _restriction(Json m) {
    if (m['hidden'] == true) return '来源消息已隐藏，不能合并转发。';
    if (m['retracted_at'] != null) return '来源消息已撤回，不能合并转发。';
    if (m['no_forward'] == true) return '来源消息禁止转发。';
    return null;
  }

  void _checkAttempt(int attempt) {
    if (!current || generation != attempt) {
      throw StateError('工作身份或来源已变更');
    }
  }

  Future<List<Json>> _readSources(int attempt) async {
    final values = <Json>[];
    // Bound concurrent reads rather than opening fifty requests at once.
    for (var start = 0; start < _ids.length; start += 5) {
      _checkAttempt(attempt);
      final ids = _ids.skip(start).take(5).toList();
      final batch = await Future.wait(
        ids.map(
          (id) => office.officeRequest(
            '${_roomPath(scopeRoom)}/messages/${Uri.encodeComponent(id)}',
          ),
        ),
      );
      _checkAttempt(attempt);
      for (var i = 0; i < ids.length; i++) {
        final raw = batch[i]['message'];
        if (raw is! Map ||
            raw['id'] != ids[i] ||
            (raw['room_id'] != null && raw['room_id'] != scopeRoom) ||
            raw['revision'] is! int ||
            (raw['revision'] as int) < 1) {
          throw const FormatException('来源消息返回不完整');
        }
        final value = Json.from(raw);
        final reason = _restriction(value);
        if (reason != null) throw OfficeException(403, reason);
        values.add(value);
      }
    }
    return values;
  }

  Future<List<Json>> _readRooms(int attempt) async {
    _checkAttempt(attempt);
    final response = await office.officeRequest('/rooms');
    _checkAttempt(attempt);
    if (response['rooms'] is! List) throw const FormatException('会话列表返回不完整');
    final rooms = maps(response['rooms']);
    if (rooms.any((r) => str(r['id']).isEmpty)) {
      throw const FormatException('会话标识缺失');
    }
    return rooms;
  }

  Future<Map<String, Json>> _commonMembers(int attempt) async {
    Map<String, Json>? common;
    for (final id in _targets.toList()) {
      _checkAttempt(attempt);
      final detail = await office.officeRequest(_roomPath(id));
      _checkAttempt(attempt);
      if ((detail['room'] as Map?)?['id'] != id || detail['members'] is! List) {
        throw const FormatException('目标会话返回不完整');
      }
      final members = {
        for (final m in maps(detail['members']))
          if (personId(m).isNotEmpty &&
              m['disabled'] != true &&
              m['revoked_at'] == null)
            personId(m): m,
      };
      if (!members.containsKey(identity.$3)) {
        throw OfficeException(403, '已不是目标会话成员');
      }
      common = common == null
          ? members
          : {
              for (final entry in common.entries)
                if (members.containsKey(entry.key)) entry.key: entry.value,
            };
    }
    return common ?? {};
  }

  Json _validatedReceipt(Json raw) {
    final bundle = raw['bundle'];
    final deliveries = maps(raw['deliveries']);
    if (bundle is! Map ||
        str(bundle['id']).isEmpty ||
        bundle['message_count'] != _ids.length ||
        str(bundle['title']).isEmpty ||
        bundle['created_by'] != identity.$3 ||
        DateTime.tryParse(str(bundle['created_at'])) == null ||
        deliveries.length != _targets.length ||
        deliveries.map((d) => str(d['room_id'])).toSet().length !=
            _targets.length ||
        deliveries.any(
          (d) =>
              !_targets.contains(d['room_id']) ||
              d['message'] is! Map ||
              str((d['message'] as Map)['id']).isEmpty ||
              (d['message'] as Map)['kind'] != 'forward_bundle' ||
              ((d['message'] as Map)['forward_bundle'] as Map?)?['id'] !=
                  bundle['id'],
        )) {
      throw const FormatException('合并转发回执不完整，请确认原请求');
    }
    return _copy(raw);
  }

  void _accept(Json result) {
    final verified = _validatedReceipt(result);
    _pendingBundles[office]?.remove(_pendingKey);
    setState(() {
      _result = verified;
      _pending = null;
      _unknown = false;
      _error = null;
    });
    close(verified);
  }

  Future<bool> _recover(int attempt) async {
    if (_pending == null) return false;
    final clientId = str(_pending!['client_id']);
    final response = await office.officeRequest(
      '${_roomPath(scopeRoom)}/messages/forward-bundle-receipts?client_id=${Uri.encodeComponent(clientId)}',
    );
    if (!current || generation != attempt) return true;
    if (response['receipts'] is! List || response['truncated'] != false) {
      throw const FormatException('原请求回执尚未确认，请稍后重试');
    }
    final receipts = maps(response['receipts']);
    if (receipts.isEmpty) return false;
    if (receipts.length != 1 || receipts.single['client_id'] != clientId) {
      throw const FormatException('原请求回执标识不匹配');
    }
    _accept({...receipts.single, 'duplicate': true, 'recovered': true});
    return true;
  }

  Future<void> _load() async {
    if (!current ||
        _busy ||
        !office.connected ||
        _blocked != null ||
        _result != null) {
      return;
    }
    final attempt = ++generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_unknown && await _recover(attempt)) return;
      if (!current || attempt != generation) return;
      final rooms = await _readRooms(attempt);
      final sources = _unknown ? <Json>[] : await _readSources(attempt);
      if (!current || attempt != generation) return;
      setState(() {
        _rooms = rooms;
        _sources = sources;
        _ready = true;
        if (!_unknown) {
          _targets.removeWhere((id) => !rooms.any((r) => r['id'] == id));
        }
      });
    } catch (e) {
      if (current && attempt == generation) {
        setState(() {
          _error = friendlyError(e);
          _sources = [];
          _rooms = [];
          _ready = false;
          if (e is OfficeException && [401, 403, 404].contains(e.status)) {
            _comment.clear();
            _mentions.clear();
          }
        });
      }
    } finally {
      if (mounted && attempt == generation) setState(() => _busy = false);
    }
  }

  void _select(String id) {
    if (!_editable || !_rooms.any((r) => r['id'] == id)) return;
    setState(() {
      if (_targets.contains(id)) {
        _targets.remove(id);
      } else if (!_multiple) {
        _targets
          ..clear()
          ..add(id);
      } else if (_targets.length < 20) {
        _targets.add(id);
      } else {
        _error = '一次最多选择 20 个会话。';
        return;
      }
      _mentions.clear();
    });
  }

  Future<void> _chooseMentions() async {
    if (!_editable ||
        !office.connected ||
        _targets.isEmpty ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final attempt = ++generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final common = await _commonMembers(attempt);
      if (!mounted || !current || generation != attempt) return;
      // The modal picker owns interaction while its result is pending. Do not
      // keep an indeterminate network spinner running behind that dialog.
      setState(() => _busy = false);
      final selection = await showDialog<OfficeMentionSelection>(
        context: context,
        builder: (pickerContext) => AnimatedBuilder(
          animation: boundOffice,
          builder: (_, _) => current && generation == attempt
              ? OfficeMentionPicker(
                  people: common.values.toList(),
                  selected: _mentions.keys.toList(),
                  mobile: MediaQuery.sizeOf(pickerContext).width < 720,
                  group: false,
                )
              : AlertDialog(
                  content: const Text('工作身份或来源已变更，请重新选择。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(pickerContext),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
        ),
      );
      if (!current || generation != attempt || selection == null) return;
      setState(() {
        _mentions
          ..clear()
          ..addAll({
            for (final id in selection.selectedIds)
              if (common.containsKey(id)) id: officeDisplayName(common[id]!),
          });
      });
    } catch (e) {
      if (current && generation == attempt) {
        setState(() {
          _error = friendlyError(e);
          _mentions.clear();
        });
      }
    } finally {
      if (mounted && generation == attempt) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (!_canSend || ModalRoute.of(context)?.isCurrent != true) return;
    final attempt = ++generation;
    var posted = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_unknown && await _recover(attempt)) return;
      if (!current || attempt != generation) return;
      if (!_unknown) {
        final rooms = await _readRooms(attempt);
        final sources = await _readSources(attempt);
        final common = await _commonMembers(attempt);
        if (!current || attempt != generation) return;
        if (_targets.any((id) => !rooms.any((r) => r['id'] == id))) {
          setState(() {
            _rooms = rooms;
            _targets.removeWhere((id) => !rooms.any((r) => r['id'] == id));
            _mentions.clear();
            _error = '目标会话已变化，请重新选择后发送。';
          });
          return;
        }
        final changed =
            jsonEncode(
              _sources.map((m) => [m['id'], m['revision']]).toList(),
            ) !=
            jsonEncode(sources.map((m) => [m['id'], m['revision']]).toList());
        final invalidMention = _mentions.keys.any(
          (id) => !common.containsKey(id),
        );
        setState(() {
          _rooms = rooms;
          _sources = sources;
        });
        if (changed || invalidMention) {
          setState(() {
            if (invalidMention) _mentions.clear();
            _error = changed ? '来源消息已更新，请核对预览后再次发送。' : '提及成员已变化，请重新选择后发送。';
          });
          return;
        }
        final comment = [
          if (_mentions.isNotEmpty)
            _mentions.values.map((name) => '@$name').join(' '),
          if (_comment.text.trim().isNotEmpty) _comment.text.trim(),
        ].join(' ');
        if (comment.length > 12000) {
          setState(() => _error = '附言最多 12000 个字符。');
          return;
        }
        _pending = {
          'client_id': OfficeState.newClientId(),
          'message_ids': _ids,
          'base_revisions': {
            for (final m in sources) str(m['id']): m['revision'],
          },
          'target_room_ids': _targets.toList(),
          'comment': comment,
          'mentions': _mentions.keys.toList(),
        };
        (_pendingBundles[office] ??= {})[_pendingKey] = {
          'payload': _copy(_pending!),
          'comment_draft': _comment.text,
          'mention_labels': {..._mentions},
        };
      }
      if (!current || !office.connected || attempt != generation) return;
      posted = true;
      final result = await office.officeRequest(
        '${_roomPath(scopeRoom)}/messages/forward-bundle',
        method: 'POST',
        data: _copy(_pending!),
      );
      if (!current || attempt != generation) return;
      _accept(result);
    } catch (e) {
      if (current && attempt == generation) {
        setState(() {
          _error = friendlyError(e);
          if (_pending != null && (posted || _unknown)) {
            final definitive =
                !_unknown &&
                e is OfficeException &&
                e.status >= 400 &&
                e.status < 500 &&
                e.code != 'idempotency_conflict';
            if (definitive) {
              _pendingBundles[office]?.remove(_pendingKey);
              _pending = null;
              _ready = false;
            } else {
              _unknown = true;
            }
          }
          if (e is OfficeException && [401, 403, 404].contains(e.status)) {
            _sources = [];
            _rooms = [];
            _mentions.clear();
            _comment.clear();
            _ready = false;
          }
        });
      }
    } finally {
      if (mounted && generation == attempt) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleRooms = _rooms
        .where(
          (r) => str(r['name']).toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
      },
      child: Column(
        children: [
          _heading('合并转发', () => close(_result)),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (!current)
            const Expanded(child: Center(child: Text('工作身份已变更，请重新打开。')))
          else if (_result != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 38,
                    ),
                    const SizedBox(height: 12),
                    Text('已合并转发至 ${maps(_result!['deliveries']).length} 个会话'),
                    Text(
                      '${(_result!['bundle'] as Map)['message_count']} 条聊天记录',
                      style: const TextStyle(color: mutedColor),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                children: [
                  if (_blocked != null)
                    Text(_blocked!, style: const TextStyle(color: Colors.red)),
                  if (_unknown)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text(
                        '上次发送结果待确认，原消息、接收会话和附言已锁定。重试会先查询原回执。',
                        style: TextStyle(color: mutedColor),
                      ),
                    ),
                  if (_sources.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xfff5f6f8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '聊天记录 · ${_sources.length} 条',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          for (final source in _sources.take(3))
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: _previewText(
                                '${officeDisplayName(Json.from(source['author'] as Map? ?? {}))}：${source['kind'] == 'forward_bundle' ? '[聊天记录]' : str(source['content'])}',
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('bundle-target-search'),
                    enabled: _editable,
                    decoration: const InputDecoration(
                      hintText: '搜索最近会话',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '最近会话',
                          style: TextStyle(fontSize: 12, color: mutedColor),
                        ),
                      ),
                      TextButton(
                        onPressed: !_editable
                            ? null
                            : () => setState(() {
                                _multiple = !_multiple;
                                if (!_multiple && _targets.length > 1) {
                                  final first = _targets.first;
                                  _targets
                                    ..clear()
                                    ..add(first);
                                  _mentions.clear();
                                }
                              }),
                        child: Text(_multiple ? '切换单选' : '切换多选'),
                      ),
                    ],
                  ),
                  if (visibleRooms.isEmpty && !_busy)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('没有可用的匹配会话'),
                    ),
                  for (final room in visibleRooms)
                    ListTile(
                      key: ValueKey('bundle-target-${room['id']}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: selectedColor,
                        child: Icon(
                          room['kind'] == 'direct'
                              ? Icons.person_outline
                              : Icons.group_outlined,
                          color: accentColor,
                        ),
                      ),
                      title: Text(
                        str(room['name'], '会话'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(
                        _targets.contains(room['id'])
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: _targets.contains(room['id'])
                            ? accentColor
                            : mutedColor,
                      ),
                      onTap: _editable ? () => _select(str(room['id'])) : null,
                    ),
                  if (_targets.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('已选 ${_targets.length} 个会话'),
                    ),
                  TextField(
                    key: const ValueKey('bundle-comment'),
                    controller: _comment,
                    enabled: _editable,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 12000,
                    decoration: const InputDecoration(
                      hintText: '留言（可 @ 成员）',
                      counterText: '',
                    ),
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final entry in _mentions.entries)
                        InputChip(
                          label: Text('@${entry.value}'),
                          onDeleted: _editable
                              ? () =>
                                    setState(() => _mentions.remove(entry.key))
                              : null,
                        ),
                      ActionChip(
                        label: const Text('@ 人或 Agent'),
                        onPressed:
                            _editable && _targets.isNotEmpty && office.connected
                            ? _chooseMentions
                            : null,
                      ),
                    ],
                  ),
                  if (_targets.length > 1)
                    const Text(
                      '可提及所有已选会话共同的成员。',
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  if (!office.connected) const Text('当前离线，连接后可继续。'),
                  if (!_unknown && _result == null && _blocked == null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: !_busy && office.connected ? _load : null,
                        child: const Text('刷新并核对来源'),
                      ),
                    ),
                ],
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => close(_result),
                  child: Text(_result == null ? '取消' : '关闭'),
                ),
                const Spacer(),
                if (_result == null && current)
                  FilledButton(
                    key: const ValueKey('bundle-send'),
                    onPressed: _canSend ? _send : null,
                    child: Text(_unknown ? '重试确认原请求' : '发送'),
                  ),
                if (_result != null)
                  FilledButton(
                    onPressed: () => close(_result),
                    child: const Text('完成'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _heading(String title, VoidCallback close) => Padding(
  padding: const EdgeInsets.fromLTRB(18, 8, 6, 8),
  child: Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      IconButton(
        tooltip: '关闭',
        onPressed: close,
        icon: const Icon(Icons.close),
      ),
    ],
  ),
);

class OfficeForwardBundleCard extends StatefulWidget {
  const OfficeForwardBundleCard({
    super.key,
    required this.state,
    required this.roomId,
    required this.message,
  });
  final OfficeState state;
  final String roomId;
  final Json message;
  @override
  State<OfficeForwardBundleCard> createState() => _ForwardCardState();
}

class _ForwardCardState extends _BundleScope<OfficeForwardBundleCard> {
  late final String _messageId;
  bool _opening = false;
  @override
  OfficeState get office => widget.state;
  @override
  String get scopeRoom => widget.roomId;
  @override
  void initState() {
    super.initState();
    _messageId = str(widget.message['id']);
  }

  @override
  void didUpdateWidget(covariant OfficeForwardBundleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (str(widget.message['id']) != _messageId) invalidate();
  }

  @override
  void clearPrivate() {}
  Json get _message {
    if ((office.detail?['room'] as Map?)?['id'] == scopeRoom) {
      final current = maps(office.detail?['messages'])
          .where((m) => m['id'] == _messageId)
          .firstOrNull;
      if (current != null) return current;
    }
    return widget.message;
  }

  Future<void> _open() async {
    if (!current ||
        _opening ||
        !office.connected ||
        _hiddenCard(_message) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _opening = true;
    try {
      await showOfficeForwardBundleDetails(
        context,
        office,
        scopeRoom,
        _message,
      );
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    final reference = message['forward_bundle'];
    if (!current ||
        _hiddenCard(message) ||
        reference is! Map ||
        str(reference['id']).isEmpty) {
      return const Text('聊天记录暂不可用', style: TextStyle(color: mutedColor));
    }
    return Semantics(
      button: true,
      label: '展开合并聊天记录',
      child: InkWell(
        key: ValueKey('forward-bundle-card-$_messageId'),
        onTap: office.connected ? _open : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .85),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xffe2e7ef)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                str(reference['title'], '聊天记录'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final preview in maps(reference['preview']).take(3))
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: _previewText(
                    '${str(preview['author_name'])}：${str(preview['content'])}',
                  ),
                ),
              const Divider(height: 18),
              Row(
                children: [
                  const Icon(Icons.forum_outlined, size: 14, color: mutedColor),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '${reference['message_count']} 条聊天记录',
                      style: const TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 16, color: mutedColor),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _hiddenCard(Json message) =>
    message['hidden'] == true || message['retracted_at'] != null;

class OfficeForwardBundleDetails extends StatefulWidget {
  const OfficeForwardBundleDetails({
    super.key,
    required this.state,
    required this.roomId,
    required this.message,
  });
  final OfficeState state;
  final String roomId;
  final Json message;
  @override
  State<OfficeForwardBundleDetails> createState() => _ForwardDetailsState();
}

class _ForwardDetailsState extends _BundleScope<OfficeForwardBundleDetails> {
  late final String _messageId, _bundleId;
  Json? _bundle;
  String? _error;
  bool _busy = false;
  @override
  OfficeState get office => widget.state;
  @override
  String get scopeRoom => widget.roomId;
  @override
  void initState() {
    super.initState();
    _messageId = str(widget.message['id']);
    _bundleId = str((widget.message['forward_bundle'] as Map?)?['id']);
    _load();
  }

  @override
  void didUpdateWidget(covariant OfficeForwardBundleDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (str(widget.message['id']) != _messageId ||
        str((widget.message['forward_bundle'] as Map?)?['id']) != _bundleId ||
        _hiddenCard(widget.message)) {
      invalidate();
    }
  }

  @override
  void clearPrivate() {
    _bundle = null;
    _error = null;
    _busy = false;
  }

  @override
  void changed() {
    if ((office.detail?['room'] as Map?)?['id'] != scopeRoom) return;
    final card = maps(office.detail?['messages'])
        .where((m) => m['id'] == _messageId)
        .firstOrNull;
    if (card != null &&
        (_hiddenCard(card) ||
            str((card['forward_bundle'] as Map?)?['id']) != _bundleId)) {
      invalidate();
    }
  }

  Future<void> _load() async {
    if (!current || _busy || !office.connected) return;
    final attempt = ++generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_messageId.isEmpty ||
          _bundleId.isEmpty ||
          _hiddenCard(widget.message)) {
        throw const FormatException('聊天记录引用不完整');
      }
      final response = await office.officeRequest(
        '${_roomPath(scopeRoom)}/messages/${Uri.encodeComponent(_messageId)}/forward-bundle',
      );
      if (!current || generation != attempt) return;
      final bundle = _verifyBundleResponse(
        response,
        roomId: scopeRoom,
        messageId: _messageId,
        bundleId: _bundleId,
      );
      setState(() => _bundle = bundle);
    } catch (e) {
      if (current && generation == attempt) {
        setState(() {
          _bundle = null;
          _error = friendlyError(e);
        });
      }
    } finally {
      if (mounted && generation == attempt) setState(() => _busy = false);
    }
  }

  Widget _item(Json item, String path) {
    final author = Json.from(item['author'] as Map);
    final nested = item['forward_bundle'] as Map?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PersonAvatar(
                name: officeDisplayName(author),
                agent: author['kind'] == 'agent',
                size: 28,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  officeDisplayName(author),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                clockText(item['source_at'], date: true, context: context),
                style: const TextStyle(fontSize: 11, color: mutedColor),
              ),
            ],
          ),
          if (str(item['content']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: OfficeRichText(
                content: str(item['content']),
                richText: item['rich_text'] is Map
                    ? Json.from(item['rich_text'] as Map)
                    : null,
              ),
            ),
          for (final attachment in maps(item['attachments']))
            _BundleAttachment(
              key: ValueKey('$path:${attachment['id']}'),
              office: office,
              attachment: attachment,
              current: () => current && _bundle != null,
            ),
          if (nested != null)
            ExpansionTile(
              key: ValueKey('bundle-nested-$path'),
              title: Text(
                '${str(nested['title'], '聊天记录')} · ${nested['message_count']} 条',
              ),
              children: [
                for (final (i, child) in maps(nested['items']).indexed)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: _item(child, '$path.$i'),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _heading(
        _bundle == null ? '聊天记录' : str(_bundle!['title'], '聊天记录'),
        close,
      ),
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: !current
            ? const Center(child: Text('工作身份或聊天记录权限已变更，请重新打开。'))
            : ListView(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                children: [
                  if (_bundle != null) ...[
                    Text(
                      '${_bundle!['message_count']} 条消息',
                      style: const TextStyle(fontSize: 12, color: mutedColor),
                    ),
                    for (final (i, item) in maps(_bundle!['items']).indexed)
                      _item(item, '$i'),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  if (!office.connected) const Text('当前离线，连接后可读取聊天记录。'),
                ],
              ),
      ),
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            TextButton(onPressed: close, child: const Text('关闭')),
            const Spacer(),
            TextButton(
              onPressed: current && !_busy && office.connected ? _load : null,
              child: const Text('刷新'),
            ),
          ],
        ),
      ),
    ],
  );
}

class _BundleAttachment extends StatefulWidget {
  const _BundleAttachment({
    super.key,
    required this.office,
    required this.attachment,
    required this.current,
  });
  final OfficeState office;
  final Json attachment;
  final bool Function() current;
  @override
  State<_BundleAttachment> createState() => _BundleAttachmentState();
}

class _BundleAttachmentState extends State<_BundleAttachment> {
  bool _busy = false;
  String? _error;
  Future<void> _save() async {
    if (_busy || !widget.current() || !widget.office.connected) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final original = widget.attachment;
    try {
      final bytes = await widget.office.getAttachmentBytes(original);
      if (!mounted ||
          !widget.current() ||
          !identical(original, widget.attachment)) {
        return;
      }
      await FilePicker.saveFile(
        fileName: str(original['filename'], 'attachment'),
        bytes: bytes,
        mimeType: str(original['mime_type'], 'application/octet-stream'),
      );
    } catch (e) {
      if (mounted && widget.current()) {
        setState(() => _error = friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final available =
        (a['availability'] ?? a['status'] ?? 'active') == 'active';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(
        str(a['filename'], '附件'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _error ??
            (available
                ? fileSizeText((a['size'] as num?)?.toInt() ?? 0)
                : '附件已不可用'),
      ),
      trailing: IconButton(
        tooltip: '保存附件',
        onPressed:
            available && !_busy && widget.current() && widget.office.connected
            ? _save
            : null,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.download_outlined),
      ),
    );
  }
}
