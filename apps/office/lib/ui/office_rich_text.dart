import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'emoji_assets.dart';
import 'office_emoji.dart';
import 'office_theme.dart';

const officeRichTextStyles = ['bold', 'italic', 'underline', 'strikethrough'];
const _maxSpans = 200;

class OfficeRichTextValue {
  const OfficeRichTextValue({required this.content, this.richText});
  final String content;
  final Json? richText;
}

bool _boundary(String content, int offset) =>
    offset >= 0 &&
    offset <= content.length &&
    !(offset > 0 &&
        offset < content.length &&
        content.codeUnitAt(offset - 1) >= 0xd800 &&
        content.codeUnitAt(offset - 1) <= 0xdbff &&
        content.codeUnitAt(offset) >= 0xdc00 &&
        content.codeUnitAt(offset) <= 0xdfff);

/// Matches the native version-1 UTF-16 contract. Invalid documents degrade as a
/// whole; no silently discarded malformed span can change the intended meaning.
Json? officeNormalizeRichText(String content, dynamic richText) {
  if (richText == null) return null;
  if (richText is! Map ||
      richText.keys.any((key) => key != 'version' && key != 'spans') ||
      richText['version'] != 1 ||
      richText['spans'] is! List) {
    return null;
  }
  final raw = richText['spans'] as List;
  if (raw.isEmpty || raw.length > _maxSpans) return null;
  final spans = <Json>[];
  for (final span in raw) {
    if (span is! Map ||
        span.keys.any((key) => !['start', 'end', 'styles'].contains(key)) ||
        span['start'] is! int ||
        span['end'] is! int ||
        span['styles'] is! List) {
      return null;
    }
    final start = span['start'] as int, end = span['end'] as int;
    final styles = span['styles'] as List;
    if (start >= end ||
        !_boundary(content, start) ||
        !_boundary(content, end) ||
        styles.isEmpty ||
        styles.length > 4 ||
        styles.any((style) => !officeRichTextStyles.contains(style))) {
      return null;
    }
    spans.add({
      'start': start,
      'end': end,
      'styles': [
        for (final style in officeRichTextStyles)
          if (styles.contains(style)) style,
      ],
    });
  }
  spans.sort((a, b) {
    final byStart = (a['start'] as int).compareTo(b['start'] as int);
    if (byStart != 0) return byStart;
    final byEnd = (a['end'] as int).compareTo(b['end'] as int);
    return byEnd != 0
        ? byEnd
        : (a['styles'] as List)
              .join(',')
              .compareTo((b['styles'] as List).join(','));
  });
  final unique = <Json>[];
  for (final span in spans) {
    if (unique.isEmpty ||
        unique.last['start'] != span['start'] ||
        unique.last['end'] != span['end'] ||
        (unique.last['styles'] as List).join(',') !=
            (span['styles'] as List).join(',')) {
      unique.add(span);
    }
  }
  return {'version': 1, 'spans': unique};
}

List<Json> _spans(Json? richText) => (richText?['spans'] as List? ?? [])
    .map((item) => Json.from(item as Map))
    .toList();

/// Rebase one contiguous text edit, inferred from the unchanged prefix/suffix.
/// Insertion inside a styled run inherits that run. Insertion at its boundary
/// does not make unrelated following text styled. Replacements wholly inside
/// a styled range retain that range's styles; deleted styles do not leak out.
Json? officeRebaseRichText(
  String oldContent,
  String newContent,
  Json? richText,
) {
  final normalized = officeNormalizeRichText(oldContent, richText);
  if (normalized == null || oldContent == newContent) return normalized;
  var start = 0;
  while (start < oldContent.length &&
      start < newContent.length &&
      oldContent.codeUnitAt(start) == newContent.codeUnitAt(start)) {
    start++;
  }
  while (!_boundary(oldContent, start) || !_boundary(newContent, start)) {
    start--;
  }
  var suffix = 0;
  while (suffix < oldContent.length - start &&
      suffix < newContent.length - start &&
      oldContent.codeUnitAt(oldContent.length - suffix - 1) ==
          newContent.codeUnitAt(newContent.length - suffix - 1)) {
    suffix++;
  }
  while (!_boundary(oldContent, oldContent.length - suffix) ||
      !_boundary(newContent, newContent.length - suffix)) {
    suffix--;
  }
  return _rebaseEdit(
    oldContent,
    newContent,
    normalized,
    start,
    oldContent.length - suffix,
    newContent.length - suffix,
  );
}

