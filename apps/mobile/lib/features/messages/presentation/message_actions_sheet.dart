import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';

enum MessageAction { reply, edit, copy, pin, unpin, info, delete }

/// What the person chose in the sheet: an action, or a reaction.
class ActionChoice {
  ActionChoice.action(this.action) : emoji = null;
  ActionChoice.react(this.emoji) : action = null;
  final MessageAction? action;
  final String? emoji;
}

const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Board 28: long-press (right-click on a PC) a message. Six quick reactions
/// and the full picker, then the actions that apply to this message.
Future<ActionChoice?> showMessageActions(
  BuildContext context, {
  required List<MessageAction> actions,
  String? myReaction,
  bool canReact = true,
}) {
  final t = context.sky;
  return showModalBottomSheet<ActionChoice>(
    context: context,
    backgroundColor: t.surface,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (canReact)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                for (final e in quickReactions)
                  _ReactionButton(
                    emoji: e,
                    selected: e == myReaction,
                    onTap: () => Navigator.pop(ctx, ActionChoice.react(e)),
                  ),
                Semantics(
                  button: true,
                  label: 'More emoji',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () async {
                      final picked = await showEmojiPicker(ctx);
                      if (picked != null && ctx.mounted) Navigator.pop(ctx, ActionChoice.react(picked));
                    },
                    child: Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: t.border, shape: BoxShape.circle),
                      child: SkyIcon(SkyIcons.plus, size: 20, color: t.textSecondary, stroke: 2),
                    ),
                  ),
                ),
              ]),
            ),
          for (final a in actions)
            ListTile(
              leading: SkyIcon(_icon(a), size: 20, color: a == MessageAction.delete ? const Color(0xFFFF9AA0) : t.textPrimary),
              title: Text(_label(a),
                  style: TextStyle(fontSize: 15, color: a == MessageAction.delete ? const Color(0xFFFF9AA0) : t.textPrimary)),
              trailing: _note(a) == null ? null : Text(_note(a)!, style: TextStyle(fontSize: 12, color: t.textSecondary)),
              onTap: () => Navigator.pop(ctx, ActionChoice.action(a)),
            ),
        ]),
      ),
    ),
  );
}

/// The full picker. Recently used emoji are NOT remembered: that list would
/// sit in unencrypted app storage.
Future<String?> showEmojiPicker(BuildContext context) {
  final t = context.sky;
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: t.surface,
    builder: (ctx) => SizedBox(
      height: 340,
      child: EmojiPicker(
        onEmojiSelected: (category, emoji) => Navigator.pop(ctx, emoji.emoji),
        config: Config(
          emojiViewConfig: EmojiViewConfig(backgroundColor: t.surface, columns: 8),
          categoryViewConfig: CategoryViewConfig(
            recentTabBehavior: RecentTabBehavior.NONE,
            backgroundColor: t.surface,
            indicatorColor: t.accentText,
            iconColorSelected: t.accentText,
          ),
          bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
          searchViewConfig: SearchViewConfig(backgroundColor: t.surface),
        ),
      ),
    ),
  );
}

/// Board 28's delete choice. Returns true for everyone, false for me, null
/// to cancel.
Future<bool?> showDeleteChoice(BuildContext context, {required bool forEveryone, required String who}) {
  final t = context.sky;
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: t.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Delete this message?',
              style: TextStyle(fontFamily: SkyFonts.display, fontSize: 18, fontWeight: FontWeight.w700, color: t.textPrimary)),
          const SizedBox(height: 8),
          Text(
            forEveryone
                ? '"For everyone" removes it from $who\'s devices too, and leaves a note that a message was deleted. '
                    'Possible for 24 hours after sending; a copy someone already saved or photographed cannot be recalled.'
                : '"For me" removes it from this device only.',
            style: TextStyle(fontSize: 13, height: 1.5, color: t.textSecondary),
          ),
          const SizedBox(height: 14),
          if (forEveryone) ...[
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: t.danger, minimumSize: const Size.fromHeight(46)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete for everyone'),
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Delete for me'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ]),
      ),
    ),
  );
}

class _ReactionButton extends StatelessWidget {
  const _ReactionButton({required this.emoji, required this.selected, required this.onTap});
  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Semantics(
      button: true,
      selected: selected,
      label: 'React $emoji',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? t.accentFill.withValues(alpha: 0.35) : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Text(emoji, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}

SkyIcons _icon(MessageAction a) => switch (a) {
      MessageAction.reply => SkyIcons.reply,
      MessageAction.edit => SkyIcons.pen,
      MessageAction.copy => SkyIcons.copy,
      MessageAction.pin || MessageAction.unpin => SkyIcons.pin,
      MessageAction.info => SkyIcons.info,
      MessageAction.delete => SkyIcons.trash,
    };

String _label(MessageAction a) => switch (a) {
      MessageAction.reply => 'Reply',
      MessageAction.edit => 'Edit',
      MessageAction.copy => 'Copy',
      MessageAction.pin => 'Pin',
      MessageAction.unpin => 'Unpin',
      MessageAction.info => 'Info',
      MessageAction.delete => 'Delete',
    };

String? _note(MessageAction a) => switch (a) {
      MessageAction.edit => 'for 15 minutes',
      MessageAction.pin => 'everyone sees it',
      _ => null,
    };
