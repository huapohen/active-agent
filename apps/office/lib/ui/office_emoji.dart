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
    this.onOpenMessageMenu,
    this.selectable = true,
  });
  final String content;
  final TextStyle? style;
  final ValueChanged<String>? onAction;
  final ValueChanged<Offset>? onOpenMessageMenu;
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
      return onAction == null && onOpenMessageMenu == null
          ? SelectableText(content, style: style)
          : SelectableText(
              content,
              style: style,
              contextMenuBuilder: (_, editable) => onOpenMessageMenu != null
                  ? _OfficeMessageMenuRedirect(
                      sourceContext: context,
                      dismiss: editable.hideToolbar,
                      position: editable.contextMenuAnchors.primaryAnchor,
                      onOpen: onOpenMessageMenu!,
                    )
                  : AdaptiveTextSelectionToolbar.buttonItems(
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
    return onAction == null && onOpenMessageMenu == null
        ? SelectionArea(child: text)
        : SelectionArea(
            contextMenuBuilder: (_, selection) => onOpenMessageMenu != null
                ? _OfficeMessageMenuRedirect(
                    sourceContext: context,
                    dismiss: selection.hideToolbar,
                    position: selection.contextMenuAnchors.primaryAnchor,
                    onOpen: onOpenMessageMenu!,
                  )
                : AdaptiveTextSelectionToolbar.buttonItems(
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

/// Text selection owns a secondary click before the message's outer gesture
/// region. Hand the same anchor to the full menu after the overlay's frame.
class _OfficeMessageMenuRedirect extends StatefulWidget {
  const _OfficeMessageMenuRedirect({
    required this.sourceContext,
    required this.dismiss,
    required this.position,
    required this.onOpen,
  });
  final BuildContext sourceContext;
  final VoidCallback dismiss;
  final Offset position;
  final ValueChanged<Offset> onOpen;
  @override
  State<_OfficeMessageMenuRedirect> createState() =>
      _OfficeMessageMenuRedirectState();
}

class _OfficeMessageMenuRedirectState
    extends State<_OfficeMessageMenuRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.sourceContext.mounted) return;
      final onOpen = widget.onOpen, position = widget.position;
      widget.dismiss();
      onOpen(position);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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
    this.scrollController,
    this.showDragHandle = false,
    this.onClose,
  });
  final OfficeState state;
  final ValueChanged<String> onSelected;
  final double? width, height;
  final ScrollController? scrollController;
  final bool showDragHandle;
  final VoidCallback? onClose;
  @override
  State<OfficeEmojiPicker> createState() => _OfficeEmojiPickerState();
}

