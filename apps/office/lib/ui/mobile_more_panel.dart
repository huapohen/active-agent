import 'package:flutter/material.dart';

import 'mobile_navigation.dart';
import 'office_theme.dart';

/// Destination data is supplied by the shell after identity and permission
/// filtering. Recent entries must come from actual opens; this panel never seeds
/// history from favorites, the catalog or a suggested list.
class OfficeMobileMorePanel extends StatefulWidget {
  const OfficeMobileMorePanel({
    super.key,
    required this.items,
    this.recentItems = const [],
    required this.onOpen,
    required this.onEditNavigation,
  });

  final List<OfficeNavigationItem> items, recentItems;
  final ValueChanged<OfficeNavigationItem> onOpen;
  final VoidCallback onEditNavigation;

  @override
  State<OfficeMobileMorePanel> createState() => _OfficeMobileMorePanelState();
}

class _OfficeMobileMorePanelState extends State<OfficeMobileMorePanel> {
  bool _allRecent = false;

  List<OfficeNavigationItem> _unique(List<OfficeNavigationItem> values) {
    final seen = <String>{};
    return values.where((item) => seen.add(item.id)).toList();
  }

  Color _color(String id) => switch (id) {
    'agents' => const Color(0xff8047ef),
    'tasks' => const Color(0xff6565f2),
    'contacts' => const Color(0xffffbd00),
    'calendar' || 'attendance' || 'approvals' => const Color(0xffff8422),
    'minutes' => const Color(0xff8d76d5),
    'enterprise' => const Color(0xff5d91d9),
    _ => accentColor,
  };

  IconData _glyph(OfficeNavigationItem item) => switch (item.id) {
    'contacts' => Icons.person_rounded,
    'tasks' => Icons.done_rounded,
    'calendar' => Icons.calendar_month_rounded,
    _ => item.icon,
  };

  Widget _icon(OfficeNavigationItem item, double size, {bool recent = false}) {
    final filled = recent || item.id == 'agents';
    return Container(
      key: ValueKey(
        'mobile-more-${recent ? 'recent' : 'grid'}-icon-${item.id}',
      ),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? _color(item.id) : Colors.white,
        borderRadius: BorderRadius.circular(size * .24),
      ),
      child: Icon(
        _glyph(item),
        color: filled ? Colors.white : _color(item.id),
        size: size * .67,
      ),
    );
  }

  Widget _recentRow(OfficeNavigationItem item) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: const Color(0xfffafafb),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey('mobile-recent-open-${item.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => widget.onOpen(item),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _icon(item, 22, recent: true),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.4,
                    color: inkColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _heading(String title, Widget action, {double bottom = 4}) => Padding(
    padding: EdgeInsets.fromLTRB(4, 0, 4, bottom),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
          ),
        ),
        action,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final recent = _unique(widget.recentItems), items = _unique(widget.items);
    return ColoredBox(
      color: const Color(0xfff4f4f4),
      child: ListView(
        key: const ValueKey('mobile-more-panel-scroll'),
        padding: const EdgeInsets.only(top: 14, bottom: 18),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                if (_allRecent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        IconButton(
                          key: const ValueKey('mobile-recent-back'),
                          tooltip: '返回更多',
                          onPressed: () => setState(() => _allRecent = false),
                          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                        ),
                        const Expanded(
                          child: Text(
                            '最近使用',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  _heading(
                    '最近使用',
                    TextButton(
                      key: const ValueKey('mobile-recent-all'),
                      onPressed: () => setState(() => _allRecent = true),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(52, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('全部', style: TextStyle(fontSize: 17)),
                          Icon(Icons.chevron_right, size: 18),
                        ],
                      ),
                    ),
                  ),
                if (recent.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      '打开应用后，会在这里显示最近使用。',
                      key: ValueKey('mobile-recent-empty'),
                      style: TextStyle(fontSize: 14, color: mutedColor),
                    ),
                  )
                else
                  ...(_allRecent ? recent : recent.take(4)).map(_recentRow),
                if (!_allRecent) ...[
                  const SizedBox(height: 24),
                  _heading(
                    '更多',
                    TextButton(
                      key: const ValueKey('mobile-more-edit-navigation'),
                      onPressed: widget.onEditNavigation,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(44, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('编辑', style: TextStyle(fontSize: 17)),
                    ),
                    bottom: 20,
                  ),
                ],
              ],
            ),
          ),
          if (!_allRecent)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: GridView.builder(
                key: const ValueKey('mobile-more-app-grid'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: items.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 14,
                  mainAxisExtent:
                      57 + MediaQuery.textScalerOf(context).scale(12) * 3,
                ),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Semantics(
                    label: item.label,
                    button: true,
                    child: Tooltip(
                      message: item.label,
                      child: InkWell(
                        key: ValueKey('mobile-more-open-${item.id}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => widget.onOpen(item),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _icon(item, 48),
                            const SizedBox(height: 9),
                            Text(
                              item.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12, height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
