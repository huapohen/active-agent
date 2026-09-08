import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:active_office/voice_audio_storage_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory fixture;
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('renji-storage-test-');
  });
  tearDown(() async {
    if (await fixture.exists()) await fixture.delete(recursive: true);
  });

  test('missing path-provider cache directory supports actual recording and playback file roundtrip', () async {
    final parent = Directory('${fixture.path}/Caches/com.huapohen.fixture');
    expect(await parent.exists(), isFalse);
    final storage = createVoiceStorage(temporaryDirectory: () async => parent);
    addTearDown(storage.close);
    final path = await storage.createRecordingPath();
    expect(File(path).parent.parent.path, parent.path);
    expect(
      File(path).parent.uri.pathSegments.where((part) => part.isNotEmpty).last,
      startsWith('renji-voice-'),
    );
    final bytes = Uint8List.fromList([1, 2, 0, 255, 128]);
    await File(path).writeAsBytes(bytes, flush: true);
    expect(await storage.readRecording(path, maxBytes: 5), bytes);
    await storage.releaseRecording(path);
    expect(await File(path).exists(), isFalse);
    final playback = await storage.createPlayback(bytes);
    expect(await File(playback.location).readAsBytes(), bytes);
    final owned = File(playback.location).parent;
    await storage.close();
    expect(await owned.exists(), isFalse);
    expect(await parent.exists(), isTrue);
  });

  test('cleanup preserves the cache parent and unrelated files or sibling sessions', () async {
    final parent = await Directory('${fixture.path}/cache').create();
    final unrelated = await File('${parent.path}/unrelated.txt')
        .writeAsString('keep');
    final sibling = await Directory('${parent.path}/another-session').create();
    final marker = await File('${sibling.path}/keep.txt')
        .writeAsString('other session');
    final storage = createVoiceStorage(temporaryDirectory: () async => parent);
    addTearDown(storage.close);
    final playback = await storage.createPlayback(Uint8List.fromList([1, 2]));
    await expectLater(
      storage.readRecording(unrelated.path, maxBytes: 10),
      throwsStateError,
    );
    await storage.releaseRecording(unrelated.path);
    await storage.close();
    expect(await File(playback.location).parent.exists(), isFalse);
    expect(await unrelated.readAsString(), 'keep');
    expect(await marker.readAsString(), 'other session');
  });

  test('parallel first recordings share one owned directory with distinct paths and enforce read bounds', () async {
    final parent = Directory('${fixture.path}/new/cache');
    final storage = createVoiceStorage(temporaryDirectory: () async => parent);
    addTearDown(storage.close);
    final paths = await Future.wait(
      List.generate(3, (_) => storage.createRecordingPath()),
    );
    expect(paths.toSet(), hasLength(3));
    expect(paths.map((path) => File(path).parent.path).toSet(), hasLength(1));
    await File(paths.first).writeAsBytes([1, 2, 3]);
    await expectLater(
      storage.readRecording(paths.first, maxBytes: 2),
      throwsStateError,
    );
  });

  test('a failed filesystem initialization can be retried without replacing the storage session', () async {
    final path = '${fixture.path}/blocked';
    await File(path).writeAsString('not a directory');
    final storage = createVoiceStorage(
      temporaryDirectory: () async => Directory(path),
    );
    addTearDown(storage.close);
    await expectLater(
      storage.createRecordingPath(),
      throwsA(isA<FileSystemException>()),
    );
    await File(path).delete();
    final recording = await storage.createRecordingPath();
    expect(await File(recording).parent.exists(), isTrue);
  });

  test(
    'closing during path-provider lookup removes only its late owned directory',
    () async {
      final parent = Directory('${fixture.path}/late-cache');
      final lookup = Completer<Directory>();
      final storage = createVoiceStorage(
        temporaryDirectory: () => lookup.future,
      );
      final recording = storage.createRecordingPath();
      final rejected = expectLater(recording, throwsStateError);
      final closing = storage.close();
      lookup.complete(parent);
      await rejected;
      await closing;
      expect(await parent.list().toList(), isEmpty);
    },
  );
}