class _OfficeEmojiPickerState extends State<OfficeEmojiPicker> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  bool _searchOpen = false, _library = false;
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
    _scroll.dispose();
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

  List<_EmojiEntry> get _recentEntries {
    final byId = {
      for (final entry in _data?.entries ?? <_EmojiEntry>[]) entry.id: entry,
    };
    return [
      for (final id in _recents)
        if (byId[id] != null) byId[id]!,
    ];
  }

  void _navigate(String category, {bool library = false}) {
    setState(() {
      _category = category;
      _library = library;
      _searchOpen = false;
      _query.clear();
    });
    final scroll = widget.scrollController ?? _scroll;
    if (scroll.hasClients) scroll.jumpTo(0);
    if (category == '最近使用') _loadRecents();
  }

  Widget _tile(_EmojiEntry entry, {bool recentShortcut = false}) => Tooltip(
    key: ValueKey('emoji-${recentShortcut ? 'recent-' : ''}${entry.id}'),
    waitDuration: const Duration(milliseconds: 350),
    richMessage: WidgetSpan(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OfficeEmojiGlyph(id: entry.id, size: 54),
            const SizedBox(height: 6),
            Text(
              entry.name,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
    child: Semantics(
      label: entry.name,
      button: true,
      child: InkWell(
        onTap: _clearing ? null : () => _choose(entry.id),
        borderRadius: BorderRadius.circular(6),
        child: Center(child: OfficeEmojiGlyph(id: entry.id, size: 28)),
      ),
    ),
  );

  Widget _grid(List<_EmojiEntry> entries, {bool recentShortcut = false}) =>
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        sliver: SliverGrid(
          key: ValueKey(
            recentShortcut ? 'emoji-recent-shortcuts' : 'emoji-grid',
          ),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisExtent: 42,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) =>
                _tile(entries[index], recentShortcut: recentShortcut),
            childCount: entries.length,
          ),
        ),
      );

  Widget _section(String title, {Widget? trailing}) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 9, 10, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 12, color: mutedColor),
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );

  Widget _empty(String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: mutedColor),
      ),
    ),
  );

  Widget _header() => SliverToBoxAdapter(
    child: Column(
      children: [
        if (widget.showDragHandle)
          SizedBox(
            key: const ValueKey('emoji-drag-handle'),
            height: 24,
            width: double.infinity,
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xffc9cdd3),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        if (_searchOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('emoji-search-field'),
                    controller: _query,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索表情（中文 / English）',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  tooltip: '收起搜索',
                  onPressed: () => setState(() {
                    _searchOpen = false;
                    _query.clear();
                  }),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          )
        else
          SizedBox(
            height: 30,
            child: Row(
              children: [
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    _library
                        ? '表情库'
                        : _category == '最近使用'
                        ? '最近使用'
                        : '',
                    style: const TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ),
                IconButton(
                  key: const ValueKey('emoji-open-search'),
                  tooltip: '搜索表情',
                  onPressed: () => setState(() => _searchOpen = true),
                  icon: const Icon(Icons.search, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 30,
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: '关闭表情',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 30,
                    ),
                  ),
                const SizedBox(width: 6),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _footer() => Container(
    key: const ValueKey('emoji-fixed-footer'),
    height: 44,
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: borderColor)),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(
      children: [
        IconButton(
          key: const ValueKey('emoji-open-library'),
          tooltip: '全部表情与分类',
          onPressed: () => _navigate('全部', library: true),
          icon: Icon(
            Icons.add,
            size: 21,
            color: _library ? accentColor : mutedColor,
          ),
        ),
        IconButton(
          key: const ValueKey('emoji-open-classic'),
          tooltip: '默认表情',
          onPressed: () => _navigate('经典表情'),
          icon: Icon(
            Icons.sentiment_satisfied_alt,
            size: 22,
            color: !_library && _category == '经典表情' ? accentColor : mutedColor,
          ),
        ),
        const Spacer(),
        IconButton(
          key: const ValueKey('emoji-open-recents'),
          tooltip: '最近使用与管理',
          onPressed: () => _navigate('最近使用'),
          icon: Icon(
            Icons.settings_outlined,
            size: 20,
            color: _category == '最近使用' ? accentColor : mutedColor,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final home = !_library && _category == '经典表情' && _query.text.trim().isEmpty;
    final entries = _entries;
    return SizedBox(
      width: widget.width ?? 340,
      height: widget.height ?? 400,
      child: Material(
        color: Colors.white,
        child: !_current
            ? const Center(child: Text('工作身份已变化，请重新打开表情。'))
            : Column(
                children: [
                  Expanded(
                    child: CustomScrollView(
                      key: const ValueKey('emoji-scroll'),
                      controller: widget.scrollController ?? _scroll,
                      physics: const ClampingScrollPhysics(),
                      slivers: [
                        _header(),
                        if (_library && !_searchOpen)
                          SliverToBoxAdapter(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: Row(
                                children: [
                                  for (final category in [
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
                                        onSelected: (_) =>
                                            _navigate(category, library: true),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (_data == null)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
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
                            ),
                          )
                        else if (home) ...[
                          _section(
                            '最常使用',
                            trailing: Tooltip(
                              message: '按最近使用排序，显示前 14 个',
                              child: Icon(
                                Icons.history,
                                size: 13,
                                color: mutedColor,
                              ),
                            ),
                          ),
                          if (_recentEntries.isEmpty)
                            _empty('还没有最近使用的表情')
                          else
                            _grid(
                              _recentEntries.take(14).toList(),
                              recentShortcut: true,
                            ),
                          _section('默认表情'),
                          _grid(entries),
                        ] else ...[
                          if (_category == '最近使用' && _query.text.trim().isEmpty)
                            _section(
                              '最近使用 · ${_recentEntries.length}/32',
                              trailing: TextButton(
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
                          if (entries.isEmpty)
                            _empty(
                              _category == '最近使用' && _query.text.trim().isEmpty
                                  ? '还没有最近使用的表情'
                                  : '没有匹配的表情',
                            )
                          else
                            _grid(entries),
                        ],
                        const SliverToBoxAdapter(child: SizedBox(height: 10)),
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
                  if (!s.connected)
                    const Padding(
                      padding: EdgeInsets.all(6),
                      child: Text(
                        '离线可选表情，最近使用暂未同步。',
                        style: TextStyle(fontSize: 10, color: mutedColor),
                      ),
                    ),
                  _footer(),
                ],
              ),
      ),
    );
  }
}

Future<String?> showOfficeEmojiPicker(BuildContext context, OfficeState state) {
  final mobile = MediaQuery.sizeOf(context).width < 760;
  if (mobile) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: DraggableScrollableSheet(
          key: const ValueKey('emoji-draggable-sheet'),
          initialChildSize: .45,
          minChildSize: .45,
          maxChildSize: .85,
          expand: false,
          snap: true,
          snapSizes: const [.45, .85],
          shouldCloseOnMinExtent: false,
          builder: (context, scrollController) => SafeArea(
            top: false,
            child: OfficeEmojiPicker(
              state: state,
              width: MediaQuery.sizeOf(context).width,
              height: double.infinity,
              scrollController: scrollController,
              showDragHandle: true,
              onClose: () => Navigator.pop(context),
              onSelected: (id) => Navigator.pop(context, id),
            ),
          ),
        ),
      ),
    );
  }
  return showDialog<String>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: OfficeEmojiPicker(
        state: state,
        width: 340,
        height: 400,
        onClose: () => Navigator.pop(context),
        onSelected: (id) => Navigator.pop(context, id),
      ),
    ),
  );
}
