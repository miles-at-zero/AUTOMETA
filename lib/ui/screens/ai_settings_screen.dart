import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/theme/design_tokens.dart';
import '../../services/ai/ai_provider.dart';
import '../../services/ai/ai_service.dart';
import '../widgets/autometa_widgets.dart';

/// AI Provider / API Key / Model / Temperature (spec §29).
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late AiSettings _s;
  final TextEditingController _key = TextEditingController();
  late final TextEditingController _model;
  late final TextEditingController _base;
  AiAvailability? _check;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _s = context.read<AppServices>().ai.settings;
    _model = TextEditingController(text: _s.model);
    _base = TextEditingController(text: _s.baseUrl);
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _base.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final AppServices services = context.read<AppServices>();
    setState(() => _busy = true);
    if (_key.text.trim().isNotEmpty) await services.ai.saveApiKey(_key.text);
    _key.clear();
    await services.saveAiSettings(_s.copyWith(model: _model.text.trim(), baseUrl: _base.text.trim()));
    final AiAvailability a = await services.ai.check();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _check = a;
      _s = services.ai.settings;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AiProvider? provider = context.read<AppServices>().ai.registry.byId(_s.providerId);
    return Scaffold(
      appBar: AppBar(title: const Text('AI Provider')),
      body: ListView(padding: EdgeInsets.all(AutometaSpacing.page(context)), children: <Widget>[
        DropdownButtonFormField<AiProviderId>(
          value: _s.providerId,
          decoration: const InputDecoration(labelText: 'Provider'),
          items: <DropdownMenuItem<AiProviderId>>[
            for (final AiProviderId p in AiProviderId.values) DropdownMenuItem<AiProviderId>(value: p, child: Text(p.label)),
          ],
          onChanged: (AiProviderId? p) => setState(() => _s = _s.copyWith(providerId: p)),
        ),
        const SizedBox(height: AutometaSpacing.md),
        if (_s.providerId == AiProviderId.localTemplates)
          const Text('On-device templates are deterministic text rules, not a language model. They work '
              'offline with no key; output is labelled LOCAL TEMPLATES in the activity log.')
        else ...<Widget>[
          TextField(
            controller: _key,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'API key',
              helperText: _s.apiKeyStored ? 'A key is stored securely. Enter a new one to replace it.' : 'Stored in Android secure storage, never logged.',
            ),
          ),
          const SizedBox(height: AutometaSpacing.md),
          TextField(
            controller: _model,
            decoration: InputDecoration(labelText: 'Model', helperText: 'e.g. ${provider?.suggestedModels.take(3).join(', ')}'),
          ),
          if (_s.providerId == AiProviderId.openAiCompatible) ...<Widget>[
            const SizedBox(height: AutometaSpacing.md),
            TextField(controller: _base, decoration: const InputDecoration(labelText: 'Base URL', helperText: 'Any OpenAI-compatible endpoint')),
          ],
          const SizedBox(height: AutometaSpacing.md),
          Text('Temperature: ${_s.temperature.toStringAsFixed(1)}'),
          Slider(value: _s.temperature, min: 0, max: 1.5, divisions: 15, onChanged: (double v) => setState(() => _s = _s.copyWith(temperature: v))),
          if (_s.apiKeyStored)
            TextButton(
              onPressed: () async {
                await context.read<AppServices>().ai.clearApiKey();
                setState(() => _s = _s.copyWith(apiKeyStored: false));
              },
              child: const Text('Remove stored key'),
            ),
        ],
        const SizedBox(height: AutometaSpacing.xl),
        PrimaryAction(label: 'Save & verify', busy: _busy, onPressed: _save),
        if (_check != null) ...<Widget>[
          const SizedBox(height: AutometaSpacing.md),
          StatusPill(
            label: _check!.available ? 'Connected · ${_check!.label}' : _check!.label,
            color: _check!.available ? AutometaColors.success : AutometaColors.danger,
            filled: true,
          ),
          if (_check!.detail.isNotEmpty) Text(_check!.detail, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: AutometaSpacing.lg),
        Text('Stored key: ${_s.apiKeyStored ? 'yes (hidden)' : 'none'}',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
