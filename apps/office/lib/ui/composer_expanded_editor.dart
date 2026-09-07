import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'mentions.dart';
import 'office_dialogs.dart' show friendlyError;
import 'office_emoji.dart';
import 'office_rich_text.dart';
import 'office_theme.dart';

typedef OfficeExpandedAgentEntry = Future<List<String>?> Function(
  Future<bool> Function() saveAndClose,
);

class OfficeExpandedDraft {
  const OfficeExpandedDraft({
    required this.value,
    required this.title,
    required this.mentions,
    required this.mentionAll,
    this.sendRequested = false,
  });
  final OfficeRichTextValue value;
  final String title;
  final List<String> mentions;
  final bool mentionAll, sendRequested;
}

Future<OfficeExpandedDraft?> showOfficeExpandedComposer(
  BuildContext context, {
  required OfficeState state,
  required OfficeRichTextValue value,
  String title = '',
  List<String> mentions = const [],
  bool mentionAll = false,
  bool mobile = false,
  Future<void> Function()? onPickAttachments,
  List<String> Function()? attachmentNames,
  OfficeExpandedAgentEntry? onAgent,
}) => showDialog<OfficeExpandedDraft>(
  context: context,
  barrierDismissible: !mobile,
  builder: (_) => OfficeExpandedComposer(
    state: state,
    value: value,
    title: title,
    mentions: mentions,
    mentionAll: mentionAll,
    mobile: mobile,
    onPickAttachments: onPickAttachments,
    attachmentNames: attachmentNames,
    onAgent: onAgent,
  ),
);

class OfficeExpandedComposer extends StatefulWidget {
  const OfficeExpandedComposer({
    super.key,
    required this.state,
    required this.value,
    this.title = '',
    this.mentions = const [],
    this.mentionAll = false,
    this.mobile = false,
    this.onPickAttachments,
    this.attachmentNames,
    this.onAgent,
  });
  final OfficeState state;
  final OfficeRichTextValue value;
  final String title;
  final List<String> mentions;
  final bool mentionAll, mobile;
  final Future<void> Function()? onPickAttachments;
  final List<String> Function()? attachmentNames;
  final OfficeExpandedAgentEntry? onAgent;
  @override
  State<OfficeExpandedComposer> createState() => _ExpandedComposerState();
}

class _ExpandedComposerState extends State<OfficeExpandedComposer> {
  late final OfficeState _office;
  late final (int, String, String, String?) _identity;
  late final TextEditingController _title;
  late final OfficeRichTextEditingController _body;
  final _focus = FocusNode();
  final _mentions = <String>{};
  bool _mentionAll = false,
      _formatting = false,
      _expired = false,
      _closed = false,
      _busy = false;
  String? _error;
  int _intent = 0;
  (int, String, String, String?) _scope() => (
    widget.state.identityGeneration,
    widget.state.endpoint,
    personId(widget.state.me ?? {}),
    widget.state.selectedRoomId,
  );
  bool get _current =>
      mounted &&
      !_expired &&
      identical(widget.state, _office) &&
      _office.me != null &&
      _identity.$4 != null &&
      _identity == _scope();
  bool get _front => ModalRoute.of(context)?.isCurrent == true;
  List<String> get _attachments =>
      _current ? widget.attachmentNames?.call() ?? [] : [];
  bool get _sendable =>
      _current &&
      _office.connected &&
      !_busy &&
      (_body.text.trim().isNotEmpty ||
          _title.text.trim().isNotEmpty ||
          _attachments.isNotEmpty);

