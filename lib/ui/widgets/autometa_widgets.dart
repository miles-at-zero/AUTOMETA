import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import '../../core/theme/autometa_theme.dart';
import '../../domain/models/execution_status.dart';
import '../../domain/models/step.dart';

/// Small uppercase section heading used across every screen.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {this.trailing, super.key});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(
          left: AutometaSpacing.xs,
          bottom: AutometaSpacing.sm,
          top: AutometaSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                text.toUpperCase(),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AutometaSemanticColors.of(context).textTertiary,
                      letterSpacing: 1.6,
                    ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

/// The AUTOMETA card: rounded, hairline border, restrained glow.
class Panel extends StatelessWidget {
  const Panel({
    required this.child,
    this.padding = const EdgeInsets.all(AutometaSpacing.lg),
    this.glow,
    this.borderColor,
    this.onTap,
    this.accentLeft = false,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? glow;
  final Color? borderColor;
  final VoidCallback? onTap;
  final bool accentLeft;

  @override
  Widget build(BuildContext context) {
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    final Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(AutometaSpacing.radiusLg),
        border: Border.all(color: borderColor ?? colors.border),
        boxShadow: glow == null
            ? null
            : AutometaShadows.card(glow!, opacity: 0.08),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AutometaSpacing.radiusLg),
        child: Stack(
          children: <Widget>[
            if (accentLeft)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: glow ?? AutometaColors.accent),
              ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AutometaSpacing.radiusLg),
        child: content,
      ),
    );
  }
}

/// Coloured status dot.
class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {this.size = 8, this.pulse = false, super.key});

  final Color color;
  final double size;
  final bool pulse;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: pulse ? 10 : 4),
          ],
        ),
      );
}

/// Pill used for statuses, capabilities and honest capability gaps.
class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    required this.color,
    this.icon,
    this.filled = false,
    super.key,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: filled ? color.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: filled ? 0.5 : 0.32)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
}

/// Colour for an execution status, used everywhere so the palette never drifts.
Color statusColor(ExecutionStatus status) => switch (status) {
      ExecutionStatus.success => AutometaColors.success,
      ExecutionStatus.failed => AutometaColors.danger,
      ExecutionStatus.running => AutometaColors.info,
      ExecutionStatus.pending => AutometaColors.neutral,
      ExecutionStatus.cancelled => AutometaColors.neutral,
      ExecutionStatus.skipped => AutometaColors.warning,
      ExecutionStatus.waitingApproval => AutometaColors.secondary,
    };

/// Icon for a block kind, used by the builder and the activity log.
IconData stepIcon(StepKind kind) => switch (kind) {
      StepKind.whatsapp => Icons.chat_bubble_outline,
      StepKind.notification => Icons.notifications_none,
      StepKind.ai => Icons.auto_awesome_outlined,
      StepKind.http => Icons.http_outlined,
      StepKind.webhook => Icons.webhook_outlined,
      StepKind.clipboard => Icons.content_paste_outlined,
      StepKind.openUrl => Icons.open_in_new,
      StepKind.condition => Icons.call_split,
      StepKind.delay => Icons.hourglass_bottom_outlined,
      StepKind.setVariable => Icons.data_object,
    };

/// Full-width primary action.
class PrimaryAction extends StatelessWidget {
  const PrimaryAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AutometaColors.accentDeep,
          foregroundColor: AutometaColors.accent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AutometaSpacing.radiusMd),
            side: BorderSide(color: AutometaColors.accent.withValues(alpha: 0.35)),
          ),
        ),
        child: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: AutometaColors.accent),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
                ],
              ),
      );
}

/// Empty-state placeholder.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AutometaSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(AutometaSpacing.lg),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AutometaColors.accent.withValues(alpha: 0.08),
                border: Border.all(color: AutometaColors.accent.withValues(alpha: 0.2)),
              ),
              child: Icon(icon, size: 28, color: AutometaColors.accent),
            ),
            const SizedBox(height: AutometaSpacing.lg),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: AutometaSpacing.sm),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: AutometaSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Label/value pair used on detail screens.
class LabeledValue extends StatelessWidget {
  const LabeledValue({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AutometaSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 108,
            child: Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.textTertiary),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyLarge),
          ),
        ],
      ),
    );
  }
}

/// The ↓ connector between builder blocks.
class FlowConnector extends StatelessWidget {
  const FlowConnector({this.label, super.key});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    return SizedBox(
      height: 34,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 26),
          Container(width: 2, color: colors.borderStrong),
          if (label != null) ...<Widget>[
            const SizedBox(width: AutometaSpacing.sm),
            Text(
              label!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.textTertiary),
            ),
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

/// Confirmation dialog. Returns true only on an explicit confirm.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: AutometaColors.danger.withValues(alpha: 0.18),
                  foregroundColor: AutometaColors.danger,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Shows a snackbar. Safe to call after an await because it re-resolves the
/// messenger from the passed context at call time.
void showToast(BuildContext context, String message, {Color? color}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 3),
      backgroundColor: color,
    ));
}

/// The AUTOMETA wordmark.
class BrandMark extends StatelessWidget {
  const BrandMark({this.size = 28, this.showWordmark = true, super.key});

  final double size;
  final bool showWordmark;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AutometaGlyph(size: size),
          if (showWordmark) ...<Widget>[
            const SizedBox(width: AutometaSpacing.sm),
            Text(
              'AUTOMETA',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    letterSpacing: 3.2,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ],
      );
}

/// The three-node A glyph: Trigger → Intelligence → Action, with the orbital
/// loop passing through the centre (spec §32).
///
/// Drawn in code so it is resolution independent and matches the launcher
/// icon exactly at every size, including the 24 px case.
class AutometaGlyph extends StatelessWidget {
  const AutometaGlyph({this.size = 28, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _GlyphPainter()),
      );
}

class _GlyphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final Offset apex = Offset(w * 0.5, w * 0.10);
    final Offset leftFoot = Offset(w * 0.14, w * 0.90);
    final Offset rightFoot = Offset(w * 0.86, w * 0.90);

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.075
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(
        colors: <Color>[AutometaColors.accent, AutometaColors.secondary],
      ).createShader(Offset.zero & size);

    final Path legs = Path()
      ..moveTo(leftFoot.dx, leftFoot.dy)
      ..lineTo(apex.dx, apex.dy)
      ..lineTo(rightFoot.dx, rightFoot.dy);
    canvas.drawPath(legs, stroke);

    // Crossbar = the intelligence node's orbit.
    final Paint orbit = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.045
      ..color = AutometaColors.secondary.withValues(alpha: 0.75);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.5, w * 0.62), width: w * 0.62, height: w * 0.20),
      orbit,
    );

    final Paint node = Paint()..color = AutometaColors.accent;
    for (final Offset point in <Offset>[apex, leftFoot, rightFoot]) {
      canvas.drawCircle(point, w * 0.075, node);
      canvas.drawCircle(
        point,
        w * 0.13,
        Paint()..color = AutometaColors.accent.withValues(alpha: 0.22),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter oldDelegate) => false;
}
