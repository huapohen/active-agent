import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../office_state.dart' hide Json;
import 'emoji_assets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

String _emojiId(String value) =>
    value.startsWith(':feishu:') && value.endsWith(':')
    ? value.substring(1, value.length - 1)
    : value;

/// Picker results are canonical IDs; only message composition needs tokens.
String officeEmojiText(String id) {
  final normalized = _emojiId(id);
  return officeClassicEmoji.containsKey(normalized) ? ':$normalized:' : id;
}

String officeEmojiLabel(String id) =>
    officeClassicEmoji[_emojiId(id)]?.$1 ?? id;

class OfficeEmojiGlyph extends StatelessWidget {
  const OfficeEmojiGlyph({super.key, required this.id, this.size = 24});
  final String id;
  final double size;
  @override
  Widget build(BuildContext context) {
    final asset = officeClassicEmoji[_emojiId(id)];
    if (asset == null) {
      return Text(
        id,
        style: TextStyle(fontSize: size, height: 1),
        textScaler: TextScaler.noScaling,
      );
    }
    return Image.asset(
      asset.$2,
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: asset.$1,
      errorBuilder: (_, _, _) => SizedBox(
        width: size,
        height: size,
        child: FittedBox(child: Text('[${asset.$1}]')),
      ),
    );
  }
}

/// Unknown tokens remain verbatim. Ordinary messages retain SelectableText.
class OfficeEmojiText extends StatelessWidget {
  const OfficeEmojiText({
    super.key,
    required this.content,
    this.style,
    this.onAction,
    this.selectable = true,
  });
  final String content;
  final TextStyle? style;
  final ValueChanged<String>? onAction;
  final bool selectable;
  static final _tokens = RegExp(r':(feishu:[A-Za-z0-9_-]+):');

  List<ContextMenuButtonItem> _actions(VoidCallback dismiss) => [
    if (onAction != null)
      for (final action in [
        ('reply', '回复'),
        ('forward', '转发'),
        ('menu', '消息操作'),
      ])
        ContextMenuButtonItem(
          label: action.$2,
          onPressed: () {
            dismiss();
            onAction!(action.$1);
          },
        ),
  ];

  @override
  Widget build(BuildContext context) {
    final matches = _tokens
        .allMatches(content)
        .where((match) => officeClassicEmoji.containsKey(match.group(1)))
        .toList();
    if (matches.isEmpty) {
      if (!selectable) return Text(content, style: style);
      return onAction == null
          ? SelectableText(content, style: style)
          : SelectableText(
              content,
              style: style,
              contextMenuBuilder: (context, editable) =>
                  AdaptiveTextSelectionToolbar.buttonItems(
                    anchors: editable.contextMenuAnchors,
                    buttonItems: [
                      ...editable.contextMenuButtonItems,
                      ..._actions(editable.hideToolbar),
                    ],
                  ),
            );
    }
    final spans = <InlineSpan>[];
    var offset = 0;
    final size =
        MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 14) * 1.85;
    for (final match in matches) {
      if (match.start > offset) {
        spans.add(TextSpan(text: content.substring(offset, match.start)));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: OfficeEmojiGlyph(id: match.group(1)!, size: size),
        ),
      );
      offset = match.end;
    }
    if (offset < content.length) {
      spans.add(TextSpan(text: content.substring(offset)));
    }
    final text = Text.rich(TextSpan(children: spans), style: style);
    if (!selectable) return text;
    return onAction == null
        ? SelectionArea(child: text)
        : SelectionArea(
            contextMenuBuilder: (context, selection) =>
                AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: selection.contextMenuAnchors,
                  buttonItems: [
                    ...selection.contextMenuButtonItems,
                    ..._actions(selection.hideToolbar),
                  ],
                ),
            child: text,
          );
  }
}

class _EmojiEntry {
  _EmojiEntry(Json json)
    : id = str(json['id']),
      name = str(json['name']),
      category = str(json['category']),
      search = [
        json['id'],
        json['name'],
        json['code'],
        ...json['aliases'] as List? ?? [],
      ].whereType<String>().join(' ').toLowerCase();
  final String id, name, category, search;
}

class _EmojiCatalog {
  _EmojiCatalog(Json json)
    : categories = (json['categories'] as List).cast<String>(),
      entries = maps(json['entries']).map(_EmojiEntry.new).toList();
  final List<String> categories;
  final List<_EmojiEntry> entries;
}