  @override
  void initState() {
    super.initState();
    _office = widget.state;
    _identity = _scope();
    var body = widget.value.content;
    var richText = officeNormalizeRichText(body, widget.value.richText);
    var title = '';
    // Only remove an explicitly remembered title that still matches the actual
    // first line. A stale draft title must not consume or prepend unrelated text.
    if (widget.title.isNotEmpty && body.startsWith('${widget.title}\n')) {
      title = widget.title;
      final prefix = title.length + 1;
      body = body.substring(prefix);
      final spans = <Json>[];
      for (final raw in richText?['spans'] as List? ?? []) {
        final span = Json.from(raw as Map);
        final start = (span['start'] as int).clamp(
          prefix,
          widget.value.content.length,
        );
        final end = span['end'] as int;
        if (end > start) {
          spans.add({
            'start': start - prefix,
            'end': end - prefix,
            'styles': span['styles'],
          });
        }
      }
      richText = officeNormalizeRichText(body, {'version': 1, 'spans': spans});
    }
    _title = TextEditingController(text: title)..addListener(_changed);
    _body = OfficeRichTextEditingController(text: body, richText: richText)
      ..addListener(_changed);
    _mentions.addAll(widget.mentions);
    _mentionAll =
        widget.mentionAll &&
        (_office.detail?['room'] as Map?)?['kind'] != 'direct';
    _office.addListener(_scopeChanged);
    _scopeChanged();
  }

  void _changed() {
    if (mounted) setState(() => _error = null);
  }

  void _scopeChanged() {
    if (!mounted || _expired) return;
    if (!_current) {
      _expired = true;
      _intent++;
      _title.clear();
      _body.clear();
      _mentions.clear();
      _mentionAll = false;
      _busy = false;
      _formatting = false;
      _focus.unfocus();
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant OfficeExpandedComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scopeChanged();
  }

  @override
  void dispose() {
    _intent++;
    _office.removeListener(_scopeChanged);
    _title.dispose();
    _body.dispose();
    _focus.dispose();
    super.dispose();
  }

  OfficeExpandedDraft _draft(bool send) {
    final title = _title.text.replaceAll(RegExp(r'[\r\n]'), ' ').trim();
    final prefix = title.isEmpty ? '' : '$title\n';
    final content = '$prefix${_body.text}';
    if (content.length > 12000) {
      throw const FormatException('正文和标题合计最多 12000 个字符。');
    }
    final spans = <Json>[
      if (title.isNotEmpty)
        {
          'start': 0,
          'end': title.length,
          'styles': ['bold'],
        },
      for (final raw in _body.richText?['spans'] as List? ?? [])
        {
          'start': (raw['start'] as int) + prefix.length,
          'end': (raw['end'] as int) + prefix.length,
          'styles': raw['styles'],
        },
    ];
    if (spans.length > 200) throw const FormatException('格式片段过多，请减少格式后再保存。');
    return OfficeExpandedDraft(
      value: OfficeRichTextValue(
        content: content,
        richText: officeNormalizeRichText(content, {
          'version': 1,
          'spans': spans,
        }),
      ),
      title: title,
      mentions: List.unmodifiable(_mentions),
      mentionAll: _mentionAll,
      sendRequested: send,
    );
  }

  bool _finish({bool send = false, bool cancel = false}) {
    if (_closed || !_front) return false;
    if (!_current) {
      _closed = true;
      Navigator.pop(context);
      return false;
    }
    if (send && !_sendable) return false;
    try {
      final draft = cancel ? null : _draft(send);
      _closed = true;
      Navigator.pop(context, draft);
      return true;
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return false;
    }
  }

  void _insert(String text) {
    if (!_current) return;
    final selection = _body.selection;
    final start = selection.isValid ? selection.start : _body.text.length;
    final end = selection.isValid ? selection.end : start;
    final value = _body.text.replaceRange(start, end, text);
    _body.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _focus.requestFocus();
  }

  Future<void> _emoji() async {
    if (!_current || !_front || _busy) return;
    final value = await showOfficeEmojiPicker(context, _office);
    if (_current && value != null) _insert(officeEmojiText(value));
  }

  Future<void> _pickMentions({bool agentsOnly = false}) async {
    if (!_current || !_front || _busy || !_office.connected) return;
    final attempt = ++_intent;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _office.officeRequest(
        '/rooms/${Uri.encodeComponent(_identity.$4!)}',
      );
      if (!_current || attempt != _intent) return;
      if ((result['room'] as Map?)?['id'] != _identity.$4 ||
          result['members'] is! List) {
        throw const FormatException('会话成员信息不完整，请重试。');
      }
      final people = maps(result['members'])
          .where(
            (p) =>
                p['disabled'] != true &&
                p['revoked_at'] == null &&
                personId(p).isNotEmpty,
          )
          .toList();
      if (!people.any((p) => personId(p) == _identity.$3)) {
        throw const FormatException('你已不是当前会话成员。');
      }
      final group = (result['room'] as Map)['kind'] != 'direct';
      final shown = agentsOnly
          ? people.where((p) => p['kind'] == 'agent').toList()
          : people;
      setState(() => _busy = false);
      if (!mounted) return;
      final selection = await showDialog<OfficeMentionSelection>(
        context: context,
        builder: (pickerContext) => AnimatedBuilder(
          animation: _office,
          builder: (_, _) => _current && attempt == _intent
              ? OfficeMentionPicker(
                  people: shown,
                  selected: _mentions.toList(),
                  mobile: widget.mobile,
                  group: group && !agentsOnly,
                  mentionAll: !agentsOnly && _mentionAll,
                )
              : AlertDialog(
                  content: const Text('工作身份或会话已变化，请重新打开。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(pickerContext),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
        ),
      );
      if (!_current || attempt != _intent || selection == null) return;
      setState(() {
        final visibleIds = shown.map(personId).toSet();
        if (agentsOnly) {
          _mentions.removeWhere(visibleIds.contains);
        } else {
          _mentions.clear();
          _mentionAll = group && selection.mentionAll;
        }
        _mentions.addAll(selection.selectedIds.where(visibleIds.contains));
      });
    } catch (error) {
      if (_current && attempt == _intent) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : friendlyError(error),
        );
      }
    } finally {
      if (mounted && attempt == _intent) setState(() => _busy = false);
    }
  }

