import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../media/data/media_service.dart';
import '../../messages/data/local_store.dart';
import '../../messages/data/messenger.dart';
import '../../messages/domain/models.dart';

/// Phase 14d (board 46): profile photos, end-to-end encrypted.
///
/// Your photo is encrypted on this device like any attachment and uploaded;
/// the server only learns which (unreadable) upload is your current photo.
/// Its key goes to each contact inside a Signal message ({"type":"profile"}),
/// again whenever a contact is new, gets a new device, or the photo changes.
/// A contact's photo is downloaded only when the server lists it as theirs,
/// decrypted, and kept in this device's vault.
///
/// Groups: members you are not linked to see initials (the key travels
/// one-to-one only, for now).
class ProfilePhotos extends ChangeNotifier {
  ProfilePhotos({required this.messenger, required this.media, required this.store}) {
    messenger.onProfile = _received;
    messenger.addListener(_contactsMaybeChanged);
  }

  final Messenger messenger;
  final MediaService media;
  final LocalStore store;

  static const _uuid = Uuid();
  final Map<String, Uint8List?> _photos = {}; // userId -> JPEG (null: none)
  final Map<String, String?> _shown = {}; // userId -> the upload those bytes came from
  final Set<String> _loading = {};
  bool _syncing = false;
  bool _syncAgain = false;
  bool _disposed = false;

  /// This person's photo, if we have it (the avatar shows initials meanwhile).
  Uint8List? photoOf(String userId) {
    if (!_photos.containsKey(userId) && _loading.add(userId)) unawaited(_load(userId));
    return _photos[userId];
  }

  Future<void> _load(String userId) async {
    try {
      final saved = await store.setting('photo.bytes.$userId');
      _photos[userId] = saved is Map && saved['b'] is String ? base64.decode(saved['b'] as String) : null;
      _shown[userId] = saved is Map ? saved['a'] as String? : null;
    } on Object {
      _photos[userId] = null;
    } finally {
      _loading.remove(userId);
      _changed();
    }
    // A contact's photo whose key arrived but was never fetched.
    final listed = messenger.contact(userId)?.photo;
    if (listed != null && _shown[userId] != listed) unawaited(_fetch(userId));
  }

  // ---------------------------------------------------------- your photo

  /// Sets your photo: [jpeg] is the cropped, resized, re-encoded image.
  Future<void> setMine(Uint8List jpeg) async {
    final dir = await getTemporaryDirectory();
    final tmp = File('${dir.path}${Platform.pathSeparator}skyline-photo-${_uuid.v4()}.jpg');
    await tmp.writeAsBytes(jpeg, flush: true);
    final key = 'profile-${_uuid.v4()}';
    final info = MediaInfo(kind: MediaKind.photo, name: 'photo.jpg', mime: 'image/jpeg', size: jpeg.length);
    try {
      await media.encrypt(key, tmp, info);
      await media.upload(key, info, onStarted: () async {});
      await messenger.api.put('/me/photo', {'attachmentId': info.attachmentId});
    } finally {
      media.finished(key);
      if (await tmp.exists()) await tmp.delete();
    }
    final version = ((await store.setting('photo.mine.version')) as int? ?? 0) + 1;
    await store.putSetting('photo.mine', {..._wire(info), 'version': version});
    await store.putSetting('photo.mine.version', version);
    await store.putSetting('photo.bytes.${messenger.me}', {'a': info.attachmentId, 'b': base64.encode(jpeg)});
    _photos[messenger.me] = jpeg;
    _shown[messenger.me] = info.attachmentId;
    _changed();
    unawaited(_syncToContacts());
  }

  /// Back to initials, everywhere.
  Future<void> removeMine() async {
    await messenger.api.delete('/me/photo');
    final version = ((await store.setting('photo.mine.version')) as int? ?? 0) + 1;
    await store.putSetting('photo.mine', {'removed': true, 'version': version});
    await store.putSetting('photo.mine.version', version);
    await store.putSetting('photo.bytes.${messenger.me}', null);
    _photos[messenger.me] = null;
    _shown[messenger.me] = null;
    _changed();
    unawaited(_syncToContacts());
  }

  bool get hasMine => _photos[messenger.me] != null;

  Map<String, Object?> _wire(MediaInfo m) => {
        'attachmentId': m.attachmentId,
        'key': m.key,
        'nonce': m.nonce,
        'sha256': m.sha256,
        'size': m.cipherSize,
      };