Future<_EmojiCatalog>? _catalogCache;
_EmojiCatalog? _catalogValue;
Future<_EmojiCatalog> _catalog() {
  if (_catalogValue != null) return Future.value(_catalogValue);
  return _catalogCache ??= () async {
    try {
      final bytes = await rootBundle.load('assets/emoji/catalog.json');
      final content = utf8.decode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      final catalog = _EmojiCatalog(Json.from(jsonDecode(content) as Map));
      _catalogValue = catalog;
      return catalog;
    } catch (_) {
      _catalogCache = null;
      rethrow;
    }
  }();
}

class OfficeEmojiPicker extends StatefulWidget {
  const OfficeEmojiPicker({
    super.key,
    required this.state,
    required this.onSelected,
    this.width,
    this.height,
  });
  final OfficeState state;
  final ValueChanged<String> onSelected;
  final double? width, height;
  @override
  State<OfficeEmojiPicker> createState() => _OfficeEmojiPickerState();
}

class _OfficeEmojiPickerState extends State<OfficeEmojiPicker> {
  final _query = TextEditingController();
  late final (OfficeState, int, String, String) _identity;
  _EmojiCatalog? _data;
  String _category = '经典表情';
  List<String> _recents = [];
  String? _catalogError, _recentError, _retryEmoji;
  bool _expired = false, _recentBusy = false;
  bool _clearing = false, _retryClear = false;
  int _recording = 0;
  int _recentIntent = 0;
  OfficeState get s => widget.state;
  (OfficeState, int, String, String) get _currentIdentity =>
      (s, s.identityGeneration, s.endpoint, personId(s.me ?? {}));
  bool get _current =>
      !_expired && s.me != null && _identity == _currentIdentity;
  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    s.addListener(_changed);
    _loadCatalog();
    _loadRecents();
  }

  @override
  void didUpdateWidget(covariant OfficeEmojiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) _changed();
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) {
      _expired = true;
      _recentIntent++;
      _recents = [];
      _recentError = _retryEmoji = null;
      _query.clear();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _identity.$1.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    if (mounted) setState(() => _catalogError = null);
    try {
      final data = await _catalog();
      if (mounted && _current) setState(() => _data = data);
    } catch (_) {
      if (mounted && _current) setState(() => _catalogError = '表情目录加载失败');
    }
  }

  Future<void> _loadRecents() async {
    if (!_current || !s.connected || _recentBusy) return;
    final intent = ++_recentIntent;
    setState(() {
      _recentBusy = true;
      _recentError = null;
    });
    try {
      final result = await s.officeRequest('/emoji/recents');
      if (mounted && _current && intent == _recentIntent) {
        setState(
          () => _recents = (result['emoji_ids'] as List? ?? [])
              .whereType<String>()
              .toList(),
        );
      }
    } catch (error) {
      if (mounted && _current && intent == _recentIntent) {
        setState(() => _recentError = friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _recentBusy = false);
    }
  }

  void _choose(String id) {
    if (!_current || _clearing) return;
    setState(
      () => _recents = [
        id,
        ..._recents.where((recent) => recent != id),
      ].take(32).toList(),
    );
    if (s.connected) _record(id);
    widget.onSelected(id);
  }

  void _record(String id) {
    if (!_current || !s.connected) return;
    final intent = ++_recentIntent;
    _recording++;
    // Start the identity-bound request before a modal selection closes us.
    final request = s.officeRequest(
      '/emoji/recents',
      method: 'POST',
      data: {'emoji': id},
    );
    unawaited(() async {
      try {
        final result = await request;
        if (mounted && _current && intent == _recentIntent) {
          setState(() {
            _recents = (result['emoji_ids'] as List? ?? [])
                .whereType<String>()
                .toList();
            _recentError = _retryEmoji = null;
            _retryClear = false;
          });
        }
      } catch (error) {
        if (mounted && _current && intent == _recentIntent) {
          setState(() {
            _recentError = '表情已选择，最近使用未同步：${friendlyError(error)}';
            _retryEmoji = id;
            _retryClear = false;
          });
        }
      } finally {
        if (mounted) setState(() => _recording--);
      }
    }());
  }

  Future<void> _clearRecents() async {
    if (!_current || !s.connected || _recentBusy || _recording > 0) return;
    final intent = ++_recentIntent;
    setState(() {
      _recentBusy = _clearing = true;
      _recentError = null;
    });
    try {
      await s.officeRequest('/emoji/recents', method: 'DELETE');
      if (mounted && _current && intent == _recentIntent) {
        setState(() {
          _recents = [];
          _retryEmoji = null;
          _retryClear = false;
        });
      }
    } catch (error) {
      if (mounted && _current && intent == _recentIntent) {
        setState(() {
          _recentError = '最近使用未清空：${friendlyError(error)}';
          _retryClear = true;
        });
      }
    } finally {
      if (mounted) setState(() => _recentBusy = _clearing = false);
    }
  }

  List<_EmojiEntry> get _entries {
    final data = _data;
    if (data == null) return [];
    final query = _query.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      return data.entries
          .where((entry) => entry.search.contains(query))
          .toList();
    }
    if (_category == '最近使用') {
      final byId = {for (final entry in data.entries) entry.id: entry};
      return [
        for (final id in _recents)
          if (byId[id] != null) byId[id]!,
      ];
    }
    return _category == '全部'
        ? data.entries
        : data.entries.where((entry) => entry.category == _category).toList();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width ?? 440,
    height: widget.height ?? 420,
    child: Material(
      color: Colors.white,
      child: !_current
          ? const Center(child: Text('工作身份已变化，请重新打开表情。'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: TextField(
                    controller: _query,
                    decoration: const InputDecoration(
                      hintText: '搜索表情（中文 / English）',
                      prefixIcon: Icon(Icons.search, size: 20),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      for (final category in [
                        '最近使用',
                        '全部',
                        ...?_data?.categories,
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(
                              category,
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: _category == category,
                            showCheckmark: false,
                            onSelected: (_) {
                              setState(() {
                                _category = category;
                                _query.clear();
                              });
                              if (category == '最近使用') _loadRecents();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                if (_recentError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _recentError!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.redAccent,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: s.connected && !_recentBusy
                              ? () => _retryClear
                                    ? _clearRecents()
                                    : _retryEmoji == null
                                    ? _loadRecents()
                                    : _record(_retryEmoji!)
                              : null,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                if (_category == '最近使用')
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed:
                          s.connected &&
                              !_recentBusy &&
                              _recording == 0 &&
                              _recents.isNotEmpty
                          ? _clearRecents
                          : null,
                      child: const Text(
                        '清空最近使用',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                if (!s.connected)
                  const Padding(
                    padding: EdgeInsets.all(6),
                    child: Text(
                      '离线可选表情，最近使用暂未同步。',
                      style: TextStyle(fontSize: 10, color: mutedColor),
                    ),
                  ),
                Expanded(
                  child: _data == null
                      ? Center(
                          child: _catalogError == null
                              ? const CircularProgressIndicator()
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_catalogError!),
                                    TextButton(
                                      onPressed: _loadCatalog,
                                      child: const Text('重试加载目录'),
                                    ),
                                  ],
                                ),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final entries = _entries;
                            if (entries.isEmpty) {
                              return Center(
                                child: Text(
                                  _category == '最近使用' && _query.text.isEmpty
                                      ? '还没有最近使用的表情'
                                      : '没有匹配的表情',
                                  style: const TextStyle(color: mutedColor),
                                ),
                              );
                            }
                            return GridView.builder(
                              key: ValueKey(
                                'emoji-grid-$_category-${_query.text}',
                              ),
                              padding: const EdgeInsets.all(10),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount:
                                        ((constraints.maxWidth - 20) / 46)
                                            .floor()
                                            .clamp(3, 12),
                                    mainAxisExtent: 46,
                                  ),
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                return Tooltip(
                                  key: ValueKey('emoji-${entry.id}'),
                                  waitDuration: const Duration(
                                    milliseconds: 350,
                                  ),
                                  richMessage: WidgetSpan(
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          OfficeEmojiGlyph(
                                            id: entry.id,
                                            size: 54,
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            entry.name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  child: Semantics(
                                    label: entry.name,
                                    button: true,
                                    child: InkWell(
                                      onTap: _clearing
                                          ? null
                                          : () => _choose(entry.id),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Center(
                                        child: OfficeEmojiGlyph(
                                          id: entry.id,
                                          size: 28,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
    ),
  );
}

Future<String?> showOfficeEmojiPicker(BuildContext context, OfficeState state) {
  final mobile = MediaQuery.sizeOf(context).width < 760;
  Widget content(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 6, 0),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '表情',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: '关闭表情',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
      ),
      Flexible(
        child: OfficeEmojiPicker(
          state: state,
          width: mobile ? MediaQuery.sizeOf(context).width : 440,
          height: mobile ? MediaQuery.sizeOf(context).height * .55 : 420,
          onSelected: (id) => Navigator.pop(context, id),
        ),
      ),
    ],
  );
  if (mobile) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SafeArea(child: content(context)),
    );
  }
  return showDialog<String>(
    context: context,
    builder: (context) =>
        Dialog(child: SizedBox(width: 440, child: content(context))),
  );
}
