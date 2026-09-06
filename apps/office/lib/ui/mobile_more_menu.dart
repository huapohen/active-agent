import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'office_theme.dart';

/// A menu above the navigation bar. The bar stays interactive, so tapping
/// More again dismisses the menu without replacing the underlying page.
class OfficeMobileMoreMenu extends StatelessWidget {
  const OfficeMobileMoreMenu({
    super.key,
    required this.onClose,
    required this.child,
  });
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) onClose();
    },
    child: CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: ModalBarrier(
                color: Colors.black26,
                dismissible: true,
                onDismiss: onClose,
                semanticsLabel: '关闭更多菜单',
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: .74,
                widthFactor: 1,
                child: Material(
                  color: Colors.white,
                  elevation: 12,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      const SizedBox(height: 9),
                      Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xffd8dce4),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 4, 10, 0),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '更多',
                                style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭更多菜单',
                              onPressed: onClose,
                              icon: const Icon(
                                Icons.close,
                                size: 20,
                                color: mutedColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