  Future<void> _images() async {
    if (!_current || !_front || _busy || widget.onPickAttachments == null) {
      return;
    }
    final attempt = ++_intent;
    setState(() => _busy = true);
    try {
      await widget.onPickAttachments!();
    } catch (error) {
      if (_current && attempt == _intent) {
        setState(() => _error = friendlyError(error));
      }
    } finally {
      if (mounted && attempt == _intent) setState(() => _busy = false);
    }
  }

  Future<bool> _saveAndCloseForAgent() async {
    if (!_finish()) return false;
    // Let the caller of showOfficeExpandedComposer consume the draft before
    // a records/store action changes the surrounding navigation or room.
    await Future<void>.delayed(Duration.zero);
    return true;
  }

  Future<void> _agent() async {
    if (!_current || !_front || _busy) return;
    if (widget.onAgent == null) {
      await _pickMentions(agentsOnly: true);
      return;
    }
    final attempt = ++_intent;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final selected = await widget.onAgent!(_saveAndCloseForAgent);
      if (!_current || _closed || attempt != _intent || selected == null) {
        return;
      }
      setState(() => _mentions.addAll(selected.where((id) => id.isNotEmpty)));
    } catch (error) {
      if (_current && !_closed && attempt == _intent) {
        setState(() => _error = friendlyError(error));
      }
    } finally {
      if (mounted && !_closed && attempt == _intent) {
        setState(() => _busy = false);
      }
    }
  }

  void _style(String style) {
    if (!_current) return;
    try {
      _body.richText = officeToggleRichTextStyle(
        _body.text,
        _body.richText,
        _body.selection,
        style,
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
    _focus.requestFocus();
  }

  void _paragraph(String kind) {
    if (!_current || !_body.selection.isValid) return;
    var selection = _body.selection;
    final first = selection.start == 0
        ? 0
        : _body.text.lastIndexOf('\n', selection.start - 1) + 1;
    var last = selection.end;
    if (last > selection.start && _body.text[last - 1] == '\n') last--;
    final starts = <int>[first];
    for (var i = first; i < last; i++) {
      if (_body.text[i] == '\n') starts.add(i + 1);
    }
    final listPrefix = RegExp(r'^(?:• |\d+\. )');
    final indentation = kind == 'indent' || kind == 'outdent';
    final remove =
        !indentation &&
        starts.every(
          (start) => kind == 'number'
              ? RegExp(r'^\d+\. ').hasMatch(_body.text.substring(start))
              : _body.text.substring(start).startsWith('• '),
        );
    for (var i = starts.length - 1; i >= 0; i--) {
      final start = starts[i];
      final existing = kind == 'indent'
          ? ''
          : kind == 'outdent'
          ? RegExp(r'^(?: {1,2}|\t)')
                    .firstMatch(_body.text.substring(start))
                    ?.group(0) ??
                ''
          : listPrefix.firstMatch(_body.text.substring(start))?.group(0) ?? '';
      final end = start + existing.length;
      final prefix = kind == 'indent'
          ? '  '
          : kind == 'outdent' || remove
          ? ''
          : kind == 'number'
          ? '${i + 1}. '
          : '• ';
      if (existing == prefix) continue;
      final text = _body.text.replaceRange(start, end, prefix);
      final rich = officeRebaseRichText(_body.text, text, _body.richText);
      int shift(int offset) => offset < start
          ? offset
          : offset <= end
          ? start + prefix.length
          : offset + prefix.length - (end - start);
      selection = TextSelection(
        baseOffset: shift(selection.baseOffset),
        extentOffset: shift(selection.extentOffset),
      );
      _body.setRichValue(
        OfficeRichTextValue(content: text, richText: rich),
        selection: selection,
      );
    }
    _focus.requestFocus();
  }

  Widget _tool(String key, String tooltip, Widget icon, VoidCallback? action) =>
      Expanded(
        child: IconButton(
          key: ValueKey('expanded-$key'),
          tooltip: tooltip,
          onPressed: _current && !_busy ? action : null,
          icon: icon,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 42),
          color: const Color(0xff737980),
          disabledColor: const Color(0xffc2c4c5),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final names = _attachments;
    final selected = _body.selection.isValid && !_body.selection.isCollapsed;
    final toolIconSize = widget.mobile ? 27.0 : 21.0;
    final body = Material(
      color: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _current
                        ? TextField(
                            key: const ValueKey('expanded-title'),
                            controller: _title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration: const InputDecoration(
                              hintText: '无标题',
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                          )
                        : const Text('展开编辑'),
                  ),
                  IconButton(
                    key: const ValueKey('expanded-collapse'),
                    tooltip: '收回并保留草稿',
                    onPressed: () => _finish(),
                    icon: const Icon(Icons.close_fullscreen, size: 18),
                  ),
                ],
              ),
            ),
            if (_busy && _front) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_current && (_mentions.isNotEmpty || _mentionAll))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_mentionAll ? '@所有人 ' : ''}${_mentions.length} 位明确提及',
                    style: const TextStyle(fontSize: 11, color: mutedColor),
                  ),
                ),
              ),
            if (names.isNotEmpty)
              SizedBox(
                height: 32,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final name in names)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Chip(
                          label: Text(
                            name,
                            style: const TextStyle(fontSize: 11),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: !_current
                  ? const Center(child: Text('工作身份或会话已变化，请重新打开编辑器。'))
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        key: const ValueKey('expanded-body'),
                        controller: _body,
                        focusNode: _focus,
                        autofocus: true,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(fontSize: 14, height: 1.6),
                        decoration: InputDecoration(
                          hintText:
                              '发送给 ${str((_office.detail?['room'] as Map?)?['name'], '当前会话')}',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: const EdgeInsets.only(top: 8),
                        ),
                      ),
                    ),
            ),
            if (_current)
              Container(
                color: const Color(0xfff8f9fa),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: _formatting
                      ? [
                          _tool(
                            'format-close',
                            '收起文字格式',
                            const Icon(Icons.keyboard_arrow_down, size: 22),
                            () => setState(() => _formatting = false),
                          ),
                          for (final action in [
                            ('bold', '加粗', Icons.format_bold),
                            (
                              'strikethrough',
                              '删除线',
                              Icons.format_strikethrough,
                            ),
                            ('italic', '斜体', Icons.format_italic),
                            ('underline', '下划线', Icons.format_underlined),
                          ])
                            _tool(
                              'format-${action.$1}',
                              action.$2,
                              Icon(action.$3, size: 21),
                              selected ? () => _style(action.$1) : null,
                            ),
                          _tool(
                            'number',
                            '编号列表',
                            const Icon(Icons.format_list_numbered, size: 21),
                            () => _paragraph('number'),
                          ),
                          _tool(
                            'bullet',
                            '项目列表',
                            const Icon(Icons.format_list_bulleted, size: 21),
                            () => _paragraph('bullet'),
                          ),
                          _tool(
                            'send',
                            '发送消息',
                            Icon(
                              Icons.send_rounded,
                              size: toolIconSize,
                              color: _sendable
                                  ? accentColor
                                  : const Color(0xffc2c4c5),
                            ),
                            _sendable ? () => _finish(send: true) : null,
                          ),
                        ]
                      : [
                          _tool(
                            'emoji',
                            '表情',
                            Icon(
                              Icons.sentiment_satisfied_alt,
                              size: toolIconSize,
                            ),
                            _emoji,
                          ),
                          _tool(
                            'mention',
                            '@ 人或 Agent',
                            Icon(Icons.alternate_email, size: toolIconSize),
                            _office.connected ? _pickMentions : null,
                          ),
                          _tool(
                            'images',
                            '图片与附件',
                            Icon(Icons.image_outlined, size: toolIconSize),
                            widget.onPickAttachments == null ? null : _images,
                          ),
                          _tool(
                            'format',
                            '文字格式',
                            const Text('Aa', style: TextStyle(fontSize: 19)),
                            () => setState(() => _formatting = true),
                          ),
                          _tool(
                            'indent',
                            '增加缩进',
                            Icon(
                              Icons.format_indent_increase,
                              size: toolIconSize,
                            ),
                            () => _paragraph('indent'),
                          ),
                          _tool(
                            'outdent',
                            '减少缩进',
                            Icon(
                              Icons.format_indent_decrease,
                              size: toolIconSize,
                            ),
                            () => _paragraph('outdent'),
                          ),
                          _tool(
                            'agent',
                            'Agent 超级入口',
                            Icon(
                              Icons.auto_awesome,
                              size: toolIconSize,
                              color: accentColor,
                            ),
                            _agent,
                          ),
                          _tool(
                            'send',
                            '发送消息',
                            Icon(
                              Icons.send_rounded,
                              size: toolIconSize,
                              color: _sendable
                                  ? accentColor
                                  : const Color(0xffc2c4c5),
                            ),
                            _sendable ? () => _finish(send: true) : null,
                          ),
                        ],
                ),
              ),
            if (!widget.mobile)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => _finish(cancel: true),
                      child: const Text('取消'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _current ? () => _finish() : null,
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    final view = widget.mobile
        ? Dialog.fullscreen(child: body)
        : Dialog(
            child: SizedBox(
              width: 760,
              height: MediaQuery.sizeOf(context).height * .82,
              child: body,
            ),
          );
    return PopScope<OfficeExpandedDraft>(
      canPop: !widget.mobile,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && widget.mobile) _finish();
      },
      child: view,
    );
  }
}
