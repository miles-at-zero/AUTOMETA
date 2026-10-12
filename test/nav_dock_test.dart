// The floating capsule navigation dock: layout under pressure, selection,
// and the Guardian unread badge.
import 'package:autometa/core/theme/autometa_theme.dart';
import 'package:autometa/ui/widgets/floating_nav_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const List<NavDockDestination> destinations = <NavDockDestination>[
  NavDockDestination(icon: Icons.dashboard_outlined, selectedIcon: Icons.dashboard, label: 'Control Room'),
  NavDockDestination(icon: Icons.account_tree_outlined, selectedIcon: Icons.account_tree, label: 'Automations'),
  NavDockDestination(icon: Icons.history, selectedIcon: Icons.history, label: 'Activity'),
  NavDockDestination(icon: Icons.hub_outlined, selectedIcon: Icons.hub, label: 'Connections'),
];

Future<void> pumpDock(
  WidgetTester tester, {
  required int index,
  int unreadCount = 0,
  ValueChanged<int>? onSelect,
  VoidCallback? onOpenNotifications,
  double width = 360,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AutometaTheme.dark,
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        bottomNavigationBar: FloatingNavDock(
          index: index,
          onSelect: onSelect ?? (_) {},
          destinations: destinations,
          unreadCount: unreadCount,
          onOpenNotifications: onOpenNotifications,
        ),
        body: const SizedBox.expand(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  // ------------------------------------------------------------- layout
  group('layout under pressure', () {
    for (final double width in <double>[320, 360, 414, 1024]) {
      testWidgets('renders without overflow at ${width}dp', (WidgetTester tester) async {
        await pumpDock(tester, index: 0, width: width);
        expect(tester.takeException(), isNull, reason: 'no overflow at $width dp');
      });

      testWidgets('shows every destination label at ${width}dp', (WidgetTester tester) async {
        await pumpDock(tester, index: 0, width: width);
        for (int i = 0; i < destinations.length; i++) {
          expect(find.byKey(Key('dock.label.$i')), findsOneWidget);
        }
      });
    }

    testWidgets('survives the largest accessibility text scale', (WidgetTester tester) async {
      for (final double width in <double>[320, 360]) {
        await pumpDock(tester, index: 0, width: width, scale: 2.0);
        expect(tester.takeException(), isNull, reason: '2.0x text at $width dp');
      }
    });

    testWidgets('every destination meets the 48dp touch target height',
        (WidgetTester tester) async {
      await pumpDock(tester, index: 0, width: 320);
      for (int i = 0; i < destinations.length; i++) {
        final Finder item = find.byKey(Key('dock.item.$i'));
        expect(tester.getSize(item).height, greaterThanOrEqualTo(48),
            reason: 'destination $i must be tappable');
      }
    });
  });

  // ---------------------------------------------------------- selection
  group('selection', () {
    testWidgets('tapping a destination reports its index', (WidgetTester tester) async {
      final List<int> tapped = <int>[];
      await pumpDock(tester, index: 0, onSelect: tapped.add);

      await tester.tap(find.byKey(const Key('dock.item.2')));
      await tester.pumpAndSettle();

      expect(tapped, <int>[2]);
    });

    testWidgets('the dock is a single capsule and only marks the active slot',
        (WidgetTester tester) async {
      await pumpDock(tester, index: 1);
      final Finder dock = find.byKey(const Key('dock'));
      expect(dock, findsOneWidget);

      final Container capsule = tester.widget<Container>(dock);
      final BoxDecoration decoration = capsule.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(999));

      // Two AnimatedContainers per slot is the tint capsule; exactly one is
      // tinted for the selected index.
      final List<AnimatedContainer> capsules = tester
          .widgetList<AnimatedContainer>(find.descendant(
            of: find.byKey(const Key('dock')),
            matching: find.byType(AnimatedContainer),
          ))
          .toList();
      expect(capsules.length, destinations.length);
      final Iterable<AnimatedContainer> tinted = capsules.where((AnimatedContainer c) {
        final BoxDecoration d = c.decoration! as BoxDecoration;
        return (d.color ?? Colors.transparent) != Colors.transparent;
      });
      expect(tinted.length, 1);
    });

    testWidgets('every destination is reachable by assistive technology',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pumpDock(tester, index: 0, width: 360, onOpenNotifications: () {});
      for (int i = 0; i < destinations.length; i++) {
        final SemanticsNode node = tester.getSemantics(find.byKey(Key('dock.item.$i')));
        expect(node.hasAction(SemanticsAction.tap), isTrue,
            reason: 'destination $i must be tappable by a screen reader');
      }
      final SemanticsNode bell = tester.getSemantics(find.byKey(const Key('dock.notifications')).hitTestable());
      expect(bell.hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });

  // -------------------------------------------------------------- badge
  group('unread badge', () {
    testWidgets('no badge and a quiet bell when nothing is unread',
        (WidgetTester tester) async {
      await pumpDock(tester, index: 0, unreadCount: 0, onOpenNotifications: () {});
      expect(find.byKey(const Key('dock.badge')), findsNothing);
    });

    testWidgets('shows the unread count', (WidgetTester tester) async {
      await pumpDock(tester, index: 0, unreadCount: 3, onOpenNotifications: () {});
      expect(find.byKey(const Key('dock.badge')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('caps the count at 9+', (WidgetTester tester) async {
      await pumpDock(tester, index: 0, unreadCount: 42, onOpenNotifications: () {});
      expect(find.text('9+'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not overflow at 320dp with a badge', (WidgetTester tester) async {
      await pumpDock(tester, index: 0, unreadCount: 7, onOpenNotifications: () {}, width: 320);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('dock.badge')), findsOneWidget);
    });

    testWidgets('the bell opens the notification center', (WidgetTester tester) async {
      int opens = 0;
      await pumpDock(tester, index: 0, unreadCount: 1, onOpenNotifications: () => opens++);
      await tester.tap(find.byKey(const Key('dock.notifications')));
      await tester.pumpAndSettle();
      expect(opens, 1);
    });
  });
}
