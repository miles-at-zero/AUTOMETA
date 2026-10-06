import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/theme/design_tokens.dart';
import '../../data/repositories/recipient.dart';
import '../../services/settings/settings_service.dart';
import '../widgets/autometa_widgets.dart';

/// Recipient aliases. Numbers live here, never in workflow definitions.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<Recipient> _items = <Recipient>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<Recipient> all = await context.read<AppServices>().contacts.all();
    if (mounted) setState(() => _items = all);
  }

  Future<void> _edit([Recipient? existing]) async {
    final TextEditingController alias = TextEditingController(text: existing?.alias ?? '');
    final TextEditingController phone = TextEditingController(text: existing?.phoneE164 ?? '');
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: Text(existing == null ? 'Add contact' : 'Edit contact'),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          TextField(controller: alias, decoration: const InputDecoration(labelText: 'Name used in workflows (e.g. Dad)')),
          const SizedBox(height: 8),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'WhatsApp number with country code', hintText: '+234…'),
          ),
        ]),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || alias.text.trim().isEmpty || !mounted) return;
    await context.read<AppServices>().contacts.save(Recipient(
          id: existing?.id ?? 'contact-${DateTime.now().microsecondsSinceEpoch}',
          alias: alias.text.trim(),
          displayName: alias.text.trim(),
          phoneE164: phone.text.trim(),
        ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsService settings = context.watch<SettingsService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      floatingActionButton: FloatingActionButton(onPressed: _edit, child: const Icon(Icons.add)),
      body: ListView(padding: EdgeInsets.all(AutometaSpacing.page(context)), children: <Widget>[
        Panel(
          child: TextFormField(
            initialValue: settings.defaultRecipientName,
            decoration: const InputDecoration(labelText: 'Default recipient name'),
            onFieldSubmitted: settings.setDefaultRecipient,
          ),
        ),
        const SizedBox(height: AutometaSpacing.lg),
        for (final Recipient r in _items)
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(r.alias),
            subtitle: Text(r.hasNumber ? r.maskedNumber : 'No number — WhatsApp blocks will fail until set',
                style: TextStyle(color: r.hasNumber ? null : AutometaColors.warning)),
            onTap: () => _edit(r),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await context.read<AppServices>().contacts.delete(r.id);
                await _load();
              },
            ),
          ),
        if (_items.isEmpty) const Text('No contacts yet.'),
      ]),
    );
  }
}
