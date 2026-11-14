import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

export 'format.dart';

/// Rounded surface used everywhere. Optional [tint] adds a soft gradient wash.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.tint});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final inner = Padding(padding: padding, child: child);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: tint == null ? null : LinearGradient(colors: [tint!.withValues(alpha: 0.20), AppColors.surface], begin: Alignment.topLeft, end: Alignment.bottomRight, stops: const [0, 0.7]),
      ),
      child: Card(
        color: tint == null ? AppColors.surface : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? inner : InkWell(onTap: () { HapticFeedback.selectionClick(); onTap!(); }, child: inner),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
              if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle!, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5))),
            ]),
          ),
          ?trailing,
        ]),
      );
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = AppColors.textDim, this.icon, this.filled = false});
  final String text;
  final Color color;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: filled ? 0.9 : 0.14), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: filled ? AppColors.bg : color), const SizedBox(width: 4)],
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: filled ? AppColors.bg : color, fontSize: 11.5, fontWeight: FontWeight.w700))),
        ]),
      );
}

class ConfidenceChip extends StatelessWidget {
  const ConfidenceChip(this.level, {super.key});
  final String level;

  @override
  Widget build(BuildContext context) => Pill(
        '$level confidence',
        color: switch (level) { 'high' => AppColors.good, 'medium' => AppColors.warn, _ => AppColors.textDim },
        icon: Icons.verified_outlined,
      );
}

/// Counts up to [value] when it first appears or changes.
class AnimatedNumber extends StatelessWidget {
  const AnimatedNumber(this.value, {super.key, this.digits = 0, this.suffix = '', this.style, this.placeholder = '—'});
  final double? value;
  final int digits;
  final String suffix, placeholder;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final s = (style ?? const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)).copyWith(fontFeatures: tabular);
    if (value == null) return Text(placeholder, style: s);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value!),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text('${v.toStringAsFixed(digits)}$suffix', style: s),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.digits = 0, this.suffix = '', this.caption, this.color, this.onTap});
  final String label, suffix;
  final double? value; // null renders as an em dash (unknown), never 0
  final int digits;
  final String? caption;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => AppCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(color: AppColors.textDim, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          AnimatedNumber(value, digits: digits, suffix: suffix, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color ?? AppColors.text)),
          if (caption != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(caption!, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      );
}

/// Animated pill-style segmented control.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.options, required this.value, required this.onChanged});
  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: AppColors.surfaceHi, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          for (final e in options.entries)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (e.key != value) HapticFeedback.selectionClick();
                  onChanged(e.key);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: e.key == value ? AppColors.accent.withValues(alpha: 0.18) : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  // Five labels on a narrow phone with large text: shrink a label rather than spill out of its box.
                  child: FittedBox(fit: BoxFit.scaleDown, child: Text(e.value, maxLines: 1, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: e.key == value ? AppColors.accent : AppColors.textDim))),
                ),
              ),
            ),
        ]),
      );
}

class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.color = AppColors.warn, this.icon = Icons.info_outline, this.action});
  final String text;
  final Color color;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withValues(alpha: 0.3))),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13, height: 1.3))),
          ?action,
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});
  final IconData icon;
  final String title, message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(icon, size: 34, color: AppColors.accent),
            ),
            const SizedBox(height: 18),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim, height: 1.4)),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ]),
        ),
      );
}

/// Shimmering placeholder block shown while data loads.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.height = 80, this.radius = 20});
  final double height, radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Container(
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1 + 2 * _c.value, 0),
              end: Alignment(1 + 2 * _c.value, 0),
              colors: const [AppColors.surface, AppColors.surfaceHi, AppColors.surface],
            ),
          ),
        ),
      );
}

class LoadingList extends StatelessWidget {
  const LoadingList({super.key});
  @override
  Widget build(BuildContext context) => ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: const [Skeleton(height: 56), SizedBox(height: 14), Skeleton(height: 170), SizedBox(height: 14), Skeleton(height: 260), SizedBox(height: 14), Skeleton(height: 110)],
      );
}

/// Operator portrait with a ring colored by side. Falls back to initials when the image can't load.
class OperatorIcon extends StatelessWidget {
  const OperatorIcon({super.key, required this.name, this.url, this.attacker, this.size = 44});
  final String name;
  final String? url;
  final bool? attacker;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ring = attacker == null ? AppColors.outline : (attacker! ? AppColors.attack : AppColors.defense);
    final initials = Text(name.isEmpty ? '?' : name.substring(0, name.length < 2 ? 1 : 2).toUpperCase(), style: TextStyle(fontWeight: FontWeight.w800, fontSize: size * 0.34, color: AppColors.textDim));
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 2)),
      child: ClipOval(
        child: Container(
          color: AppColors.surfaceHi,
          alignment: Alignment.center,
          child: url == null
              ? initials
              : Stack(fit: StackFit.expand, alignment: Alignment.center, children: [
                  Center(child: initials), // visible immediately, covered once the art arrives
                  Image.network(
                    url!,
                    fit: BoxFit.cover,
                    cacheWidth: (size * 3).round(),
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    frameBuilder: (_, child, frame, sync) => AnimatedOpacity(opacity: (frame != null || sync) ? 1 : 0, duration: const Duration(milliseconds: 250), child: child),
                  ),
                ]),
        ),
      ),
    );
  }
}

class RankBadge extends StatelessWidget {
  const RankBadge({super.key, this.url, this.size = 84, this.color = AppColors.accent});
  final String? url;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: url == null
            ? Icon(Icons.military_tech, size: size * 0.7, color: color)
            : Image.network(url!, fit: BoxFit.contain, cacheWidth: (size * 3).round(), errorBuilder: (_, _, _) => Icon(Icons.military_tech, size: size * 0.7, color: color)),
      );
}

/// Opens a short explanation sheet.
void showInfo(BuildContext context, String title, String body) {
  HapticFeedback.selectionClick();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true, // long explanations must scroll instead of being clipped
    builder: (_) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text(body, style: const TextStyle(color: AppColors.textDim, height: 1.45)),
        ]),
      ),
    ),
  );
}

/// "13 h" or "40 min" for an age.
String ageText(Duration d) => d.inMinutes < 90 ? '${d.inMinutes} min' : (d.inHours < 48 ? '${d.inHours} h' : '${d.inDays} d');
