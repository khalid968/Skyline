import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';

/// The pieces boards 43 and 44 share: section titles, notes, cards and rows.
class SettingsSection extends StatelessWidget {
  const SettingsSection(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Semantics(
          header: true,
          child: Text(text.toUpperCase(),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.7,
                color: context.sky.textSecondary,
              )),
        ),
      );
}

class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text(text, style: TextStyle(fontSize: 12, height: 1.55, color: context.sky.textSecondary)),
      );
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children, this.padding});
  final List<Widget> children;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 && padding == null) Divider(height: 1, color: t.border),
          children[i],
        ],
      ]),
    );
  }
}

/// A row that opens another screen: a tinted icon, a title and a summary.
class SettingsLink extends StatelessWidget {
  const SettingsLink({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  final SkyIcons icon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tint.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
            child: SkyIcon(icon, size: 18, color: tint, stroke: 2),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 15, color: t.textPrimary)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
            ]),
          ),
          if (onTap != null) SkyIcon(SkyIcons.chevron, size: 16, color: t.textSecondary, stroke: 2),
        ]),
      ),
    );
  }
}

class SettingsAppBar extends StatelessWidget implements PreferredSizeWidget {
  const SettingsAppBar({super.key, required this.title, this.actions});
  final String title;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return AppBar(
      leading: IconButton(
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
        icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
      ),
      title: Text(title),
      actions: actions,
    );
  }
}
