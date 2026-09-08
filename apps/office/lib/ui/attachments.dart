import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../office_state.dart' hide Json;
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'voice_message.dart';

class PendingOfficeAttachment {
  PendingOfficeAttachment({
    required this.filename,
    required this.bytes,
    required this.mimeType,
    required this.roomId,
  });
  final String filename, mimeType, roomId;
  final Uint8List bytes;
  Json? record;
  bool uploading = false;
  String? error;
}

String fileSizeText(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
String imageMime(String filename) =>
    const {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
    }[filename.split('.').last.toLowerCase()] ??
    'application/octet-stream';

class MessageAttachment extends StatefulWidget {
  const MessageAttachment({
    super.key,
    required this.state,
    required this.attachment,
  });
  final OfficeState state;
  final Json attachment;
  @override
  State<MessageAttachment> createState() => _MessageAttachmentState();
}

class _MessageAttachmentState extends State<MessageAttachment> {
  Future<Uint8List>? _bytes;
  bool _saving = false;
  bool get _available =>
      (widget.attachment['status'] ??
          widget.attachment['availability'] ??
          'active') ==
      'active';
  bool get _image => str(widget.attachment['mime_type']).startsWith('image/');
  Future<Uint8List> _load() =>
      _bytes ??= widget.state.getAttachmentBytes(widget.attachment);
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final bytes = await widget.state.getAttachmentBytes(widget.attachment);
      final result = await FilePicker.saveFile(
        fileName: str(widget.attachment['filename'], 'attachment'),
        bytes: bytes,
        mimeType: str(
          widget.attachment['mime_type'],
          'application/octet-stream',
        ),
      );
      if (mounted && result != null) notifyOffice(context, '附件已保存');
    } catch (e) {
      if (mounted) notifyOffice(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    if (!_available) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Text(
          '${str(a['filename'])} · 附件已不可用',
          style: const TextStyle(fontSize: 11, color: mutedColor),
        ),
      );
    }
    if (a['audio'] is Map && str(a['mime_type']) == 'audio/wav') {
      return OfficeVoiceMessage(
        state: widget.state,
        attachment: a,
        onDownload: _save,
        saving: _saving,
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .68),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0xffe2e7ef)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_image)
            FutureBuilder<Uint8List>(
              future: _load(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      '图片暂时无法读取，可重试下载',
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const SizedBox(
                    height: 90,
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                return InkWell(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => Dialog(
                      backgroundColor: Colors.transparent,
                      insetPadding: const EdgeInsets.all(15),
                      child: Stack(
                        children: [
                          InteractiveViewer(
                            minScale: .5,
                            maxScale: 5,
                            child: Image.memory(
                              snapshot.data!,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const Text('图片无法解码'),
                            ),
                          ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: IconButton(
                              onPressed: () => Navigator.pop(context),
                              tooltip: '关闭图片',
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                              ),
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 19,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(7),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: Image.memory(
                        snapshot.data!,
                        width: 290,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Padding(
                          padding: EdgeInsets.all(18),
                          child: Text('图片无法解码'),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 10, 6, 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_image) ...[
                  const Icon(
                    Icons.insert_drive_file_outlined,
                    size: 27,
                    color: Color(0xff7a9ac9),
                  ),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        str(a['filename']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        fileSizeText((a['size'] as num?)?.toInt() ?? 0),
                        style: const TextStyle(fontSize: 9, color: mutedColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _saving ? null : _save,
                  tooltip: '下载附件',
                  icon: _saving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined, size: 19),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
