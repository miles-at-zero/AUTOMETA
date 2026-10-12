import 'package:flutter/material.dart';

import '../../core/theme/autometa_theme.dart';
import '../../core/theme/design_tokens.dart';

/// One destination in the floating dock.
@immutable
class NavDockDestination {
  const NavDockDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.semanticLabel,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Announced to screen readers; falls back to [label].
  final String? semanticLabel;
}

/// The AUTOMETA floating navigation dock.
///
/// A single capsule that floats above the content instead of a full-bleed
/// bottom bar: the destinations sit in a pill with a tinted capsule that
/// animates onto the active icon, and the Guardian Notification Center opens
/// from the bell at the end of the same capsule.
///
/// Built to survive the hard cases the product actually ships to: 320 dp
/// phones and 1.8x accessibility text. Every slot is an equal share of the
/// width, labels scale down instead of wrapping, and text scaling is capped
/// inside the dock only (content screens still honour it fully).
class FloatingNavDock extends StatelessWidget {
  const FloatingNavDock({
    required this.index,
    required this.onSelect,
    required this.destinations,
    this.unreadCount = 0,
    this.onOpenNotifications,
    super.key,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final List<NavDockDestination> destinations;

  /// Unread Guardian notifications; > 0 lights the bell and shows a badge.
  final int unreadCount;

  /// Omitted when the notification center isn't available (e.g. previews).
  final VoidCallback? onOpenNotifications;

  static const double _height = 66;

  @override
  Widget build(BuildContext context) {
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    final MediaQueryData mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(textScaler: mq.textScaler.clamp(maxScaleFactor: 1.15)),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(
          AutometaSpacing.lg,
          0,
          AutometaSpacing.lg,
          AutometaSpacing.md,
        ),
        child: Container(
          key: const Key('dock'),
          height: _height,
          decoration: BoxDecoration(
            color: colors.surfaceHigh,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: unreadCount > 0
                  ? AutometaColors.warning.withValues(alpha: 0.45)
                  : colors.borderStrong,
            ),
            // The dock is a floating surface lifted off the page, so a shadow
            // here is intentional (unlike the in-grid cards, where an
            // out-of-bounds shadow bled into the neighbouring card).
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.38),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Row(
              children: <Widget>[
                for (int i = 0; i < destinations.length; i++)
                  Expanded(child: _destination(context, i)),
                if (onOpenNotifications != null) ...<Widget>[
                  const _DockDivider(),
                  _bell(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _destination(BuildContext context, int i) {
    final NavDockDestination d = destinations[i];
    final bool selected = i == index;
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    final Color color = selected ? AutometaColors.accent : colors.textTertiary;
    return Semantics(
      button: true,
      selected: selected,
      label: d.semanticLabel ?? d.label,
      // excludeSemantics drops the InkWell's own semantics, so this node has
      // to declare the action itself or a screen reader sees a button that
      // cannot be activated.
      onTap: () => onSelect(i),
      excludeSemantics: true,
      child: InkWell(
        key: Key('dock.item.$i'),
        onTap: () => onSelect(i),
        child: SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                decoration: BoxDecoration(
                  color: selected
                      ? AutometaColors.accent.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Icon(selected ? d.selectedIcon : d.icon, size: 22, color: color),
              ),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    d.label,
                    maxLines: 1,
                    softWrap: false,
                    key: Key('dock.label.$i'),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bell(BuildContext context) {
    final bool hasUnread = unreadCount > 0;
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    final Color color = hasUnread ? AutometaColors.warning : colors.textTertiary;
    return Semantics(
      button: true,
      label: hasUnread
          ? 'Notifications, $unreadCount unread'
          : 'Notifications, none unread',
      onTap: onOpenNotifications,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('dock.notifications'),
        onTap: onOpenNotifications,
        child: SizedBox(
          width: 58,
          height: _height,
          child: Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Icon(
                  hasUnread ? Icons.notifications_active : Icons.notifications_none,
                  size: 22,
                  color: color,
                ),
                if (hasUnread)
                  Positioned(
                    right: -7,
                    top: -5,
                    child: UnreadBadge(key: const Key('dock.badge'), count: unreadCount),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DockDivider extends StatelessWidget {
  const _DockDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 19),
        child: VerticalDivider(
          width: 1,
          thickness: 1,
          color: AutometaSemanticColors.of(context).border,
        ),
      );
}

/// Unread count badge. Public because the Control Room header and the dock
/// both need the same treatment (and the same "9+" cap).
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: AutometaColors.danger,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AutometaColors.darkSurfaceHigh, width: 1.5),
        ),
        child: Center(
          child: Text(
            count > 9 ? '9+' : '$count',
            style: const TextStyle(
              fontSize: 10,
              height: 1.1,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      );
}
