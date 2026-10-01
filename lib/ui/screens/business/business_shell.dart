import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app_services.dart';
import '../../../business/business_api.dart';
import '../../../business/business_session.dart';
import '../../../core/theme/design_tokens.dart';
import '../../widgets/autometa_widgets.dart';
import 'business_common.dart';
import 'flows_screen.dart';
import 'inbox_screen.dart';
import 'insights_screen.dart';
import 'more_screen.dart';

/// Entry point for Business mode. Personal mode is untouched; this screen is
/// pushed on top of it and popping returns to Personal.
class BusinessGate extends StatefulWidget {
  const BusinessGate({super.key});

  @override
  State<BusinessGate> createState() => _BusinessGateState();
}

class _BusinessGateState extends State<BusinessGate> {
  late final BusinessSession _session = BusinessSession(context.read<AppServices>());

  @override
  void initState() {
    super.initState();
    _session.init();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();

  // Business screens live in a nested navigator *below* the session provider
  // so every pushed screen can reach it. System back pops inside first.
  @override
  Widget build(BuildContext context) => ChangeNotifierProvider<BusinessSession>.value(
        value: _session,
        child: NavigatorPopHandler(
          onPop: () => _nav.currentState?.maybePop(),
          child: Navigator(
            key: _nav,
            onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => Consumer<BusinessSession>(
                builder: (BuildContext context, BusinessSession s, _) {
                  if (!s.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
                  if (!s.signedIn) return const BusinessSignInScreen();
                  return const BusinessShell();
                },
              ),
            ),
          ),
        ),
      );
}

class BusinessShell extends StatefulWidget {
  const BusinessShell({super.key});

  @override
  State<BusinessShell> createState() => _BusinessShellState();
}

class _BusinessShellState extends State<BusinessShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final BusinessSession s = context.watch<BusinessSession>();
    final String bid = s.bid;
    final List<Widget> pages = <Widget>[
      InboxScreen(key: ValueKey<String>('inbox$bid')),
      FlowsScreen(key: ValueKey<String>('flows$bid')),
      InsightsScreen(key: ValueKey<String>('ins$bid')),
      const MoreScreen(),
    ];
    final String notice = str(s.subscription['notice']);
    return Scaffold(
      appBar: AppBar(
        title: Text(str(s.business['name']).isEmpty ? 'Business' : str(s.business['name']), overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Center(child: StatusPill(label: s.planName, color: s.planId == 'free' ? AutometaColors.neutral : AutometaColors.secondary)),
          ),
          IconButton(tooltip: 'Back to Personal', icon: const Icon(Icons.person_outline), onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (notice.isNotEmpty)
            MaterialBanner(
              content: Text(notice),
              leading: const Icon(Icons.info_outline, color: AutometaColors.warning),
              actions: <Widget>[TextButton(onPressed: () => setState(() => _index = 3), child: const Text('Plans'))],
            ),
          if (s.business['connected'] != true)
            MaterialBanner(
              content: const Text('Connect your WhatsApp Business number so automations can reply.'),
              leading: const Icon(Icons.link_off, color: AutometaColors.warning),
              actions: <Widget>[TextButton(onPressed: () => setState(() => _index = 3), child: const Text('Connect'))],
            ),
          Expanded(child: IndexedStack(index: _index, children: pages)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int i) => setState(() => _index = i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const <NavigationDestination>[
          NavigationDestination(icon: Icon(Icons.forum_outlined), selectedIcon: Icon(Icons.forum), label: 'Inbox'),
          NavigationDestination(icon: Icon(Icons.account_tree_outlined), selectedIcon: Icon(Icons.account_tree), label: 'Workflows'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Insights'),
          NavigationDestination(icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: 'More'),
        ],
      ),
    );
  }
}

class BusinessSignInScreen extends StatefulWidget {
  const BusinessSignInScreen({super.key});

  @override
  State<BusinessSignInScreen> createState() => _BusinessSignInScreenState();
}

class _BusinessSignInScreenState extends State<BusinessSignInScreen> {
  late final TextEditingController _url = TextEditingController(text: context.read<BusinessSession>().serverUrl);
  final TextEditingController _code = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _biz = TextEditingController();
  bool _haveCode = true;
  bool _busy = false;

  Future<void> _go() async {
    final BusinessSession s = context.read<BusinessSession>();
    if (_url.text.trim().isEmpty) return toast(context, 'Enter your AUTOMETA server address');
    setState(() => _busy = true);
    try {
      if (_haveCode) {
        await s.redeem(_url.text, _code.text);
      } else {
        await s.signUp(_url.text, _name.text, _biz.text);
      }
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Business mode'), leading: CloseButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop())),
        body: ListView(
          padding: const EdgeInsets.all(AutometaSpacing.lg),
          children: <Widget>[
            Text('Turn your WhatsApp conversations into an organised business workflow.', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Business mode uses the official WhatsApp Business Platform. Customers message your business number, and AUTOMETA replies, takes orders and captures leads. It hands chats to your team when needed.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            TextField(controller: _url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Server address', hintText: 'autometa.yourdomain.com', helperText: 'Provided with your setup, or your own server')),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: true, label: Text('I have a code')),
                ButtonSegment<bool>(value: false, label: Text('Start free')),
              ],
              selected: <bool>{_haveCode},
              onSelectionChanged: (Set<bool> v) => setState(() => _haveCode = v.first),
            ),
            const SizedBox(height: 16),
            if (_haveCode)
              TextField(controller: _code, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Setup or invite code', hintText: 'ABCD-EFGH-JKLM'))
            else ...<Widget>[
              TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Your name')),
              const SizedBox(height: 12),
              TextField(controller: _biz, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Business name')),
            ],
            const SizedBox(height: 24),
            PrimaryAction(label: _haveCode ? 'Continue' : 'Create free account', icon: Icons.arrow_forward, busy: _busy, onPressed: _busy ? null : _go),
          ],
        ),
      );
}
