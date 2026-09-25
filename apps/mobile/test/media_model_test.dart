import 'package:flutter_test/flutter_test.dart';
import 'package:skyline/features/media/data/media_service.dart';
import 'package:skyline/features/media/presentation/media_format.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/domain/models.dart';

void main() {
  group('MediaInfo', () {
    MediaInfo sample() => MediaInfo(
          kind: MediaKind.voice,
          name: 'Voice message.m4a',
          mime: 'audio/mp4',
          size: 4096,
          attachmentId: '6f0f8c1e-0000-4000-8000-000000000001',
          cipherSize: 4112,
          key: 'a2V5',
          nonce: 'bm9uY2U=',
          sha256: 'aGFzaA==',
          durationMs: 4200,
          wave: const [3, 9, 31],
          localFile: 'x.enc',
          state: MediaState.ready,
        );

    test('the wire form carries what the recipient needs and nothing local', () {
      final wire = sample().toWire();
      expect(wire['id'], '6f0f8c1e-0000-4000-8000-000000000001');
      expect(wire['key'], 'a2V5');
      expect(wire.containsKey('localFile'), isFalse);
      expect(wire.containsKey('state'), isFalse);
      final back = MediaInfo.fromWire(wire)!;
      expect(back.kind, MediaKind.voice);
      expect(back.durationMs, 4200);
      expect(back.wave, [3, 9, 31]);
      expect(back.state, MediaState.remote); // not on the recipient's device yet
    });

    test('a received file with no id, key or known kind is ignored', () {
      final wire = sample().toWire();
      expect(MediaInfo.fromWire({...wire, 'id': null}), isNull);
      expect(MediaInfo.fromWire({...wire, 'key': 42}), isNull);
      expect(MediaInfo.fromWire({...wire, 'kind': 'hologram'}), isNull);
      expect(MediaInfo.fromWire('nonsense'), isNull);
    });

    test('a sender cannot push waveform values out of range', () {
      final back = MediaInfo.fromWire({...sample().toWire(), 'wave': [-5, 999, 12]})!;
      expect(back.wave, [0, 31, 12]);
    });

    test('the local record keeps where the ciphertext is, even before upload', () {
      final pending = MediaInfo(kind: MediaKind.file, name: 'a.pdf', mime: 'application/pdf', size: 10)
        ..localFile = 'y.enc'
        ..state = MediaState.uploading;
      final back = MediaInfo.fromJson(pending.toJson());
      expect(back.localFile, 'y.enc');
      expect(back.state, MediaState.uploading);
      expect(back.attachmentId, isNull);
    });

    test('a message with media survives the vault round trip', () {
      final m = LocalMessage(
        id: 'm1',
        peerUserId: 'p',
        fromMe: false,
        sentAt: DateTime.fromMillisecondsSinceEpoch(1000),
        kind: MessageKind.media,
        text: 'caption',
        media: sample(),
      );
      final back = LocalMessage.fromJson(m.toJson());
      expect(back.isMedia, isTrue);
      expect(back.media!.localFile, 'x.enc');
      expect(back.text, 'caption');
    });
  });

  group('albums and view once', () {
    MediaInfo item(MediaKind k) =>
        MediaInfo(kind: k, name: 'x', mime: 'm', size: 1, attachmentId: 'a', key: 'k', nonce: 'n', thumb: 't')
          ..localFile = 'f.enc'
          ..state = MediaState.ready;

    LocalMessage msg(List<MediaInfo> items, {bool once = false}) => LocalMessage(
          id: 'm',
          peerUserId: 'p',
          fromMe: false,
          sentAt: DateTime.fromMillisecondsSinceEpoch(0),
          kind: MessageKind.media,
          items: items,
          viewOnce: once,
        );

    test('labels say what is inside', () {
      expect(msg([item(MediaKind.photo)]).mediaLabel, 'Photo');
      expect(msg([item(MediaKind.photo)], once: true).mediaLabel, 'Photo · view once');
      expect(msg([item(MediaKind.photo), item(MediaKind.photo), item(MediaKind.photo)]).mediaLabel, '3 photos');
      expect(msg([item(MediaKind.video), item(MediaKind.video)]).mediaLabel, '2 videos');
      expect(msg([item(MediaKind.photo), item(MediaKind.video)]).mediaLabel, '2 photos and videos');
    });

    test('an album and its view-once flag survive the vault round trip', () {
      final m = msg([item(MediaKind.photo), item(MediaKind.video)], once: true)..openedAt = DateTime(2026);
      final back = LocalMessage.fromJson(m.toJson());
      expect(back.items.map((i) => i.kind), [MediaKind.photo, MediaKind.video]);
      expect(back.viewOnce, isTrue);
      expect(back.openedAt, DateTime(2026));
    });

    test('messages stored before albums (one "media" entry) still load', () {
      final old = msg([item(MediaKind.photo)]).toJson()
        ..remove('items')
        ..['media'] = item(MediaKind.voice).toJson();
      final back = LocalMessage.fromJson(old);
      expect(back.items.single.kind, MediaKind.voice);
    });

    test('burning a view-once item leaves nothing that could decrypt it', () {
      final i = item(MediaKind.photo)..burn();
      expect(i.burned, isTrue);
      expect(i.key, isEmpty);
      expect(i.nonce, isEmpty);
      expect(i.thumb, isNull);
      expect(i.localFile, isNull);
      expect(MediaInfo.fromJson(i.toJson()).burned, isTrue);
    });
  });

  test('file names from a sender cannot escape the viewing folder', () {
    expect(MediaService.safeName('../../etc/passwd'), '.._.._etc_passwd');
    expect(MediaService.safeName(r'C:\Windows\x.dll'), 'C__Windows_x.dll');
    expect(MediaService.safeName('..'), 'file');
    expect(MediaService.safeName(''), 'file');
    final long = MediaService.safeName('${'a' * 300}.pdf');
    expect(long.length, 120);
    expect(long.endsWith('.pdf'), isTrue);
  });

  test('sizes, progress and durations read as on the boards', () {
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatBytes(184 * 1024 * 1024), '184 MB');
    expect(formatProgress((3.1 * 1024 * 1024).round(), 5 * 1024 * 1024), '3.1 of 5.0 MB');
    expect(formatProgress((4.8 * 1024 * 1024).round(), 12 * 1024 * 1024), '5 of 12 MB');
    expect(formatDuration(161000), '2:41');
    expect(formatDuration(7000), '0:07');
  });

  test('content types follow the file name', () {
    expect(mimeFor('Site_Survey_v3.pdf', MediaKind.file), 'application/pdf');
    expect(mimeFor('clip.MOV', MediaKind.video), 'video/quicktime');
    expect(mimeFor('noext', MediaKind.photo), 'image/jpeg');
  });
}
