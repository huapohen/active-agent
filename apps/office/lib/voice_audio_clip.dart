import 'dart:math' as math;
import 'dart:typed_data';

class OfficeVoiceException implements Exception {
  const OfficeVoiceException(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

class OfficeVoiceClip {
  const OfficeVoiceClip({
    required this.bytes,
    required this.filename,
    required this.duration,
    this.sampleRate = 16000,
    this.channels = 1,
    this.bitsPerSample = 16,
    this.waveform = const [],
    this.truncated = false,
  });
  final Uint8List bytes;
  final String filename;
  final Duration duration;
  final int sampleRate, channels, bitsPerSample;
  final List<double> waveform;
  final bool truncated;
  String get mimeType => 'audio/wav';
  int get durationMs => math.max(1, (duration.inMicroseconds / 1000).round());

  /// Validates the real header, then writes a canonical PCM WAV without changing
  /// the device's sample rate. Only an explicit recording duration limit trims
  /// trailing PCM frames; no requested metadata is substituted for actual data.
  factory OfficeVoiceClip.fromWav(
    Uint8List source, {
    String filename = 'voice.wav',
    int maxBytes = 12 * 1024 * 1024,
    Duration? maxDuration,
  }) {
    Never invalid() => throw const OfficeVoiceException(
      'invalid_audio',
      '录音不是有效的单声道 PCM16 WAV',
    );
    if (source.length < 44 || source.length > maxBytes) invalid();
    final data = ByteData.sublistView(source);
    String four(int offset) =>
        String.fromCharCodes(source.sublist(offset, offset + 4));
    if (four(0) != 'RIFF' ||
        four(8) != 'WAVE' ||
        data.getUint32(4, Endian.little) + 8 != source.length) {
      invalid();
    }
    int? rate, audioStart, audioLength;
    var cursor = 12;
    while (cursor + 8 <= source.length) {
      final type = four(cursor),
          length = data.getUint32(cursor + 4, Endian.little);
      final start = cursor + 8, end = start + length;
      if (end > source.length) invalid();
      if (type == 'fmt ') {
        if (rate != null || length < 16) invalid();
        final format = data.getUint16(start, Endian.little);
        final channels = data.getUint16(start + 2, Endian.little);
        final sampleRate = data.getUint32(start + 4, Endian.little);
        if (channels != 1 ||
            sampleRate < 8000 ||
            sampleRate > 48000 ||
            data.getUint16(start + 14, Endian.little) != 16 ||
            data.getUint16(start + 12, Endian.little) != 2 ||
            data.getUint32(start + 8, Endian.little) != sampleRate * 2) {
          invalid();
        }
        if (format == 1) {
          if (length != 16 &&
              (length != 18 ||
                  data.getUint16(start + 16, Endian.little) != 0)) {
            invalid();
          }
        } else if (format == 0xfffe) {
          const pcmGuid = [
            1,
            0,
            0,
            0,
            0,
            0,
            16,
            0,
            128,
            0,
            0,
            170,
            0,
            56,
            155,
            113,
          ];
          if (length != 40 ||
              data.getUint16(start + 16, Endian.little) != 22 ||
              data.getUint16(start + 18, Endian.little) != 16) {
            invalid();
          }
          for (var index = 0; index < pcmGuid.length; index++) {
            if (source[start + 24 + index] != pcmGuid[index]) invalid();
          }
        } else {
          invalid();
        }
        rate = sampleRate;
      } else if (type == 'data') {
        if (audioStart != null || length == 0 || length.isOdd) invalid();
        audioStart = start;
        audioLength = length;
      }
      cursor = end + (length.isOdd ? 1 : 0);
      if (cursor > source.length) invalid();
    }
    if (cursor != source.length ||
        rate == null ||
        audioStart == null ||
        audioLength == null) {
      invalid();
    }
    final originalFrames = audioLength ~/ 2;
    final maxFrames = maxDuration == null
        ? originalFrames
        : (maxDuration.inMicroseconds * rate / Duration.microsecondsPerSecond)
              .floor();
    final frames = math.min(originalFrames, maxFrames);
    if (frames < 1) invalid();
    final pcm = Uint8List.sublistView(
      source,
      audioStart,
      audioStart + frames * 2,
    );
    final result = Uint8List(44 + pcm.length);
    final header = ByteData.sublistView(result);
    void ascii(int offset, String text) =>
        result.setRange(offset, offset + text.length, text.codeUnits);
    ascii(0, 'RIFF');
    header.setUint32(4, result.length - 8, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, rate, Endian.little);
    header.setUint32(28, rate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);
    result.setRange(44, result.length, pcm);
    final pcmData = ByteData.sublistView(pcm);
    final peaks = <double>[];
    for (var bin = 0; bin < 32; bin++) {
      final from = bin * frames ~/ 32, to = (bin + 1) * frames ~/ 32;
      var peak = 0;
      for (var sample = from; sample < to; sample++) {
        peak = math.max(
          peak,
          pcmData.getInt16(sample * 2, Endian.little).abs(),
        );
      }
      peaks.add(peak / 32768);
    }
    return OfficeVoiceClip(
      bytes: result,
      filename: filename,
      sampleRate: rate,
      duration: Duration(
        microseconds: (frames * Duration.microsecondsPerSecond / rate).round(),
      ),
      waveform: List.unmodifiable(peaks),
      truncated: frames < originalFrames,
    );
  }
}
