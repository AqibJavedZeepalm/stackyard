import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/models.dart';
import 'motion.dart';

/// A tech's official logo, used in the sidebar and headers. Falls back to a
/// monogram tile for techs without one.
class TechBadge extends StatelessWidget {
  const TechBadge(this.info, {super.key, this.size = 20});

  final TechInfo info;
  final double size;

  @override
  Widget build(BuildContext context) {
    final logo = info.logo;
    if (logo != null) {
      final dark = FluentTheme.of(context).brightness == Brightness.dark;
      final tint = switch (info.logoTint) {
        LogoTint.none => null,
        // Deep brand colors (e.g. .NET purple) get lifted so they read on dark.
        LogoTint.brand => dark && info.color.computeLuminance() < 0.12 ? Color.lerp(info.color, const Color(0xFFFFFFFF), 0.35) : info.color,
        LogoTint.foreground => dark ? const Color(0xFFFFFFFF) : const Color(0xFF1B1B1B),
      };
      return SizedBox(
        width: size,
        height: size,
        child: SvgPicture.asset(
          logo,
          width: size,
          height: size,
          colorFilter: tint == null ? null : ColorFilter.mode(tint, BlendMode.srcIn),
          semanticsLabel: info.name,
        ),
      );
    }
    final onColor = info.color.computeLuminance() > 0.5 ? const Color(0xFF111111) : const Color(0xFFFFFFFF);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: info.color, borderRadius: BorderRadius.circular(size * 0.24)),
      child: Text(
        info.monogram,
        style: TextStyle(
          color: onColor,
          fontSize: size * (info.monogram.length > 1 ? 0.42 : 0.52),
          fontWeight: FontWeight.w600,
          height: 1,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

/// Colors and wording for each item status.
class StatusStyle {
  const StatusStyle(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;

  static StatusStyle of(BuildContext context, ItemStatus s) {
    final r = FluentTheme.of(context).resources;
    final accent = FluentTheme.of(context).accentColor.defaultBrushFor(FluentTheme.of(context).brightness);
    return switch (s) {
      ItemStatus.global => StatusStyle('Global', accent, WindowsIcons.globe),
      ItemStatus.inUse => StatusStyle('In use', r.systemFillColorSuccess, WindowsIcons.check_mark),
      ItemStatus.stale => StatusStyle('Stale', r.systemFillColorCaution, WindowsIcons.history),
      ItemStatus.unused => StatusStyle('Unused', r.textFillColorSecondary, WindowsIcons.circle_ring),
      ItemStatus.broken => StatusStyle('Broken', r.systemFillColorCritical, WindowsIcons.error),
      ItemStatus.cache => StatusStyle('Cache', r.textFillColorSecondary, WindowsIcons.sync),
      ItemStatus.unknown => StatusStyle('Not tracked', r.textFillColorTertiary, WindowsIcons.unknown),
    };
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key});
  final ItemStatus status;

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(context, status);
    return Pill(label: s.label, color: s.color);
  }
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 10, color: color), const SizedBox(width: 4)],
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// A Windows 11 "settings card": layer fill, hairline stroke, hover tint.
class SurfaceCard extends StatefulWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.onPressed,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.radius = 6,
    this.highlight,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsets padding;
  final double radius;
  final Color? highlight;

  @override
  State<SurfaceCard> createState() => _SurfaceCardState();
}

class _SurfaceCardState extends State<SurfaceCard> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final r = theme.resources;
    final interactive = widget.onPressed != null;
    // Hover and press layer Windows' subtle fills over the card, so they stay a
    // gentle shade in both themes (setting alpha directly turned dark cards white).
    final base = r.cardBackgroundFillColorDefault;
    final bg = !interactive
        ? base
        : _down
        ? Color.alphaBlend(r.subtleFillColorTertiary, base)
        : _hover
        ? Color.alphaBlend(r.subtleFillColorSecondary, base)
        : base;
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = _down = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: interactive ? (_) => setState(() => _down = true) : null,
        onTapCancel: interactive ? () => setState(() => _down = false) : null,
        onTapUp: interactive ? (_) => setState(() => _down = false) : null,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.fast),
          curve: Motion.move,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(color: widget.highlight ?? r.cardStrokeColorDefault),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Rows that belong together in one card, separated by hairlines
/// (the Windows 11 Settings pattern), instead of a box per row.
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final r = FluentTheme.of(context).resources;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: r.cardBackgroundFillColorDefault,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: r.cardStrokeColorDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, child) in children.indexed) ...[if (i > 0) Container(height: 1, color: r.dividerStrokeColorDefault), child],
        ],
      ),
    );
  }
}

