import 'dart:convert';
import 'dart:typed_data';

import 'office_state.dart';

// Keep the picker and upload adapter aligned with the server's minutes audio
// attachment suffix allowlist. An MP4 video cannot be linked as a recording.
const officeMinutesAudioMimeTypes = {
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'aac': 'audio/aac',
  'opus': 'audio/ogg',
  'flac': 'audio/flac',
  'webm': 'audio/webm',
};

/// A view of the office protocol, not a second store of meeting knowledge.
class OfficeMinutesApi {
  OfficeMinutesApi(this.office);
  final OfficeState office;
  Future<List<Json>> list([String query = '']) async {
    final value = await office.officeRequest(
      '/minutes?q=${Uri.encodeQueryComponent(query)}',
    );
    return (value['minutes'] as List? ?? []).map((e) => Json.from(e)).toList();
  }

  Future<Json> get(String id) async => Json.from(
    (await office.officeRequest(
      '/minutes/${Uri.encodeComponent(id)}',
    ))['minute'],
  );
  Future<Json> create(String room, Json input) async => Json.from(
    (await office.officeRequest(
      '/rooms/${Uri.encodeComponent(room)}/minutes',
      method: 'POST',
      data: input,
    ))['minute'],
  );
  Future<Json> update(Json minute, Json changes) async => Json.from(
    (await office.officeRequest(
      '/minutes/${Uri.encodeComponent(minute['id'])}',
      method: 'PATCH',
      data: {'base_revision': minute['revision'], ...changes},
    ))['minute'],
  );
  Future<Json> audio(
    String room,
    String name,
    Uint8List bytes,
    String clientId,
  ) async {
    if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) {
      throw OfficeException(422, '录音文件大小需为 1 字节至 12 MB');
    }
    final ext = name.split('.').last.toLowerCase();
    final mime = officeMinutesAudioMimeTypes[ext];
    if (mime == null) {
      throw OfficeException(
        422,
        '请选择 MP3、M4A、WAV、OGG、AAC、OPUS、FLAC 或 WEBM 音频文件',
      );
    }
    return Json.from(
      (await office.officeRequest(
        '/rooms/${Uri.encodeComponent(room)}/attachments',
        method: 'POST',
        data: {
          'client_id': clientId,
          'filename': name,
          'mime_type': mime,
          'data_base64': base64Encode(bytes),
        },
      ))['attachment'],
    );
  }

  Future<Json> createTask(
    Json minute,
    String title,
    String assignee,
    String clientId,
  ) async => Json.from(
    (await office.officeRequest(
      '/rooms/${Uri.encodeComponent(minute['room_id'])}/tasks',
      method: 'POST',
      data: {
        'client_id': clientId,
        'title': title,
        'assignee_id': assignee,
        'description':
            '请阅读人机妙记《${minute['title']}》（${minute['id']}），根据逐字稿整理结论、疑问和待办。'
            '共同纪要文档：${minute['document_id']}。请先读取这份共享文档的完整正文。'
            '仅将有原文依据的内容写入共享文档，标明待核实事项。\n\n'
            '逐字稿预览（最多 6000 字，完整内容以共享文档为准）：\n'
            '${minutesTranscriptText(minute).substring(0, minutesTranscriptText(minute).length.clamp(0, 6000))}',
      },
    ))['task'],
  );
}

String minutesOffset(dynamic raw) {
  final seconds = ((raw as num? ?? 0) / 1000).floor();
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

List<Json> parseMinutesTranscript(String source) {
  final result = <Json>[];
  var previous = 0;
  for (final raw in const LineSplitter().convert(source)) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    var offset = previous;
    final stamp = RegExp(r'^\[(\d{1,4}):(\d{2})(?::(\d{2}))?\]\s*')
        .firstMatch(line);
    if (stamp != null) {
      final first = int.parse(stamp[1]!), second = int.parse(stamp[2]!);
      if (second > 59 || (stamp[3] != null && int.parse(stamp[3]!) > 59)) {
        throw const FormatException('时间请使用 [分:秒] 或 [时:分:秒]');
      }
      offset =
          (stamp[3] == null
              ? first * 60 + second
              : first * 3600 + second * 60 + int.parse(stamp[3]!)) *
          1000;
      line = line.substring(stamp.end);
    }
    if (offset < previous || offset > 86400000) {
      throw const FormatException('逐字稿时间需按先后排列，最长 24 小时');
    }
    final speaker = RegExp(r'^([^:：]{1,60})[:：]\s*').firstMatch(line);
    final label = speaker == null ? '未标注发言人' : speaker[1]!.trim();
    if (speaker != null) line = line.substring(speaker.end);
    if (line.isEmpty) continue;
    if (line.length > 4000) throw const FormatException('单段内容请控制在 4000 字以内');
    result.add({'speaker_label': label, 'offset_ms': offset, 'text': line});
    previous = offset;
  }
  if (result.length > 200 || source.length > 100000) {
    throw const FormatException('请分批导入，每份最多 200 段、10 万字');
  }
  return result;
}

String minutesTranscriptText(
  Json minute,
) => (minute['transcript'] as List? ?? [])
    .map(
      (e) =>
          '[${minutesOffset(e['offset_ms'])}] ${e['speaker_label'] ?? '未标注发言人'}：${e['text']}',
    )
    .join('\n\n');

String minutesMarkdown(Json minute) =>
    '# ${minute['title']}\n\n'
    '> 人机妙记 · 共同记录 r${minute['revision']}。以下是已保存的文字记录，不是自动生成的 AI 摘要。\n\n'
    '## 文字记录\n\n${minutesTranscriptText(minute)}\n\n'
    '## 结论与待核实事项\n\n待团队或受派 Agent 根据原文整理。\n\n'
    '## 行动项\n\n待确认负责人、交付内容和期限。\n';