Json? _rebaseEdit(
  String before,
  String after,
  Json? richText,
  int start,
  int oldEnd,
  int newEnd,
) {
  final output = <Json>[];
  final delta = newEnd - oldEnd;
  for (final span in _spans(richText)) {
    final a = span['start'] as int, b = span['end'] as int;
    final pieces = <(int, int)>[];
    if (a < start) pieces.add((a, b < start ? b : start));
    final inherited = oldEnd == start
        ? a < start && b > start
        : a <= start && b >= oldEnd;
    if (inherited && newEnd > start) pieces.add((start, newEnd));
    if (b > oldEnd) pieces.add(((a > oldEnd ? a : oldEnd) + delta, b + delta));
    // A source span produces at most one contiguous retained run: replacements
    // that leave both sides also inherit their style in the inserted segment.
    for (final piece in pieces) {
      if (piece.$1 >= piece.$2) continue;
      if (output.isNotEmpty &&
          output.last['end'] == piece.$1 &&
          (output.last['styles'] as List).join(',') ==
              (span['styles'] as List).join(',')) {
        output.last['end'] = piece.$2;
      } else {
        output.add({
          'start': piece.$1,
          'end': piece.$2,
          'styles': [...span['styles'] as List],
        });
      }
    }
  }
  return officeNormalizeRichText(after, {'version': 1, 'spans': output});
}

OfficeRichTextValue officeTrimRichText(String content, Json? richText) {
  final trimmed = content.trim();
  final left = content.length - content.trimLeft().length;
  final right = left + trimmed.length;
  final output = <Json>[];
  for (final span in _spans(officeNormalizeRichText(content, richText))) {
    final start = (span['start'] as int).clamp(left, right);
    final end = (span['end'] as int).clamp(left, right);
    if (start < end) {
      output.add({
        'start': start - left,
        'end': end - left,
        'styles': span['styles'],
      });
    }
  }
  return OfficeRichTextValue(
    content: trimmed,
    richText: officeNormalizeRichText(trimmed, {'version': 1, 'spans': output}),
  );
}

class _Run {
  const _Run(this.start, this.end, this.styles);
  final int start, end;
  final Set<String> styles;
}

List<_Run> _runs(String content, Json? richText) {
  final events = <int, Map<String, int>>{0: {}, content.length: {}};
  for (final span in _spans(richText)) {
    for (final (position, delta) in [
      (span['start'] as int, 1),
      (span['end'] as int, -1),
    ]) {
      final event = events.putIfAbsent(position, () => {});
      for (final style in (span['styles'] as List).cast<String>()) {
        event[style] = (event[style] ?? 0) + delta;
      }
    }
  }
  final points = events.keys.toList()..sort();
  final active = <String, int>{};
  final result = <_Run>[];
  var previous = 0;
  for (final point in points) {
    if (point > previous) {
      result.add(
        _Run(previous, point, {
          for (final style in officeRichTextStyles)
            if ((active[style] ?? 0) > 0) style,
        }),
      );
    }
    for (final event in events[point]!.entries) {
      active[event.key] = (active[event.key] ?? 0) + event.value;
    }
    previous = point;
  }
  return result;
}

TextStyle _style(Set<String> styles) => TextStyle(
  fontWeight: styles.contains('bold') ? FontWeight.w700 : null,
  fontStyle: styles.contains('italic') ? FontStyle.italic : null,
  decoration: TextDecoration.combine([
    if (styles.contains('underline')) TextDecoration.underline,
    if (styles.contains('strikethrough')) TextDecoration.lineThrough,
  ]),
);

