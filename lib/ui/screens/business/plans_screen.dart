import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../../business/business_api.dart';
import '../../../core/theme/design_tokens.dart';
import '../../widgets/autometa_widgets.dart';
import 'business_common.dart';

/// Plans, current subscription, purchase / restore. Purchases go through
/// Google Play and are verified by the server before anything unlocks; the
/// app never decides entitlements itself.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final Map<String, ProductDetails> _products = <String, ProductDetails>{};
  bool _storeAvailable = false;
  bool _busy = false;
  final GlobalKey<LoaderState<Json>> _key = GlobalKey<LoaderState<Json>>();

  @override
  void initState() {
    super.initState();
    _sub = _iap.purchaseStream.listen(_onPurchases, onError: (Object e) => toast(context, 'Store error: $e'));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<Json> _load() async {
    final Json b = await apiOf(context).get('/billing');
    try {
      _storeAvailable = await _iap.isAvailable();
      if (_storeAvailable) {
        final Set<String> ids = <String>{
          for (final MapEntry<String, dynamic> e in asMap(asMap(b['pricing'])['plans']).entries) str(asMap(e.value)['googlePlayProductId']),
        }..removeWhere((String e) => e.isEmpty);
        final ProductDetailsResponse r = await _iap.queryProductDetails(ids);
        for (final ProductDetails p in r.productDetails) {
          _products[p.id] = p;
        }
      }
    } catch (_) {
      _storeAvailable = false;
    }
    return b;
  }

  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    for (final PurchaseDetails p in list) {
      if (p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored) {
        try {
          if (!mounted) return;
          await apiOf(context).post('/billing/google/verify', <String, dynamic>{'purchaseToken': p.verificationData.serverVerificationData});
          if (mounted) {
            await sessionOf(context).refresh();
            toast(context, 'Plan updated');
          }
        } catch (e) {
          if (mounted) await showBusinessError(context, e);
        }
      } else if (p.status == PurchaseStatus.error) {
        if (mounted) toast(context, p.error?.message ?? 'Purchase failed');
      }
      if (p.pendingCompletePurchase) await _iap.completePurchase(p);
    }
    if (mounted) {
      setState(() => _busy = false);
      await _key.currentState?.reload();
    }
  }

  Future<void> _buy(String productId) async {
    final ProductDetails? p = _products[productId];
    if (p == null) {
      toast(context, 'This plan isn\'t available in Google Play on this device. Use "Pay by transfer" below.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: p));
    } catch (e) {
      setState(() => _busy = false);
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool owner = sessionOf(context).role == 'owner';
    return Scaffold(
      appBar: AppBar(title: const Text('Plans')),
      body: Loader<Json>(
        key: _key,
        load: _load,
        builder: (BuildContext context, Json b, _) {
          final Json sub = asMap(b['subscription']);
          final Json pricing = asMap(b['pricing']);
          final Json prices = asMap(pricing['plans']);
          final Json featureLabels = asMap(b['features']);
          final String current = str(sub['plan']);
          final Json usage = asMap(b['usage']);
          final Json setup = asMap(pricing['setupService']);
          return ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              Panel(
                glow: AutometaColors.secondary,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text('Current plan: ${current.isEmpty ? 'free' : current}'.toUpperCase(), style: Theme.of(context).textTheme.titleMedium),
                  if (str(sub['notice']).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(str(sub['notice']), style: const TextStyle(color: AutometaColors.warning))),
                  if (intOf(sub['periodEnd']) > 0) Text('${sub['status'] == 'canceled' ? 'Ends' : 'Renews'} ${DateTime.fromMillisecondsSinceEpoch(intOf(sub['periodEnd'])).toLocal().toString().substring(0, 10)}'),
                  const SizedBox(height: 8),
                  Text('Using ${intOf(usage['flows'])} workflows · ${intOf(usage['members'])} team · ${intOf(usage['businesses'])} business(es)', style: Theme.of(context).textTheme.bodySmall),
                  for (final MapEntry<String, dynamic> o in asMap(usage['overLimit']).entries)
                    Text('Over the ${o.key} limit (${intOf(asMap(o.value)['used'])}/${intOf(asMap(o.value)['limit'])}). Extra items are kept but paused.', style: const TextStyle(color: AutometaColors.warning)),
                ]),
              ),
              const SizedBox(height: 12),
              for (final Json plan in asList(b['plans'])) ...<Widget>[
                _PlanCard(
                  plan: plan,
                  price: asMap(prices[str(plan['id'])]),
                  store: _products[str(asMap(prices[str(plan['id'])])['googlePlayProductId'])],
                  featureLabels: featureLabels,
                  current: current == plan['id'],
                  busy: _busy,
                  onBuy: owner && plan['id'] != 'free' && current != plan['id'] ? () => _buy(str(asMap(prices[str(plan['id'])])['googlePlayProductId'])) : null,
                ),
                const SizedBox(height: 10),
              ],
              if (owner)
                OutlinedButton.icon(
                  onPressed: !_storeAvailable ? null : () async {
                    setState(() => _busy = true);
                    await _iap.restorePurchases();
                    if (mounted) setState(() => _busy = false);
                  },
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore purchases'),
                ),
              if (!owner) const Text('Only the account owner can change the plan.'),
              const SizedBox(height: 16),
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text('Pay by transfer or get it set up for you', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Prefer bank transfer, or want us to configure your menu, FAQs and workflows? '
                    'Professional setup: ${naira(setup['from'])}–${naira(setup['to'])}. ${str(setup['description'])} '
                    'After payment your plan is activated on your account.',
                  ),
                  if (str(setup['contact']).isNotEmpty) ...<Widget>[const SizedBox(height: 6), SelectableText('Contact: ${setup['contact']}')],
                ]),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.price, required this.store, required this.featureLabels, required this.current, required this.busy, this.onBuy});

  final Json plan;
  final Json price;
  final ProductDetails? store;
  final Json featureLabels;
  final bool current;
  final bool busy;
  final VoidCallback? onBuy;

  @override
  Widget build(BuildContext context) {
    final Json limits = asMap(plan['limits']);
    String lim(String k, String label) => limits[k] == null ? 'Unlimited $label' : '${intOf(limits[k])} $label';
    final String priceText = plan['id'] == 'free' ? 'Free' : store?.price ?? '${naira(price['monthly'])}/month';
    return Panel(
      borderColor: current ? AutometaColors.accent : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(str(plan['name']), style: Theme.of(context).textTheme.titleLarge)),
          Text(priceText, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AutometaColors.accent)),
        ]),
        if (str(plan['tagline']).isNotEmpty) Text(str(plan['tagline'])),
        const SizedBox(height: 8),
        Text('${lim('businesses', 'business numbers')} · ${lim('members', 'team members')} · ${lim('flows', 'workflows')}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
          for (final String f in asStrings(plan['features'])) StatusPill(label: str(featureLabels[f]).isEmpty ? f : str(featureLabels[f]), color: AutometaColors.neutral),
        ]),
        const SizedBox(height: 10),
        if (current) const StatusPill(label: 'Your plan', color: AutometaColors.accent, filled: true) else if (onBuy != null) PrimaryAction(label: 'Choose ${plan['name']}', onPressed: busy ? null : onBuy, busy: busy),
      ]),
    );
  }
}
