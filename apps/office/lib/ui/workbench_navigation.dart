import 'dart:async';

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'app_workbench.dart';
import 'office_theme.dart';

typedef OfficeWorkbenchPageBuilder = Widget Function(
  int route,
  VoidCallback onBack,
  ValueChanged<int> navigate,
);

const _routes = {
  'messages': 0,
  'agents': 1,
  'contacts': 2,
  'documents': 3,
  'docs': 3,
  'tasks': 4,
  'workbench': 5,
  'meetings': 6,
  'calendar': 7,
  'mail': 8,
  'attendance': 9,
  'approvals': 10,
  'approval': 10,
  'settings': 11,
  'enterprise': 13,
  'minutes': 14,
};

const _titles = {
  0: '消息',
  1: 'Agent',
  2: '通讯录',
  3: '云文档',
  4: '任务',
  5: '工作台',
  6: '视频会议',
  7: '日历',
  8: '邮箱',
  9: '考勤',
  10: '审批',
  11: '设置',
  13: '企业管理',
  14: '人机妙记',
};

const _modules = {
  0: 'im',
  1: 'im',
  2: 'im',
  3: 'docs',
  4: 'tasks',
  5: 'workbench',
  6: 'meetings',
  7: 'calendar',
  8: 'mail',
  9: 'attendance',
  10: 'approvals',
  14: 'minutes',
};

/// Resolve native application paths only. External URLs remain explicitly
/// unsupported here instead of silently opening a similarly named native app.
int? officeWorkbenchRoute(String route) {
  final uri = Uri.tryParse(route.trim());
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  final id = uri.fragment.isNotEmpty
      ? uri.fragment
      : uri.pathSegments.where((part) => part.isNotEmpty).lastOrNull;
  return _routes[id];
}

typedef _WorkbenchIdentity = ({
  OfficeState owner,
  int generation,
  String endpoint,
  String? principal,
});

class _WorkbenchPage {
  _WorkbenchPage(this.route, {this.path});
  final int? route;
  final String? path;
  Object get id => route ?? path ?? 'unknown';
}

/// Local application navigation within the workbench. Every native route has
/// one mounted instance; going to an earlier route returns to that instance.
/// Media and business operations stay owned by the supplied real pages.
class OfficeWorkbenchNavigator extends StatefulWidget {
  const OfficeWorkbenchNavigator({
    super.key,
    required this.state,
    required this.pageBuilder,
    this.embeddedMobileHeader = false,
  });
  final OfficeState state;
  final OfficeWorkbenchPageBuilder pageBuilder;
  final bool embeddedMobileHeader;

  @override
  State<OfficeWorkbenchNavigator> createState() =>
      OfficeWorkbenchNavigatorState();
}

class OfficeWorkbenchNavigatorState extends State<OfficeWorkbenchNavigator> {
  final _pages = <_WorkbenchPage>[];
  late _WorkbenchIdentity _identity;
  int _homeGeneration = 0;

  _WorkbenchIdentity get _currentIdentity => (
    owner: widget.state,
    generation: widget.state.identityGeneration,
    endpoint: widget.state.endpoint,
    principal: widget.state.me?['id']?.toString(),
  );

  @override
  void initState() {
    super.initState();
    _identity = _currentIdentity;
    widget.state.addListener(_stateChanged);
  }