  /// Sends the current photo (or "removed") to every contact whose copy is out
  /// of date: a new contact, a new device of theirs, or a new photo.
  Future<void> _syncToContacts() async {
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _syncAgain = false;
        final mine = await store.setting('photo.mine');
        if (mine is! Map) return; // never set: nothing to tell anyone
        final version = mine['version'];
        final sent = Map<String, Object?>.from((await store.setting('photo.sent')) as Map? ?? const {});
        var changed = false;
        for (final c in messenger.contacts) {
          if (c.suspended) continue;
          final stamp = '$version|${(c.devices.map((d) => d.deviceNumber).toList()..sort()).join(',')}';
          if (sent[c.userId] == stamp) continue;
          try {
            await messenger.sendProfile(c.userId, Map<String, Object?>.from(mine)..remove('version'));
            sent[c.userId] = stamp;
            changed = true;
          } on Object {
            // offline: the next contacts refresh tries again
          }
        }
        if (changed) await store.putSetting('photo.sent', sent);
      } while (_syncAgain);
    } finally {
      _syncing = false;
    }
  }

  // ------------------------------------------------------ their photos

  /// A profile message: from a contact, or from one of our own devices (then
  /// it is our own photo, set elsewhere).
  Future<void> _received(String userId, Map<String, Object?> content) async {
    if (content['removed'] == true) {
      await store.putSetting('photo.key.$userId', null);
      await store.putSetting('photo.bytes.$userId', null);
      _photos[userId] = null;
      _shown[userId] = null;
      _changed();
      return;
    }
    if (content['attachmentId'] is! String || content['key'] is! String) return;
    await store.putSetting('photo.key.$userId', {
      for (final k in const ['attachmentId', 'key', 'nonce', 'sha256', 'size']) k: content[k],
    });
    await _fetch(userId);
  }

  /// Downloads and decrypts [userId]'s photo if we hold its key and the server
  /// lists that upload as their current photo.
  Future<void> _fetch(String userId) async {
    final k = await store.setting('photo.key.$userId');
    if (k is! Map) return;
    final listed = userId == messenger.me ? k['attachmentId'] : messenger.contact(userId)?.photo;
    if (listed == null || listed != k['attachmentId']) return; // not (yet) theirs
    final info = MediaInfo(
      kind: MediaKind.photo,
      name: 'photo.jpg',
      mime: 'image/jpeg',
      size: 0,
      attachmentId: k['attachmentId'] as String,
      key: k['key'] as String,
      nonce: k['nonce'] as String? ?? '',
      sha256: k['sha256'] as String? ?? '',
      cipherSize: (k['size'] as num?)?.toInt() ?? 0,
    );
    try {
      await media.download('profile-$userId', info);
      final bytes = await media.bytes(info);
      await store.putSetting('photo.bytes.$userId', {'a': info.attachmentId, 'b': base64.encode(bytes)});
      final f = media.fileOf(info);
      if (await f.exists()) await f.delete(); // kept decrypted in the vault instead
      _photos[userId] = bytes;
      _shown[userId] = info.attachmentId;
      _changed();
    } on Object {
      // expired, replaced or offline: shown with initials; retried later
    }
  }

  String _seenContacts = '';

  /// After a contacts refresh: tell new contacts (and new devices) our photo,
  /// and follow contacts' photos appearing, changing or going away.
  void _contactsMaybeChanged() {
    final now = [
      for (final c in messenger.contacts) '${c.userId}:${c.photo}:${c.devices.length}',
    ].join(';');
    if (now == _seenContacts) return;
    _seenContacts = now;
    for (final c in messenger.contacts) {
      if (c.photo == null && _photos[c.userId] != null) {
        _photos[c.userId] = null;
        _shown[c.userId] = null;
        unawaited(store.putSetting('photo.bytes.${c.userId}', null));
        _changed();
      } else if (c.photo != null) {
        unawaited(_fetchIfNew(c.userId, c.photo!));
      }
    }
    unawaited(_syncToContacts());
  }

  Future<void> _fetchIfNew(String userId, String attachmentId) async {
    final k = await store.setting('photo.key.$userId');
    if (k is Map && k['attachmentId'] == attachmentId && _shown[userId] != attachmentId) await _fetch(userId);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    messenger.removeListener(_contactsMaybeChanged);
    if (messenger.onProfile == _received) messenger.onProfile = null;
    super.dispose();
  }
}