/// A row inside a [GroupCard]: hover tint, optional tap, and widgets that
/// only show while hovered (so secondary actions don't add noise).
class HoverRow extends StatefulWidget {
  const HoverRow({super.key, required this.builder, this.onPressed, this.padding = const EdgeInsets.fromLTRB(16, 10, 12, 10)});
  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onPressed;
  final EdgeInsets padding;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = FluentTheme.of(context).resources;
    return MouseRegion(
      cursor: widget.onPressed != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.fast),
          color: _hover ? r.subtleFillColorSecondary : r.subtleFillColorTransparent,
          padding: widget.padding,
          child: widget.builder(context, _hover),
        ),
      ),
    );
  }
}

/// Small colored dot that carries an item's status.
class StatusDot extends StatelessWidget {
  const StatusDot(this.status, {super.key});
  final ItemStatus status;

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(context, status);
    return Tooltip(
      message: s.label,
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.normal),
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: status == ItemStatus.unused || status == ItemStatus.unknown ? null : s.color,
          border: Border.all(color: s.color, width: 1.5),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// A quiet one-line notice (instead of a big banner).
class Callout extends StatelessWidget {
  const Callout({super.key, required this.icon, required this.text, this.color, this.action});
  final IconData icon;
  final String text;
  final Color? color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: color ?? theme.resources.textFillColorSecondary),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.typography.body)),
        if (action != null) ...[const SizedBox(width: 12), action!],
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.top = 24});
  final String text;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(text, style: FluentTheme.of(context).typography.bodyStrong)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Muted secondary text.
/// A small spinner with a word, for anything that's working right now.
class BusyLabel extends StatelessWidget {
  const BusyLabel(this.text, {super.key, this.muted = false});
  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 12, height: 12, child: ProgressRing(strokeWidth: 2)),
        const SizedBox(width: 8),
        Text(text, style: muted ? theme.typography.caption?.copyWith(color: theme.resources.textFillColorSecondary) : null),
      ],
    );
  }
}

class Muted extends StatelessWidget {
  const Muted(this.text, {super.key, this.maxLines, this.size});
  final String text;
  final int? maxLines;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Text(
      text,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: theme.typography.caption?.copyWith(color: theme.resources.textFillColorSecondary, fontSize: size),
    );
  }
}

/// Horizontal stacked bar that animates its segments to new proportions.
///
/// Segments are positioned slices in a Stack, so no combination of sizes,
/// resizes or mid-animation values can overflow. The bar sweeps in once.
class StorageBar extends StatelessWidget {
  const StorageBar({super.key, required this.segments, this.height = 10});

  /// (id, color, bytes) per segment; the id keeps a segment's animation stable.
  final List<(String, Color, int)> segments;
  final double height;

  @override
  Widget build(BuildContext context) {
    final total = segments.fold<int>(0, (s, e) => s + e.$3);
    final track = FluentTheme.of(context).resources.subtleFillColorSecondary;
    final move = Motion.of(context, Motion.slow);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Motion.of(context, Motion.count),
          curve: Motion.enter,
          builder: (context, reveal, child) => ClipRect(
            child: Align(alignment: Alignment.centerLeft, widthFactor: reveal, child: child),
          ),
          child: LayoutBuilder(
            builder: (context, c) {
              var x = 0.0;
              final slices = <Widget>[];
              for (final (i, (id, color, bytes)) in segments.indexed) {
                final w = total == 0 ? 0.0 : c.maxWidth * bytes / total;
                final gap = i == segments.length - 1 || w < 4 ? 0.0 : 2.0;
                slices.add(
                  AnimatedPositioned(
                    key: ValueKey(id),
                    duration: move,
                    curve: Motion.move,
                    left: x,
                    width: (w - gap).clamp(0, c.maxWidth),
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(color: color),
                  ),
                );
                x += w;
              }
              return ColoredBox(
                color: track,
                child: Stack(fit: StackFit.expand, children: slices),
              );
            },
          ),
        ),
      ),
    );
  }
}

String timeAgo(DateTime? t) {
  if (t == null || t.millisecondsSinceEpoch == 0) return 'Unknown';
  final d = DateTime.now().difference(t);
  if (d.inDays >= 365) {
    final y = (d.inDays / 365).floor();
    return '$y year${y == 1 ? '' : 's'} ago';
  }
  if (d.inDays >= 30) {
    final m = (d.inDays / 30).floor();
    return '$m month${m == 1 ? '' : 's'} ago';
  }
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  if (d.inHours >= 1) return '${d.inHours} hr ago';
  return 'Just now';
}
