import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../state/settings.dart';

/// Fluent 2 motion tokens.
class Motion {
  /// Fluent "decelerate": things entering the screen.
  static const enter = Cubic(0.1, 0.9, 0.2, 1.0);

  /// Fluent "point to point": things moving or resizing on screen.
  static const move = Cubic(0.55, 0.55, 0.0, 1.0);

  /// Fluent "accelerate": things leaving the screen.
  static const exit = Cubic(0.7, 0.0, 1.0, 0.5);

  static const fast = Duration(milliseconds: 167);
  static const normal = Duration(milliseconds: 250);
  static const slow = Duration(milliseconds: 333);
  static const count = Duration(milliseconds: 700);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true || Provider.of<Settings>(context, listen: false).reduceMotion;

  /// [d], or zero when the user asked for less motion.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;
}

/// Fades and slides a child in the first time it's built.
///
/// [index] staggers siblings in a list; the stagger is capped so long lists
/// never make you wait.
class Appear extends StatefulWidget {
  const Appear({super.key, required this.child, this.index = 0, this.offset = const Offset(0, 12), this.onceKey});

  final Widget child;
  final int index;
  final Offset offset;

  /// When set, the animation plays only the first time this key is seen.
  final String? onceKey;

  static final _seen = <String>{};

  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    final skip = widget.onceKey != null && !Appear._seen.add(widget.onceKey!);
    _c = AnimationController(vsync: this, duration: Motion.slow, value: skip ? 1 : 0);
    _t = CurvedAnimation(parent: _c, curve: Motion.enter);
    if (!skip) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (Motion.reduced(context)) {
          _c.value = 1;
          return;
        }
        final delay = Duration(milliseconds: 28 * widget.index.clamp(0, 10));
        Future.delayed(delay, () {
          if (mounted) _c.forward();
        });
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(offset: widget.offset * (1 - _t.value), child: child),
      ),
      child: widget.child,
    );
  }
}

String formatBytes(num bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final d = i <= 1 ? 0 : (v >= 100 ? 0 : decimals);
  return '${v.toStringAsFixed(d)} ${units[i]}';
}

/// A byte count that rolls smoothly to its new value.
class AnimatedBytes extends StatelessWidget {
  const AnimatedBytes(this.bytes, {super.key, this.style, this.pending = false});

  final int bytes;
  final TextStyle? style;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: bytes.toDouble()),
      duration: Motion.of(context, Motion.count),
      curve: Motion.enter,
      builder: (context, v, _) => Text(formatBytes(v), style: style, maxLines: 1),
    );
  }
}

/// Cross-fades and resizes between children when [child]'s key changes.
class SmoothSwitcher extends StatelessWidget {
  const SmoothSwitcher({super.key, required this.child, this.alignment = Alignment.topLeft});

  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final d = Motion.of(context, Motion.normal);
    return AnimatedSize(
      duration: d,
      curve: Motion.move,
      alignment: alignment,
      child: AnimatedSwitcher(
        duration: d,
        switchInCurve: Motion.enter,
        switchOutCurve: Motion.exit,
        layoutBuilder: (current, previous) => Stack(alignment: alignment, children: [...previous, if (current != null) current]),
        child: child,
      ),
    );
  }
}
