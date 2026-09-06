/// A shareable office URL contains message coordinates, never credentials.
String officeMessageLink(String endpoint, String roomId, String messageId) {
  final origin = Uri.parse(endpoint);
  return Uri(
    scheme: origin.scheme,
    host: origin.host,
    port: origin.hasPort ? origin.port : null,
    path: '/office/',
    queryParameters: {'room': roomId, 'message': messageId},
  ).toString();
}

(String, String)? officeMessageTarget(Uri uri) {
  final room = uri.queryParameters['room']?.trim() ?? '';
  final message = uri.queryParameters['message']?.trim() ?? '';
  if (room.isEmpty ||
      message.isEmpty ||
      room.length > 200 ||
      message.length > 200) {
    return null;
  }
  return (room, message);
}