List<InlineSpan> _textSpans(
  String content,
  Json? richText, {
  int start = 0,
  int? end,
}) => [
  for (final run in _runs(content, richText))
    if (run.end > start && run.start < (end ?? content.length))
      TextSpan(
        text: content.substring(
          run.start < start ? start : run.start,
          run.end > (end ?? content.length) ? (end ?? content.length) : run.end,
        ),
        style: _style(run.styles),
      ),
];

/// Toggle a real style over a safe selection, preserving unselected styles.
/// An invalid/collapsed selection is a no-op. A fragment-limit conflict throws
/// FormatException so callers can retain the previous value and explain it.
Json? officeToggleRichTextStyle(
  String content,
  Json? richText,
  TextSelection selection,
  String style,
) {
  final normalized = officeNormalizeRichText(content, richText);
  if (!officeRichTextStyles.contains(style)) {
    throw const FormatException('不支持此文字格式');
  }
  if (!selection.isValid ||
      selection.isCollapsed ||
      !_boundary(content, selection.start) ||
      !_boundary(content, selection.end)) {
    return normalized;
  }
  final remove = _runs(content, normalized)
      .where((run) => run.end > selection.start && run.start < selection.end)
      .every((run) => run.styles.contains(style));
  final spans = <Json>[];
  for (final run in _runs(content, normalized)) {
    final points = {
      run.start,
      run.end,
      selection.start.clamp(run.start, run.end),
      selection.end.clamp(run.start, run.end),
    }.toList()..sort();
    for (var i = 1; i < points.length; i++) {
      final start = points[i - 1], end = points[i];
      if (start == end) continue;
      final styles = {...run.styles};
      if (start >= selection.start && end <= selection.end) {
        if (remove) {
          styles.remove(style);
        } else {
          styles.add(style);
        }
      }
      if (styles.isEmpty) continue;
      final ordered = [
        for (final s in officeRichTextStyles)
          if (styles.contains(s)) s,
      ];
      if (spans.isNotEmpty &&
          spans.last['end'] == start &&
          (spans.last['styles'] as List).join(',') == ordered.join(',')) {
        spans.last['end'] = end;
      } else {
        spans.add({'start': start, 'end': end, 'styles': ordered});
      }
    }
  }
  if (spans.length > _maxSpans) {
    throw const FormatException('格式片段过多，请先清除部分格式。');
  }
  return officeNormalizeRichText(content, {'version': 1, 'spans': spans});
}

class OfficeRichText extends StatelessWidget {
  const OfficeRichText({
    super.key,
    required this.content,
    this.richText,
    this.style,
    this.selectable = true,
    this.onAction,
    this.onOpenMessageMenu,
  });
  final String content;
  final Json? richText;
  final TextStyle? style;
  final bool selectable;
  final ValueChanged<String>? onAction;
  final ValueChanged<Offset>? onOpenMessageMenu;
  @override
  Widget build(BuildContext context) {
    final normalized = officeNormalizeRichText(content, richText);
    if (normalized == null) {
      return OfficeEmojiText(
        content: content,
        style: style,
        selectable: selectable,
        onAction: onAction,
        onOpenMessageMenu: onOpenMessageMenu,
      );
    }
    final spans = <InlineSpan>[];
    var offset = 0;
    final size =
        MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 14) * 1.85;
    for (final match in RegExp(
      r':(feishu:[A-Za-z0-9_-]+):',
    ).allMatches(content)) {
      if (!officeClassicEmoji.containsKey(match.group(1))) continue;
      spans.addAll(
        _textSpans(content, normalized, start: offset, end: match.start),
      );
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: OfficeEmojiGlyph(id: match.group(1)!, size: size),
        ),
      );
      offset = match.end;
    }
    spans.addAll(_textSpans(content, normalized, start: offset));
    final text = Text.rich(TextSpan(children: spans), style: style);
    if (!selectable) return text;
    return SelectionArea(
      contextMenuBuilder: (context, selection) {
        if (onOpenMessageMenu != null) {
          return _RichMenuRedirect(
            position: selection.contextMenuAnchors.primaryAnchor,
            dismiss: selection.hideToolbar,
            open: onOpenMessageMenu!,
          );
        }
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: selection.contextMenuAnchors,
          buttonItems: [
            ...selection.contextMenuButtonItems,
            if (onAction != null)
              for (final action in [
                ('reply', '回复'),
                ('forward', '转发'),
                ('menu', '消息操作'),
              ])
                ContextMenuButtonItem(
                  label: action.$2,
                  onPressed: () {
                    selection.hideToolbar();
                    onAction!(action.$1);
                  },
                ),
          ],
        );
      },
      child: text,
    );
  }
}