  @override
  void didUpdateWidget(covariant OfficeWorkbenchNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.removeListener(_stateChanged);
      widget.state.addListener(_stateChanged);
    }
    _syncIdentity();
  }

  void _syncIdentity() {
    if (_identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _pages.clear();
    _homeGeneration++;
  }

  void _stateChanged() {
    if (!mounted) return;
    setState(_syncIdentity);
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
    super.dispose();
  }

  void openApp(String path) {
    final route = officeWorkbenchRoute(path);
    if (route == 5) {
      close();
    } else {
      _open(_WorkbenchPage(route, path: path));
    }
  }

  void navigate(int route) {
    if (route == 5) {
      close();
    } else {
      _open(_WorkbenchPage(route));
    }
  }

  void _open(_WorkbenchPage page) {
    if (!mounted || _identity != _currentIdentity) return;
    final existing = _pages.indexWhere((entry) => entry.id == page.id);
    if (existing == _pages.length - 1 && existing >= 0) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      if (existing >= 0) {
        _pages.removeRange(existing + 1, _pages.length);
      } else {
        _pages.add(page);
      }
    });
    _recordPageVisit(_pages.last);
  }

  void _recordPageVisit(_WorkbenchPage page) {
    final identity = _identity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = page.route;
      if (!_active(page, identity) ||
          route == null ||
          !_titles.containsKey(route) ||
          !_available(route)) {
        return;
      }
      final registered = widget.state.apps.where(
        (app) =>
            officeWorkbenchRoute(str(app['route'], str(app['id']))) == route,
      );
      final app =
          registered
              .where((app) => str(app['route'], str(app['id'])) == page.path)
              .firstOrNull ??
          registered.where((app) => app['available'] == true).firstOrNull;
      final id = app?['id'];
      if (id is! String || id.isEmpty || app?['available'] != true) return;
      // Usage is acknowledged by the authenticated service. A failure must not
      // block the app being opened or invent a local recent-history entry.
      unawaited(
        widget.state.recordWorkbenchVisit(id).catchError((Object _) {}),
      );
    });
  }

  void back() {
    if (!mounted || _pages.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _pages.removeLast());
  }

  void close() {
    if (!mounted || _pages.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(_pages.clear);
  }

  bool _active(_WorkbenchPage page, _WorkbenchIdentity identity) =>
      mounted &&
      identity == _currentIdentity &&
      _pages.isNotEmpty &&
      identical(_pages.last, page);

  String _title(_WorkbenchPage page) {
    for (final app in widget.state.apps) {
      final path = str(app['route'], str(app['id']));
      if ((page.route != null && officeWorkbenchRoute(path) == page.route) ||
          (page.path != null && path == page.path)) {
        return str(app['name'], _titles[page.route] ?? '应用');
      }
    }
    return _titles[page.route] ?? '应用';
  }

  bool _available(int route) {
    if (route == 13 && !widget.state.canManageEnterprise) return false;
    final module = _modules[route];
    if (module != null && !widget.state.moduleAvailable(module)) return false;
    final registered = widget.state.apps.where(
      (app) => officeWorkbenchRoute(str(app['route'], str(app['id']))) == route,
    );
    return registered.isEmpty ||
        registered.any((app) => app['available'] == true);
  }

  Widget _page(_WorkbenchPage page) {
    final identity = _identity;
    final route = page.route;
    final known = route != null && _titles.containsKey(route);
    final available = known && _available(route);
    void goBack() {
      if (_active(page, identity)) back();
    }

    void goTo(int target) {
      if (_active(page, identity)) navigate(target);
    }

    return KeyedSubtree(
      key: ObjectKey(page),
      child: known && available
          ? widget.pageBuilder(route, goBack, goTo)
          : EmptyOffice(
              title: known ? '此应用暂不可用' : '暂不支持打开此应用',
              subtitle: known
                  ? '当前身份或工作空间策略限制了此应用。你可以返回上一页，或关闭并回到工作台。'
                  : '工作台尚未接入此应用的原生页面。你可以返回上一页，或关闭并回到工作台。',
              icon: known ? Icons.lock_outline : Icons.apps_outlined,
              action: TextButton(onPressed: goBack, child: const Text('返回上一页')),
            ),
    );
  }

  Widget _retain(Widget child, {required bool active}) => TickerMode(
    enabled: active,
    child: ExcludeFocus(excluding: !active, child: child),
  );

  @override
  Widget build(BuildContext context) {
    final active = _pages.lastOrNull;
    final foreground = TickerMode.valuesOf(context).enabled;
    final identity = _identity;
    return PopScope(
      canPop: active == null || !foreground,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop &&
            foreground &&
            active != null &&
            _active(active, identity)) {
          back();
        }
      },
      child: Material(
        color: Colors.white,
        child: Column(
          children: [
            if (active != null)
              Container(
                key: const ValueKey('workbench-app-toolbar'),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: borderColor)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('workbench-app-back'),
                      tooltip: _pages.length == 1
                          ? '返回工作台'
                          : '返回${_title(_pages[_pages.length - 2])}',
                      onPressed: () {
                        if (_active(active, identity)) back();
                      },
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        _title(active),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('workbench-app-close'),
                      tooltip: '关闭应用并返回工作台',
                      onPressed: () {
                        if (_active(active, identity)) close();
                      },
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: IndexedStack(
                index: _pages.length,
                sizing: StackFit.expand,
                children: [
                  _retain(
                    OfficeAppWorkbench(
                      embeddedMobileHeader: widget.embeddedMobileHeader,
                      key: ValueKey('workbench-home-$_homeGeneration'),
                      state: widget.state,
                      onOpen: (path) {
                        if (identity == _currentIdentity && _pages.isEmpty) {
                          openApp(path);
                        }
                      },
                    ),
                    active: active == null,
                  ),
                  for (final page in _pages)
                    _retain(_page(page), active: identical(page, active)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
