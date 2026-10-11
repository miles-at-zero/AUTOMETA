import 'package:autometa/core/theme/autometa_theme.dart';
import 'package:autometa/core/theme/design_tokens.dart';
import 'package:autometa/ui/widgets/autometa_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpAt(WidgetTester tester, {required double width, double scale = 1}) async {
    tester.view.physicalSize = Size(width * 3, 1800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AutometaTheme.dark,
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 1800), textScaler: TextScaler.linear(scale)),
        child: const Scaffold(body: _SelectableCards()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('selection is clipped to one card and does not move adjacent cards', (WidgetTester tester) async {
    for (final double width in <double>[320, 360, 1024]) {
      await pumpAt(tester, width: width);
      final Rect firstBefore = tester.getRect(find.byKey(const Key('panel.first')));
      final Rect secondBefore = tester.getRect(find.byKey(const Key('panel.second')));
      final _SelectableCardsState state = tester.state<_SelectableCardsState>(find.byType(_SelectableCards));
      final int firstCountBefore = state.firstTaps;
      final int secondCountBefore = state.secondTaps;

      await tester.tapAt(Offset(firstBefore.left + 20, firstBefore.top + 20));
      await tester.pumpAndSettle();

      expect(state.firstTaps, firstCountBefore + 1);
      expect(state.secondTaps, secondCountBefore);
      expect(tester.getRect(find.byKey(const Key('panel.first'))), firstBefore, reason: 'selected state must not shift layout');
      expect(tester.getRect(find.byKey(const Key('panel.second'))), secondBefore, reason: 'neighbor must not move');
      expect(tester.takeException(), isNull, reason: 'no overflow at $width dp');
    }
  });

  testWidgets('large accessibility text wraps inside cards at narrow widths', (WidgetTester tester) async {
    for (final double width in <double>[320, 360]) {
      await pumpAt(tester, width: width, scale: 1.8);
      expect(tester.takeException(), isNull, reason: 'large text at $width dp');
    }
  });

  testWidgets('a nested action does not also activate its parent card', (WidgetTester tester) async {
    await pumpAt(tester, width: 360);
    await tester.tap(find.byKey(const Key('panel.innerAction')));
    await tester.pumpAndSettle();

    final _SelectableCardsState state = tester.state<_SelectableCardsState>(find.byType(_SelectableCards));
    expect(state.innerTaps, 1);
    expect(state.firstTaps, 0);
    expect(state.secondTaps, 0);
  });

  testWidgets('interactive Panel uses a shaped, clipped Material boundary without external decoration', (WidgetTester tester) async {
    await pumpAt(tester, width: 320);
    final Finder panel = find.byKey(const Key('panel.third'));
    final Finder title = find.byKey(const Key('panel.third.title'));
    final Material material = tester.widget<Material>(find.ancestor(of: title, matching: find.byType(Material)).first);
    expect(material.clipBehavior, Clip.antiAlias);
    expect(material.shape, isA<RoundedRectangleBorder>());
    expect(material.elevation, 0);
    final InkWell inkWell = tester.widget<InkWell>(find.ancestor(of: title, matching: find.byType(InkWell)).first);
    expect(inkWell.customBorder, isA<RoundedRectangleBorder>());
    expect(find.descendant(of: panel, matching: find.byType(DecoratedBox)), findsNothing,
        reason: 'Panel selection must not paint an out-of-bounds BoxShadow');
  });
}

class _SelectableCards extends StatefulWidget {
  const _SelectableCards();

  @override
  State<_SelectableCards> createState() => _SelectableCardsState();
}

class _SelectableCardsState extends State<_SelectableCards> {
  bool _firstSelected = false;
  int firstTaps = 0;
  int secondTaps = 0;
  int innerTaps = 0;

  Widget _card({
    required String id,
    required String title,
    required VoidCallback onTap,
    bool selected = false,
    bool highlighted = false,
    Widget? trailing,
  }) =>
      Panel(
        key: Key('panel.$id'),
        onTap: onTap,
        glow: selected || highlighted ? AutometaColors.accent : null,
        borderColor: selected || highlighted ? AutometaColors.accent : null,
        padding: const EdgeInsets.all(AutometaSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, key: Key('panel.$id.title'), style: const TextStyle(fontSize: 18)),
            const Text('This selectable card has enough text to exercise wrap and hit-test boundaries.'),
            if (trailing != null) Align(alignment: Alignment.centerLeft, child: trailing),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(AutometaSpacing.md),
        children: <Widget>[
          _card(
            id: 'first',
            title: 'First card',
            selected: _firstSelected,
            onTap: () => setState(() {
              firstTaps++;
              _firstSelected = !_firstSelected;
            }),
            trailing: OutlinedButton(
              key: const Key('panel.innerAction'),
              onPressed: () => setState(() => innerTaps++),
              child: const Text('Card action'),
            ),
          ),
          const SizedBox(height: AutometaSpacing.xs),
          _card(id: 'second', title: 'Second card', onTap: () => setState(() => secondTaps++)),
          const SizedBox(height: AutometaSpacing.xs),
          _card(id: 'third', title: 'Third card', highlighted: true, onTap: () {}),
        ],
      );
}