class _RichMenuRedirect extends StatefulWidget {
  const _RichMenuRedirect({
    required this.position,
    required this.dismiss,
    required this.open,
  });
  final Offset position;
  final VoidCallback dismiss;
  final ValueChanged<Offset> open;
  @override
  State<_RichMenuRedirect> createState() => _RichMenuRedirectState();
}

class _RichMenuRedirectState extends State<_RichMenuRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final callback = widget.open, position = widget.position;
      widget.dismiss();
      callback(position);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// A real styled editing surface. Keyboard edits rebase spans automatically;
/// restoring a draft or applying an editor result should use setRichValue so
/// content and formatting change together in one notification.
class OfficeRichTextEditingController extends TextEditingController {
  OfficeRichTextEditingController({String text = '', Json? richText})
    : _richText = officeNormalizeRichText(text, richText),
      super(text: text);
  Json? _richText;
  Json? get richText => officeNormalizeRichText(text, _richText);
  set richText(Json? next) {
    _richText = officeNormalizeRichText(text, next);
    notifyListeners();
  }

  @override
  set value(TextEditingValue next) {
    if (next.text != text) {
      _richText = officeRebaseRichText(text, next.text, _richText);
    }
    super.value = next;
  }

  void setRichValue(OfficeRichTextValue document, {TextSelection? selection}) {
    int safe(int offset) {
      var value = offset.clamp(0, document.content.length);
      if (!_boundary(document.content, value)) value--;
      return value;
    }

    final selected =
        selection ?? TextSelection.collapsed(offset: document.content.length);
    _richText = officeNormalizeRichText(document.content, document.richText);
    final next = TextEditingValue(
      text: document.content,
      selection: TextSelection(
        baseOffset: safe(selected.baseOffset),
        extentOffset: safe(selected.extentOffset),
        affinity: selected.affinity,
        isDirectional: selected.isDirectional,
      ),
    );
    if (next == value) {
      notifyListeners();
    } else {
      super.value = next;
    }
  }

  void replace(OfficeRichTextValue document, TextSelection selection) =>
      setRichValue(document, selection: selection);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final spans = <Json>[..._spans(richText)];
    if (withComposing &&
        value.isComposingRangeValid &&
        !value.composing.isCollapsed) {
      spans.add({
        'start': value.composing.start,
        'end': value.composing.end,
        'styles': ['underline'],
      });
    }
    return TextSpan(
      style: style,
      children: _textSpans(text, {'version': 1, 'spans': spans}),
    );
  }
}

Future<OfficeRichTextValue?> showOfficeRichTextEditor(
  BuildContext context, {
  required String content,
  Json? richText,
  OfficeState? state,
  bool Function()? sourceIsCurrent,
}) => showDialog<OfficeRichTextValue>(
  context: context,
  builder: (_) => OfficeRichTextEditor(
    content: content,
    richText: richText,
    state: state,
    sourceIsCurrent: sourceIsCurrent,
  ),
);

class OfficeRichTextEditor extends StatefulWidget {
  const OfficeRichTextEditor({
    super.key,
    required this.content,
    this.richText,
    this.state,
    this.sourceIsCurrent,
  });
  final String content;
  final Json? richText;
  final OfficeState? state;

