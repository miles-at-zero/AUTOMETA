import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../legal/legal_texts.dart';
import '../widgets/autometa_widgets.dart';

/// Legal & privacy centre. Every document is a draft prepared for legal
/// review, and the screen says so instead of implying compliance.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    return Scaffold(
      appBar: AppBar(title: const Text('Legal & privacy')),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          ResponsiveWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              const _ReviewBanner(),
              const SizedBox(height: AutometaSpacing.lg),
              Panel(
                padding: EdgeInsets.zero,
                child: Column(children: <Widget>[
                  for (final LegalDoc d in legalDocs)
                    ListTile(
                      title: Text(d.title),
                      subtitle: Text(d.summary),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => open(LegalDocScreen(doc: d)),
                    ),
                  ListTile(
                    title: const Text('Open-source licences'),
                    subtitle: const Text('Software Autometa is built with'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showLicensePage(context: context, applicationName: AppInfo.name, applicationVersion: AppInfo.version),
                  ),
                  ListTile(
                    title: const Text('Contact'),
                    subtitle: Text('${LegalInfo.operatorName}\n${LegalInfo.contact}'),
                    isThreeLine: true,
                  ),
                ]),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class LegalDocScreen extends StatelessWidget {
  const LegalDocScreen({required this.doc, super.key});
  final LegalDoc doc;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(doc.title)),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          ResponsiveWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              const _ReviewBanner(),
              const SizedBox(height: AutometaSpacing.lg),
              for (final (String h, String body) in doc.sections) ...<Widget>[
                Text(h, style: t.titleSmall),
                const SizedBox(height: 4),
                SelectableText(body, style: t.bodyMedium),
                const SizedBox(height: AutometaSpacing.lg),
              ],
              Text('Draft date ${LegalInfo.draftDate}', style: t.bodySmall),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ReviewBanner extends StatelessWidget {
  const _ReviewBanner();

  @override
  Widget build(BuildContext context) => Panel(
        borderColor: AutometaColors.warning,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Icon(Icons.gavel_outlined, color: AutometaColors.warning),
          const SizedBox(width: 10),
          Expanded(child: Text(LegalInfo.reviewBanner, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );
}
