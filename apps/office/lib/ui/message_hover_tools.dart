import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'office_emoji.dart';
import 'office_theme.dart';

/// All transient controls, including time, paint outside the message layout.
class OfficeMessageHoverTools extends StatefulWidget {
  const OfficeMessageHoverTools({
    super.key,
    required this.child,
    required this.onAction,
    required this.messageId,
    required this.state,
    this.onOpenMore,
    this.timestamp,
    this.enabled = true,
  });
  final Widget child;
  final ValueChanged<String> onAction;
  final String messageId;
  final OfficeState state;
  final ValueChanged<Offset>? onOpenMore;
  final String? timestamp;
  final bool enabled;
  @override
  State<OfficeMessageHoverTools> createState() =>
      _OfficeMessageHoverToolsState();
}

class _OfficeMessageHoverToolsState extends State<OfficeMessageHoverTools> {
  final _portal = OverlayPortalController();
  final _reactions = MenuController();
  Timer? _leave, _reactionLeave;
  bool _hovered = false;
  bool _menuOpen = false, _active = true;
  void _enter() {
    _hovered = true;
    _leave?.cancel();
    if (widget.enabled && mounted && _active && !_portal.isShowing) {
      _portal.show();
    }
  }

  void _exit() {
    _hovered = false;
    _leave?.cancel();
    _leave = Timer(const Duration(milliseconds: 180), () {
      if (mounted && !_menuOpen) _portal.hide();
    });
  }

  void _enterReactions() {
    _reactionLeave?.cancel();
    _enter();
  }

  void _exitReactions() {
    _reactionLeave?.cancel();
    // Allow crossing the small gap between the trigger and popup.
    _reactionLeave = Timer(const Duration(milliseconds: 180), () {
      if (mounted && _reactions.isOpen) _reactions.close();
    });
  }

  void _hide() {
    _reactionLeave?.cancel();
    if (_reactions.isOpen) _reactions.close();
    _portal.hide();
  }

  void _act(String action) {
    if (!mounted || !widget.enabled || !_active) return;
    _leave?.cancel();
    _hide();
    widget.onAction(action);
  }

  void _hideAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _hide();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.valuesOf(context).enabled;
    if (!_active) _hideAfterFrame();
  }

  @override
  void didUpdateWidget(covariant OfficeMessageHoverTools oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || oldWidget.messageId != widget.messageId) {
      _hideAfterFrame();
    }
  }

  @override
  void dispose() {
    _leave?.cancel();
    _reactionLeave?.cancel();
    super.dispose();
  }

  Widget _button(String action, String label, IconData icon) => Builder(
    builder: (context) => IconButton(
      tooltip: label,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(34, 34),
        maximumSize: const Size(34, 34),
      ),
      onPressed: () {
        if (action == 'more' && widget.onOpenMore != null) {
          final box = context.findRenderObject();
          if (box is RenderBox && widget.enabled && _active) {
            final point = box.localToGlobal(Offset(0, box.size.height));
            _hide();
            widget.onOpenMore!(point);
            return;
          }
        }
        _act(action);
      },
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      iconSize: 18,
      color: action == 'agent' ? accentColor : const Color(0xff57647a),
      icon: Icon(icon),
    ),
  );

  String _fullTime(DateTime date, BuildContext context) {
    return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} '
        '${officeHourMinute(date, context: context)}:${date.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    overlayChildBuilder: (context, info) {
      final rect = MatrixUtils.transformRect(
        info.childPaintTransform,
        Offset.zero & info.childSize,
      );
      if (rect.bottom < 0 || rect.top > info.overlaySize.height || !_active) {
        return const SizedBox.shrink();
      }
      final width = math.min(212.0, info.overlaySize.width - 16);
      final left = (rect.right - width).clamp(
        8.0,
        math.max(8.0, info.overlaySize.width - width - 8),
      );
      final date = DateTime.tryParse(widget.timestamp ?? '')?.toLocal();
      final time = date == null ? '' : officeHourMinute(date, context: context);
      const timeStyle = TextStyle(fontSize: 10, color: mutedColor);
      final timePainter = TextPainter(
        text: TextSpan(text: time, style: timeStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final timeWidth = math.min(
        math.max(36.0, timePainter.width + 8),
        math.max(0.0, info.overlaySize.width - 16),
      );
      final timeHeight = math.max(18.0, timePainter.height);
      timePainter.dispose();
      final timeLeft = (rect.left - timeWidth - 8).clamp(
        8.0,
        math.max(8.0, info.overlaySize.width - timeWidth - 8),
      );
      final timeTop = (rect.center.dy - timeHeight / 2).clamp(
        8.0,
        math.max(8.0, info.overlaySize.height - timeHeight - 8),
      );
      const height = 42.0;
      final top = (rect.top - height + 6).clamp(
        8.0,
        math.max(8.0, info.overlaySize.height - height - 8),
      );
      return Positioned.fill(
        child: Stack(
          children: [
            if (date != null)
              Positioned(
                left: timeLeft.toDouble(),
                top: timeTop.toDouble(),
                width: timeWidth,
                height: timeHeight,
                child: MouseRegion(
                  onEnter: (_) => _enter(),
                  onExit: (_) => _exit(),
                  child: Tooltip(
                    message: _fullTime(date, context),
                    child: Center(
                      key: ValueKey('message-hover-time-${widget.messageId}'),
                      child: Text(time, style: timeStyle),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: left.toDouble(),
              top: top.toDouble(),
              width: width,
              child: MouseRegion(
                onEnter: (_) => _enter(),
                onExit: (_) => _exit(),
                child: Material(
                  key: ValueKey('message-hover-toolbar-${widget.messageId}'),
                  color: Colors.white,
                  elevation: 5,
                  shadowColor: Colors.black26,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: borderColor),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MenuAnchor(
                          controller: _reactions,
                          onOpen: () {
                            _menuOpen = true;
                            _leave?.cancel();
                          },
                          onClose: () {
                            _menuOpen = false;
                            if (!_hovered) _exit();
                          },
                          menuChildren: [
                            SizedBox(
                              width: math.min(380, info.overlaySize.width - 24),
                              height: math.min(
                                430,
                                info.overlaySize.height - 100,
                              ),
                              child: MouseRegion(
                                onEnter: (_) => _enterReactions(),
                                onExit: (_) {
                                  _exitReactions();
                                  _exit();
                                },
                                child: OfficeEmojiPicker(
                                  state: widget.state,
                                  onSelected: (emoji) => _act('react:$emoji'),
                                ),
                              ),
                            ),
                          ],
                          builder: (context, controller, child) => MouseRegion(
                            onExit: (_) => _exitReactions(),
                            onEnter: (_) {
                              _enterReactions();
                              if (!controller.isOpen) controller.open();
                            },
                            child: IconButton(
                              tooltip: '表情回应',
                              style: IconButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(34, 34),
                                maximumSize: const Size(34, 34),
                              ),
                              constraints: const BoxConstraints.tightFor(
                                width: 34,
                                height: 34,
                              ),
                              padding: EdgeInsets.zero,
                              iconSize: 18,
                              onPressed: () => controller.isOpen
                                  ? controller.close()
                                  : controller.open(),
                              icon: const Icon(Icons.thumb_up_outlined),
                            ),
                          ),
                        ),
                        _button('reply', '回复', Icons.reply_outlined),
                        _button('forward', '转发', Icons.forward_outlined),
                        _button('topic', '创建话题', Icons.forum_outlined),
                        _button('agent', 'Agent 协作', Icons.auto_awesome),
                        _button('more', '更多', Icons.more_horiz),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
    child: MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: widget.child,
    ),
  );
}
