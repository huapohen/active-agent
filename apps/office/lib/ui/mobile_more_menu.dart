import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
                color: const Color(0x66000000),
                dismissible: true,
                onDismiss: onClose,
                semanticsLabel: '关闭更多菜单',
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                // Match the sheet to the screen, independent of the height of
                // the shell's safe area and editable bottom navigation.
                height: MediaQuery.sizeOf(context).height * .64,
                width: double.infinity,
                child: Material(
                  key: const ValueKey('mobile-more-sheet'),
                  color: const Color(0xfff4f4f4),
                  elevation: 12,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(14),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      const SizedBox(height: 9),
                      Container(
                        key: const ValueKey('mobile-more-sheet-handle'),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xffc9c9cb),
                          borderRadius: BorderRadius.circular(4),
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
