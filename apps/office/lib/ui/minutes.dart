import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../minutes_api.dart';
import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeMinutes extends StatefulWidget {
  const OfficeMinutes({super.key, required this.state});
  final OfficeState state;
  @override
  State<OfficeMinutes> createState() => OfficeMinutesState();
}

class OfficeMinutesState extends State<OfficeMinutes> {
  List<Json> _items = [];
  Json? _selected;
  String _query = '', _filter = '全部妙记';
  String? _error;
  bool _loading = true, _busy = false;
  int _load = 0;
  Timer? _refreshTimer;
  final Map<String, Json> _createdDocuments = {}, _createdTasks = {};
  final Map<String, String> _intents = {};
  OfficeState get s => widget.state;
  OfficeMinutesApi get api => OfficeMinutesApi(s);

  @override
  void initState() {
    super.initState();
    s.addListener(_scheduleRefresh);
    _refresh();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 350), _refresh);
  }

  @override
  void dispose() {
    s.removeListener(_scheduleRefresh);
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_load;
    try {
      final items = await api.list(_query);
      if (!mounted || generation != _load) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted && generation == _load) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> createMinute({String? initialText}) async {
    final rooms = officeBusinessRooms(s);
    if (rooms.isEmpty) {
      notifyOffice(context, '请先创建或加入一个工作群');
      return;
    }
    final value = await showDialog<Json>(
      context: context,
      builder: (_) => _MinutesEditDialog(office: s, initialText: initialText),
    );
    if (value != null && mounted) {
      setState(() => _selected = value);
      await _refresh();
    }
  }

  Future<void> openMinute(Json minute) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await api.get(str(minute['id']));
      if (mounted) setState(() => _selected = value);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final value = await showDialog<Json>(
      context: context,
      builder: (_) => _MinutesEditDialog(office: s, source: _selected),
    );
    if (value != null && mounted) {
      setState(() => _selected = value);
      await _refresh();
    }
  }

  Future<Json> _ensureDocument(Json minute) async {
    if (minute['document_id'] != null) {
      return s.getDocument(
        str(minute['document_id']),
        roomId: str(minute['room_id']),
      );
    }
    final id = str(minute['id']);
    final doc =
        _createdDocuments[id] ??
        Json.from(
          (await s.officeRequest(
            '/rooms/${Uri.encodeComponent(minute['room_id'])}/documents',
            method: 'POST',
            data: {
              'client_id': _intents.putIfAbsent(
                'doc:$id',
                OfficeState.newClientId,
              ),
              'title': '${minute['title']} · 共同纪要',
              'content': minutesMarkdown(minute),
            },
          ))['document'],
        );
    _createdDocuments[id] = doc;
    // Keep a successful document if association conflicts; retry links the same resource.
    final updated = await api.update(minute, {'document_id': doc['id']});
    if (mounted) setState(() => _selected = updated);
    return doc;
  }

  Future<void> _document() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final doc = await _ensureDocument(_selected!);
      if (mounted) {
        await OfficeDialogs.document(context, s, {
          ...doc,
          'room_id': _selected!['room_id'],
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              '${friendlyError(e)}${_createdDocuments.containsKey(_selected?['id']) ? '。已创建的文档已保留，刷新妙记后可重试关联。' : ''}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delegate() async {
    final minute = _selected!;
    final room = str(minute['room_id']);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final roomDetail = await s.officeRequest(
        '/rooms/${Uri.encodeComponent(room)}',
      );
      if (!mounted) return;
      final members = maps(
        roomDetail['members'] ?? roomDetail['room']?['members'],
      );
      final people = members
          .where(
            (p) => p['kind'] == 'agent' || p['principal']?['kind'] == 'agent',
          )
          .toList();
      if (people.isEmpty) {
        notifyOffice(context, '请先从 Agent 商店添加一位同事到这个群');
        return;
      }
      final ids = await chooseOfficePeople(
        context,
        s,
        title: '交给 Agent 整理纪要',
        people: people,
      );
      if (ids == null || ids.isEmpty || !mounted) return;
      await _ensureDocument(minute);
      final current = _selected!;
      final key = '${minute['id']}:${ids.first}';
      final task =
          _createdTasks[key] ??
          await api.createTask(
            current,
            '整理《${minute['title']}》的结论与待办',
            ids.first,
            _intents.putIfAbsent('task:$key', OfficeState.newClientId),
          );
      _createdTasks[key] = task;
      final linked = {
        ...(current['task_ids'] as List? ?? []).map(str),
        str(task['id']),
      }.toList();
      final updated = await api.update(current, {'task_ids': linked});
      if (mounted) {
        setState(() => _selected = updated);
        notifyOffice(context, '任务已交给 Agent；执行状态以工作记录为准');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '${friendlyError(e)}。已创建的文档或任务会保留，可刷新后重试关联。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    try {
      final current = await api.get(str(_selected!['id']));
      await FilePicker.saveFile(
        fileName:
            '${str(current['title']).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.md',
        bytes: Uint8List.fromList(utf8.encode(minutesMarkdown(current))),
        mimeType: 'text/markdown',
      );
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  Future<void> _downloadAudio() async {
    try {
      final minute = _selected!;
      final attachment = Json.from(
        minute['audio_attachment'] ??
            {
              'id': minute['audio_attachment_id'],
              'room_id': minute['room_id'],
              'filename': '${minute['title']}.audio',
            },
      );
      attachment['room_id'] = minute['room_id'];
      final bytes = await s.getAttachmentBytes(attachment);
      await FilePicker.saveFile(
        fileName: str(attachment['filename'], 'recording.audio'),
        bytes: bytes,
        mimeType: str(attachment['mime_type'], 'application/octet-stream'),
      );
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) =>
      _selected == null ? _library() : _detail();

  Widget _library() {
    final visible = _items.where((m) {
      if (_filter == '我创建的' && m['created_by'] != s.me?['id']) return false;
      if (_filter == '会议记录' && m['meeting_id'] == null) return false;
      return true;
    }).toList();
    return Column(
      children: [
        BusinessHeader(
          title: '人机妙记',
          subtitle: '让每段对话，成为可继续推进的工作。',
          actions: [
            IconButton(
              onPressed: _refresh,
              tooltip: '刷新妙记',
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xfff2f0ff),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.graphic_eq_rounded,
                  color: Color(0xff7966d6),
                  size: 32,
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '对话有记录，协作有后续',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '文字与录音 · 共同纪要 · Agent 待办',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => createMinute(),
                  icon: const Icon(Icons.add, size: 17),
                  label: const Text('新建'),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索妙记标题或文字记录',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
            onChanged: (v) {
              setState(() => _query = v);
              _scheduleRefresh();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Row(
            children: [
              for (final label in ['全部妙记', '我创建的', '会议记录'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: _filter == label,
                    onSelected: (_) => setState(() => _filter = label),
                  ),
                ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: BusinessError(_error),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.mic_none_rounded,
                          size: 48,
                          color: Color(0xffa39bc5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _query.isEmpty ? '从一份对话记录开始' : '没有找到这份妙记',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 9),
                        const Text(
                          '新建或导入文字，再和人、Agent 一起整理。',
                          style: TextStyle(fontSize: 12, color: mutedColor),
                        ),
                        const SizedBox(height: 20),
                        OutlinedButton(
                          onPressed: () => createMinute(),
                          child: const Text('新建人机妙记'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final m = visible[index];
                    return Material(
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        side: const BorderSide(color: borderColor),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(14),
                        onTap: _busy ? null : () => openMinute(m),
                        leading: Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: const Color(0xffefecff),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            m['audio_attachment_id'] == null
                                ? Icons.notes_rounded
                                : Icons.graphic_eq,
                            color: const Color(0xff8874ca),
                          ),
                        ),
                        title: Text(
                          str(m['title']),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '${officeRoomName(s, str(m['room_id']))} · ${m['transcript_count'] ?? m['segment_count'] ?? maps(m['transcript']).length} 段记录\n${fullOfficeTime(m['updated_at'], context: context)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: mutedColor,
                            ),
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: mutedColor,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _detail() {
    final m = _selected!, transcript = maps(m['transcript']);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() => _selected = null),
                tooltip: '返回妙记列表',
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      str(m['title']),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${officeRoomName(s, str(m['room_id']))} · 共同版本 r${m['revision']}',
                      style: const TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _busy ? null : () => openMinute(m),
                tooltip: '刷新这份妙记',
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _edit,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('编辑记录'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _document,
                icon: const Icon(Icons.description_outlined, size: 16),
                label: Text(m['document_id'] == null ? '转为共同纪要' : '打开共同纪要'),
              ),
              FilledButton.icon(
                onPressed: _busy || transcript.isEmpty ? null : _delegate,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Agent 整理'),
              ),
              TextButton.icon(
                onPressed: _export,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('导出'),
              ),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: BusinessError(_error),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (m['audio_attachment_id'] != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _downloadAudio,
                    icon: const Icon(Icons.audio_file_outlined, size: 17),
                    label: Text(
                      '下载录音 · ${str(m['audio_attachment']?['filename'], '音频文件')}',
                    ),
                  ),
                ),
              if (m['meeting_id'] != null)
                _info(
                  Icons.videocam_outlined,
                  '关联会议',
                  str(
                    s.meetings
                        .where((e) => e['id'] == m['meeting_id'])
                        .firstOrNull?['title'],
                    '会议记录',
                  ),
                ),
              if (m['audio_attachment_id'] != null)
                _info(
                  Icons.audiotrack_outlined,
                  '录音文件已保存',
                  '转写服务尚未配置。可先导入或补充文字记录；本页不会生成虚假逐字稿。',
                ),
              Row(
                children: [
                  const Text(
                    '文字记录',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '${transcript.length} 段',
                    style: const TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (transcript.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    '还没有文字记录。点击“编辑记录”导入逐字稿或手动整理。',
                    style: TextStyle(color: mutedColor),
                  ),
                ),
              for (final segment in transcript)
                Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xfff3f4f8),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          minutesOffset(segment['offset_ms']),
                          style: const TextStyle(
                            fontSize: 11,
                            color: mutedColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              str(segment['speaker_label'], '未标注发言人'),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xff7b68c4),
                              ),
                            ),
                            const SizedBox(height: 7),
                            SelectableText(
                              str(segment['text']),
                              style: const TextStyle(fontSize: 14, height: 1.8),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 32),
              _info(
                Icons.task_alt,
                '关联待办',
                '${(m['task_ids'] as List? ?? []).length} 项已关联。Agent 接到任务后通过自己的工作身份处理，执行结果可在群里的工作记录核对。',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _info(IconData icon, String title, String description) => Container(
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: const Color(0xfff6f7fb),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: mutedColor),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: mutedColor,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _MinutesEditDialog extends StatefulWidget {
  const _MinutesEditDialog({
    required this.office,
    this.source,
    this.initialText,
  });
  final OfficeState office;
  final Json? source;
  final String? initialText;
  @override
  State<_MinutesEditDialog> createState() => _MinutesEditDialogState();
}

class _MinutesEditDialogState extends State<_MinutesEditDialog> {
  late final TextEditingController _title, _text;
  late String _room;
  String? _meeting, _filename, _audioId, _error;
  Uint8List? _audio;
  bool _busy = false;
  final _client = OfficeState.newClientId(),
      _uploadClient = OfficeState.newClientId();
  @override
  void initState() {
    super.initState();
    final m = widget.source;
    _title = TextEditingController(text: str(m?['title']));
    _text = TextEditingController(
      text: m == null ? (widget.initialText ?? '') : minutesTranscriptText(m),
    );
    final rooms = officeBusinessRooms(widget.office);
    _room = str(
      m?['room_id'] ??
          (rooms.any((r) => r['id'] == widget.office.selectedRoomId)
              ? widget.office.selectedRoomId
              : rooms.first['id']),
    );
    _meeting = m?['meeting_id'];
    _audioId = m?['audio_attachment_id'];
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _import(bool audio) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: audio
            ? officeMinutesAudioMimeTypes.keys.toList(growable: false)
            : ['txt', 'md'],
      );
      final file = result.firstOrNull;
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.length > (audio ? 12 * 1024 * 1024 : 1024 * 1024)) {
        throw FormatException(audio ? '录音请控制在 12 MB 内' : '文字文件请控制在 1 MB 内');
      }
      setState(() {
        if (audio) {
          _audio = bytes;
          _filename = file.name;
          _audioId = null;
        } else {
          _text.text = utf8.decode(bytes);
        }
        if (_title.text.trim().isEmpty) {
          _title.text = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
        }
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : friendlyError(e),
        );
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_title.text.trim().isEmpty) throw const FormatException('请给这份妙记起个名字');
      final transcript = parseMinutesTranscript(_text.text),
          api = OfficeMinutesApi(widget.office);
      if (_audio != null && _audioId == null) {
        _audioId = str(
          (await api.audio(_room, _filename!, _audio!, _uploadClient))['id'],
        );
      }
      final input = <String, dynamic>{
        'title': _title.text.trim(),
        'transcript': transcript,
        'meeting_id': _meeting,
        'audio_attachment_id': _audioId,
      };
      final value = widget.source == null
          ? await api.create(_room, {'client_id': _client, ...input})
          : await api.update(widget.source!, input);
      if (mounted) Navigator.pop(context, value);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : friendlyError(e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rooms = officeBusinessRooms(widget.office),
        meetings = widget.office.meetings
            .where((m) => m['room_id'] == _room)
            .toList();
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: MediaQuery.sizeOf(context).height * .87,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.graphic_eq, color: Color(0xff8874ca)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.source == null ? '新建人机妙记' : '编辑人机妙记',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    tooltip: '关闭妙记编辑',
                    icon: const Icon(Icons.close, size: 19),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _title,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: '妙记标题',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _room,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '共享到工作会话'),
                        items: rooms
                            .map(
                              (r) => DropdownMenuItem(
                                value: str(r['id']),
                                child: Text(
                                  str(r['name']),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged:
                            _busy || widget.source != null || _audioId != null
                            ? null
                            : (v) => setState(() {
                                _room = v!;
                                _meeting = null;
                              }),
                      ),
                      if (meetings.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: DropdownButtonFormField<String>(
                            key: ValueKey(_room),
                            initialValue: _meeting ?? '',
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '关联会议（可选）',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('不关联会议'),
                              ),
                              for (final m in meetings)
                                DropdownMenuItem(
                                  value: str(m['id']),
                                  child: Text(
                                    str(m['title']),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(
                                    () => _meeting = v == '' ? null : v,
                                  ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: MediaQuery.viewInsetsOf(context).bottom > 0
                            ? 180
                            : 260,
                        child: TextField(
                          controller: _text,
                          expands: true,
                          maxLines: null,
                          minLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          style: const TextStyle(fontSize: 13, height: 1.8),
                          decoration: const InputDecoration(
                            labelText: '文字记录',
                            alignLabelWithHint: true,
                            hintText: '[00:00] 张同事：本次讨论的目标是…\n[01:20] Agent 同事：我来整理需要跟进的事项。\n\n也可以直接粘贴文字，每段一行。未标注时间的段落沿用上一段时间。',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_filename != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '录音：$_filename · 保存后可补充逐字稿',
                    style: const TextStyle(fontSize: 11, color: mutedColor),
                  ),
                ),
              if (_error != null) BusinessError(_error),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _busy ? null : () => _import(false),
                    icon: const Icon(Icons.file_open_outlined, size: 16),
                    label: const Text('导入文字'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _import(true),
                    icon: const Icon(Icons.audio_file_outlined, size: 16),
                    label: const Text('上传录音'),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(_busy ? '正在保存…' : '保存妙记'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