  /// Rechecked on state events and before completion. A source-bound editor
  /// must expire when its message is withdrawn, even in the same identity.
  final bool Function()? sourceIsCurrent;
  @override
  State<OfficeRichTextEditor> createState() => _OfficeRichTextEditorState();
}

class _OfficeRichTextEditorState extends State<OfficeRichTextEditor> {
  late final OfficeRichTextEditingController _controller;
  final _focus = FocusNode();
  bool _preview = false, _closed = false, _expired = false;
  bool _sourceExpired = false;
  late final OfficeState? _boundState;
  late final (int, String, String, String?)? _identity;
  (int, String, String, String?) _scope(OfficeState state) => (
    state.identityGeneration,
    state.endpoint,
    personId(state.me ?? {}),
    state.selectedRoomId,
  );
  bool get _identityCurrent =>
      _boundState == null ||
      identical(_boundState, widget.state) &&
          _boundState.me != null &&
          _identity == _scope(_boundState);
  bool get _sourceCurrent => widget.sourceIsCurrent?.call() != false;
  bool get _current => !_expired && _identityCurrent && _sourceCurrent;
  String? _error;
  @override
  void initState() {
    super.initState();
    _boundState = widget.state;
    _identity = _boundState == null ? null : _scope(_boundState);
    _controller = OfficeRichTextEditingController(
      text: widget.content,
      richText: widget.richText,
    );

    _controller.addListener(_changed);
    _boundState?.addListener(_scopeChanged);
    _scopeChanged();
  }

  void _scopeChanged() {
    if (!mounted || _current || _expired) return;
    _sourceExpired = _identityCurrent && !_sourceCurrent;
    _expired = true;
    _preview = false;
    _focus.unfocus();
    _controller.replace(
      const OfficeRichTextValue(content: ''),
      const TextSelection.collapsed(offset: 0),
    );
    setState(() => _error = null);
  }

  @override
  void didUpdateWidget(covariant OfficeRichTextEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scopeChanged();
  }

  void _changed() {
    if (mounted) setState(() => _error = null);
  }

