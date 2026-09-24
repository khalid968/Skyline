import 'dart:convert';

import '../../../core/crypto/device_crypto.dart';
import '../domain/models.dart';

/// The app's history on this device, sealed in the crypto vault's records
/// (AES-256-GCM-SIV under the keystore-held key; ids and chat ids HMAC'd).
/// Nothing here is ever sent anywhere.
class LocalStore {
  LocalStore(this.crypto);
  final CryptoDevice crypto;

  static const _chat = 'chat';
  static const _message = 'message';
  static const _device = 'device';
  static const _setting = 'setting';
  static const _all = 'all';

  Future<void> _put(String kind, String id, String group, int sort, Map<String, Object?> v) =>
      crypto.putRecord(kind: kind, id: id, group: group, sort: sort, value: utf8.encode(jsonEncode(v)));

  Future<Map<String, Object?>?> _get(String kind, String id) async {
    final raw = await crypto.getRecord(kind: kind, id: id);
    return raw == null ? null : jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
  }

  Future<List<Map<String, Object?>>> _list(String kind, String group, {int? before, int limit = 200}) async {
    final rows = await crypto.listRecords(kind: kind, group: group, beforeSort: before, limit: limit);
    return [for (final r in rows) jsonDecode(utf8.decode(r.value)) as Map<String, Object?>];
  }

  // ------------------------------------------------------------- chats

  Future<List<ChatSummary>> chats() async =>
      [for (final j in await _list(_chat, _all, limit: 1000)) ChatSummary.fromJson(j)];

  Future<ChatSummary?> chat(String peer) async {
    final j = await _get(_chat, peer);
    return j == null ? null : ChatSummary.fromJson(j);
  }

  Future<void> putChat(ChatSummary c) => _put(
        _chat,
        c.peerUserId,
        _all,
        (c.lastAt ?? DateTime.fromMillisecondsSinceEpoch(0)).millisecondsSinceEpoch,
        c.toJson(),
      );

  // ---------------------------------------------------------- messages

  /// Newest first.
  Future<List<LocalMessage>> messages(String peer, {DateTime? before, int limit = 60}) async => [
        for (final j in await _list(_message, peer, before: before?.millisecondsSinceEpoch, limit: limit))
          LocalMessage.fromJson(j),
      ];

  Future<LocalMessage?> message(String id) async {
    final j = await _get(_message, id);
    return j == null ? null : LocalMessage.fromJson(j);
  }

  Future<void> putMessage(LocalMessage m) =>
      _put(_message, m.id, m.peerUserId, m.sentAt.millisecondsSinceEpoch, m.toJson());

  Future<void> deleteMessage(String id) => crypto.deleteRecord(kind: _message, id: id);

  // ----------------------------------------------------------- devices

  Future<List<KnownDevice>> devicesOf(String userId) async =>
      [for (final j in await _list(_device, userId)) KnownDevice.fromJson(j)];

  Future<void> putDevice(KnownDevice d) =>
      _put(_device, d.key, d.userId, d.deviceNumber, d.toJson());

  // ---------------------------------------------------------- settings

  Future<Object?> setting(String name) async => (await _get(_setting, name))?['v'];

  Future<void> putSetting(String name, Object? value) => _put(_setting, name, _all, 0, {'v': value});
}
