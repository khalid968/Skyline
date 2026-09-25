import 'models.dart';

/// The rules every device applies to message actions (board 28, owner
/// decision 2026-09-25), in one place so they can be tested on their own.
/// A sender's app offers only what these allow, and a RECEIVING device
/// ignores anything they refuse: a modified app could send it, but it would
/// never show.
class MessageRules {
  static const editWindow = Duration(minutes: 15);
  static const deleteWindow = Duration(hours: 24);
  static const maxPins = 3;

  /// Devices' clocks differ a little; a receiver allows this much.
  static const slack = Duration(minutes: 2);

  /// A reaction is one emoji: short, or it is ignored.
  static const maxReactionRunes = 8;

  // ------------------------------------------------------ what you may do

  static bool canEdit(LocalMessage m, DateTime now) =>
      m.fromMe && m.kind == MessageKind.text && !m.deleted && now.difference(m.sentAt) < editWindow;

  static bool canDeleteForEveryone(LocalMessage m, DateTime now) =>
      m.fromMe && !m.isNotice && !m.deleted && now.difference(m.sentAt) < deleteWindow;

  // --------------------------------------------- what a receiver accepts

  /// An edit of [target] sent at [sentAt]: by its author, of a text that is
  /// still there, with a text body, and within the window (plus slack).
  static bool acceptEdit({
    required LocalMessage target,
    required bool byAuthor,
    required Object? body,
    required DateTime sentAt,
  }) =>
      byAuthor &&
      !target.deleted &&
      body is String &&
      target.kind == MessageKind.text &&
      sentAt.difference(target.sentAt) <= editWindow + slack;

  static bool acceptDelete({required LocalMessage target, required bool byAuthor, required DateTime sentAt}) =>
      byAuthor && !target.deleted && sentAt.difference(target.sentAt) <= deleteWindow + slack;

  /// The reaction to store, or null to remove the sender's reaction.
  static String? reaction(Object? emoji) =>
      emoji is String && emoji.isNotEmpty && emoji.runes.length <= maxReactionRunes ? emoji : null;
}
