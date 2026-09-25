// Phase 12: the app's rules, tested on their own (no device, no server).
// The end-to-end tests prove the pieces work together; these prove each rule
// at its edges, where a mistake would hide.
import 'package:flutter_test/flutter_test.dart';
import 'package:skyline/features/calls/data/call_service.dart';
import 'package:skyline/features/messages/domain/message_rules.dart';
import 'package:skyline/features/messages/domain/models.dart';
import 'package:skyline/features/messages/presentation/timer_sheet.dart';

final t0 = DateTime.utc(2026, 9, 26, 10);

LocalMessage msg({
  bool fromMe = true,
  MessageKind kind = MessageKind.text,
  bool deleted = false,
  NoticeType? notice,
}) =>
    LocalMessage(
      id: 'm1',
      peerUserId: 'bob',
      fromMe: fromMe,
      sentAt: t0,
      kind: notice != null ? MessageKind.notice : kind,
      notice: notice,
      text: 'hello',
      deleted: deleted,
    );

void main() {
  group('what you may do to your own message (board 28)', () {
    test('edit: your own text, not deleted, for 15 minutes', () {
      final almost = t0.add(const Duration(minutes: 14, seconds: 59));
      final late = t0.add(const Duration(minutes: 15));
      expect(MessageRules.canEdit(msg(), almost), isTrue);
      expect(MessageRules.canEdit(msg(), late), isFalse);
      expect(MessageRules.canEdit(msg(fromMe: false), almost), isFalse);
      expect(MessageRules.canEdit(msg(kind: MessageKind.media), almost), isFalse);
      expect(MessageRules.canEdit(msg(deleted: true), almost), isFalse);
    });

    test('delete for everyone: your own, not a notice, for 24 hours', () {
      final almost = t0.add(const Duration(hours: 23, minutes: 59));
      final late = t0.add(const Duration(hours: 24));
      expect(MessageRules.canDeleteForEveryone(msg(), almost), isTrue);
      expect(MessageRules.canDeleteForEveryone(msg(), late), isFalse);
      expect(MessageRules.canDeleteForEveryone(msg(fromMe: false), almost), isFalse);
      expect(MessageRules.canDeleteForEveryone(msg(notice: NoticeType.pinned), almost), isFalse);
    });
  });

  group('what a receiving device accepts (a modified app cannot get past these)', () {
    test('an edit only from the author, of a live text, inside the window plus 2 minutes of slack', () {
      bool edit({bool byAuthor = true, Object? body = 'new', Duration after = Duration.zero, LocalMessage? target}) =>
          MessageRules.acceptEdit(target: target ?? msg(fromMe: false), byAuthor: byAuthor, body: body, sentAt: t0.add(after));
      expect(edit(), isTrue);
      expect(edit(after: const Duration(minutes: 17)), isTrue);
      expect(edit(after: const Duration(minutes: 17, seconds: 1)), isFalse);
      expect(edit(byAuthor: false), isFalse);
      expect(edit(body: 42), isFalse);
      expect(edit(body: null), isFalse);
      expect(edit(target: msg(fromMe: false, deleted: true)), isFalse);
      expect(edit(target: msg(fromMe: false, kind: MessageKind.media)), isFalse);
    });

    test('a deletion only from the author, inside 24 hours plus slack', () {
      bool del({bool byAuthor = true, Duration after = Duration.zero}) =>
          MessageRules.acceptDelete(target: msg(fromMe: false), byAuthor: byAuthor, sentAt: t0.add(after));
      expect(del(after: const Duration(hours: 24, minutes: 2)), isTrue);
      expect(del(after: const Duration(hours: 24, minutes: 2, seconds: 1)), isFalse);
      expect(del(byAuthor: false), isFalse);
      expect(
        MessageRules.acceptDelete(target: msg(fromMe: false, deleted: true), byAuthor: true, sentAt: t0),
        isFalse,
        reason: 'already deleted',
      );
    });

    test('a reaction is one short emoji; anything else removes it', () {
      expect(MessageRules.reaction('\u{1F44D}'), '\u{1F44D}');
      // A family emoji is several code points joined, and still one reaction.
      expect(MessageRules.reaction('\u{1F468}‍\u{1F469}‍\u{1F467}'), isNotNull);
      expect(MessageRules.reaction(''), isNull);
      expect(MessageRules.reaction(null), isNull);
      expect(MessageRules.reaction(7), isNull);
      expect(MessageRules.reaction('this is a sentence, not a reaction'), isNull);
    });
  });

  group('calls (Phase 10)', () {
    test('an offer rings only while the server has held it for 50 seconds or less', () {
      expect(CallService.ringsAfter(Duration.zero), isTrue);
      expect(CallService.ringsAfter(const Duration(seconds: 50)), isTrue);
      expect(CallService.ringsAfter(const Duration(seconds: 51)), isFalse);
    });

    test('how each ending is written in the chat, on each side', () {
      String rec(String o, {bool outgoing = true, bool connected = false}) =>
          CallService.recordedOutcome(o, outgoing: outgoing, connected: connected);
      expect(rec('completed'), 'completed');
      expect(rec('noAnswer'), 'noAnswer');
      expect(rec('noAnswer', outgoing: false), 'missed');
      expect(rec('cancelled'), 'noAnswer');
      expect(rec('cancelled', outgoing: false), 'missed');
      expect(rec('declined'), 'declined');
      expect(rec('declined', outgoing: false), 'declined');
      expect(rec('busy'), 'busy');
      expect(rec('missed', outgoing: false), 'missed');
      // A failure after connecting was still a call; before, it never happened.
      expect(rec('failed', connected: true), 'completed');
      expect(rec('failed'), 'noAnswer');
      expect(rec('failed', outgoing: false), 'missed');
    });
  });

  group('what the vault keeps survives a round trip', () {
    test('a message with everything on it', () {
      final m = LocalMessage(
        id: 'm9',
        peerUserId: 'group-1',
        fromMe: false,
        sentAt: t0,
        text: 'See you at 10:30',
        status: MessageStatus.delivered,
        senderUserId: 'carol',
        senderName: 'Carol Example',
        replyTo: const {'id': 'm8', 'author': 'bob', 'preview': 'When?'},
        editedAt: t0.add(const Duration(minutes: 3)),
        reactions: {'bob': '\u{1F44D}'},
        mentions: const ['alice'],
        timerSeconds: 3600,
      );
      final back = LocalMessage.fromJson(m.toJson());
      expect(back.toJson(), m.toJson());
      expect(back.author, 'carol');
      expect(back.replyTo!['preview'], 'When?');
      expect(back.reactions, {'bob': '\u{1F44D}'});
    });

    test('a call line', () {
      final m = LocalMessage(
        id: 'c1',
        peerUserId: 'bob',
        fromMe: true,
        sentAt: t0,
        kind: MessageKind.notice,
        notice: NoticeType.call,
        noticeData: const {'video': true, 'outgoing': true, 'outcome': 'completed', 'seconds': 67},
      );
      final back = LocalMessage.fromJson(m.toJson());
      expect(back.notice, NoticeType.call);
      expect(back.noticeData['seconds'], 67);
    });

    test('a chat summary with pins, a timer and a mention', () {
      final c = ChatSummary(
        peerUserId: 'group-1',
        displayName: 'Operations',
        username: '',
        lastText: 'Dana: gate code changes Friday',
        lastAt: t0,
        unread: 3,
        timerSeconds: 86400,
        isGroup: true,
        pins: ['a', 'b'],
        mentioned: true,
      );
      expect(ChatSummary.fromJson(c.toJson()).toJson(), c.toJson());
    });
  });

  test('timer labels read as on board 15', () {
    expect(timerLabel(null), 'Off');
    expect(timerLabel(3600), '1 hour');
    expect(timerLabel(7 * 86400), '1 week');
    expect(timerLabel(2 * 3600), '2 hours');
    expect(timerLabel(5 * 60), '5 minutes');
    expect(timerLabel(14 * 86400), '2 weeks');
  });
}