  @override
  void dispose() {
    _boundState?.removeListener(_scopeChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _selectionValid =>
      _current &&
      _controller.selection.isValid &&
      _boundary(_controller.text, _controller.selection.start) &&
      _boundary(_controller.text, _controller.selection.end);
  bool _selectedStyle(String style) {
    final selected = _controller.selection;
    if (!_selectionValid || selected.isCollapsed) return false;
    return _runs(_controller.text, _controller.richText)
        .where((run) => run.end > selected.start && run.start < selected.end)
        .every((run) => run.styles.contains(style));
  }

  void _format(String style) {
    if (!_selectionValid || _controller.selection.isCollapsed) return;
    final selected = _controller.selection;
    try {
      final rich = officeToggleRichTextStyle(
        _controller.text,
        _controller.richText,
        selected,
        style,
      );
      _controller.replace(
        OfficeRichTextValue(content: _controller.text, richText: rich),
        selected,
      );
      _focus.requestFocus();
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _list(bool numbered) {
    if (!_selectionValid) return;
    var document = OfficeRichTextValue(
      content: _controller.text,
      richText: _controller.richText,
    );
    var selection = _controller.selection;
    final first = selection.start == 0
        ? 0
        : document.content.lastIndexOf('\n', selection.start - 1) + 1;
    var last = selection.end;
    if (last > selection.start && document.content[last - 1] == '\n') last--;
    final starts = <int>[first];
    for (var i = first; i < last; i++) {
      if (document.content[i] == '\n') starts.add(i + 1);
    }
    final prefix = RegExp(r'^(?:• |\d+\. )');
    final remove = starts.every(
      (start) => numbered
          ? RegExp(r'^\d+\. ').hasMatch(document.content.substring(start))
          : document.content.substring(start).startsWith('• '),
    );
    for (var i = starts.length - 1; i >= 0; i--) {
      final start = starts[i];
      final match = prefix.firstMatch(document.content.substring(start));
      final end = start + (match?.end ?? 0);
      final replacement = remove
          ? ''
          : numbered
          ? '${i + 1}. '
          : '• ';
      final content = document.content.replaceRange(start, end, replacement);
      final rich = _rebaseEdit(
        document.content,
        content,
        document.richText,
        start,
        end,
        start + replacement.length,
      );
      int translate(int offset) => offset < start
          ? offset
          : offset <= end
          ? start + replacement.length
          : offset + replacement.length - (end - start);
      selection = TextSelection(
        baseOffset: translate(selection.baseOffset),
        extentOffset: translate(selection.extentOffset),
      );
      document = OfficeRichTextValue(content: content, richText: rich);
    }
    _controller.replace(document, selection);
    _focus.requestFocus();
  }

  void _close({bool save = false}) {
    if (_closed || ModalRoute.of(context)?.isCurrent != true) return;
    if (save && !_current) {
      _scopeChanged();
      return;
    }
    if (save && _controller.text.length > 12000) {
      setState(() => _error = '正文最多 12000 个字符。');
      return;
    }
    _closed = true;
    Navigator.pop(
      context,
      save
          ? OfficeRichTextValue(
              content: _controller.text,
              richText: officeNormalizeRichText(
                _controller.text,
                _controller.richText,
              ),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '文字排版',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '取消排版',
                onPressed: _close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            children: [
              for (final action in [
                ('bold', '加粗', Icons.format_bold),
                ('italic', '斜体', Icons.format_italic),
                ('underline', '下划线', Icons.format_underlined),
                ('strikethrough', '删除线', Icons.format_strikethrough),
              ])
                IconButton(
                  key: ValueKey('rich-format-${action.$1}'),
                  tooltip: action.$2,
                  isSelected: _selectedStyle(action.$1),
                  onPressed:
                      !_preview &&
                          _selectionValid &&
                          !_controller.selection.isCollapsed
                      ? () => _format(action.$1)
                      : null,
                  icon: Icon(action.$3),
                ),
              IconButton(
                key: const ValueKey('rich-list-bullet'),
                tooltip: '项目列表',
                onPressed: !_preview && _selectionValid
                    ? () => _list(false)
                    : null,
                icon: const Icon(Icons.format_list_bulleted),
              ),
              IconButton(
                key: const ValueKey('rich-list-numbered'),
                tooltip: '编号列表',
                onPressed: !_preview && _selectionValid
                    ? () => _list(true)
                    : null,
                icon: const Icon(Icons.format_list_numbered),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: !_current
                ? Center(
                    child: Text(
                      _sourceExpired
                          ? '来源消息已变化，请关闭文字排版'
                          : '工作身份或会话已变化，请重新打开文字排版',
                    ),
                  )
                : _preview
                ? SingleChildScrollView(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: OfficeRichText(
                        content: _controller.text,
                        richText: _controller.richText,
                      ),
                    ),
                  )
                : TextField(
                    key: const ValueKey('rich-editor-content'),
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: true,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 14, height: 1.6),
                    decoration: const InputDecoration(
                      hintText: '输入正文，选中文字后设置格式',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(
            children: [
              TextButton(onPressed: _close, child: const Text('取消')),
              TextButton(
                onPressed: !_current
                    ? null
                    : () => setState(() {
                        _preview = !_preview;
                        _focus.unfocus();
                      }),
                child: Text(_preview ? '继续编辑' : '预览'),
              ),
              const Spacer(),
              FilledButton(
                key: const ValueKey('rich-editor-save'),
                onPressed: _current ? () => _close(save: true) : null,
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ],
    );
    if (MediaQuery.sizeOf(context).width < 600) {
      return Dialog.fullscreen(child: SafeArea(child: body));
    }
    return Dialog(
      child: SizedBox(
        width: 680,
        height: MediaQuery.sizeOf(context).height * .76,
        child: body,
      ),
    );
  }
}
