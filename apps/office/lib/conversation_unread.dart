/// The entry snapshot stays stable after receipts and background refreshes so
/// the conversation can explain where this visit's unread messages began.
class OfficeConversationWindow {
  const OfficeConversationWindow({
    required this.roomId,
    required this.selection,
    required this.positionVersion,
    required this.entryFirstUnreadSeq,
    required this.entryUnreadCount,
    required this.anchorSeq,
    required this.firstUnreadSeq,
    required this.beforeCursor,
    required this.afterCursor,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
    required this.remainingUnreadAfter,
    required this.startAtUnread,
  });

  final String roomId;
  final int selection, positionVersion;
  final int? entryFirstUnreadSeq, anchorSeq, firstUnreadSeq;
  final int entryUnreadCount;
  final int? beforeCursor, afterCursor;
  final bool hasMoreBefore, hasMoreAfter, startAtUnread;
  final int remainingUnreadAfter;
}
