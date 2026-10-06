/// In-app legal & trust documents.
///
/// STATUS: DRAFTS PREPARED FOR LEGAL REVIEW. They describe what the code
/// actually does (see docs/LEGAL.md for the source of each statement). They
/// have NOT been reviewed by a lawyer and must not be presented as compliant
/// or final. The operator must fill in the identity/contact placeholders and
/// have them reviewed before a public launch.
library;

/// Operator identity, supplied at build time so no real-looking placeholder
/// is ever shown as if it were real:
/// `--dart-define=AUTOMETA_OPERATOR="Example Ltd" --dart-define=AUTOMETA_CONTACT_EMAIL=privacy@example.com`
class LegalInfo {
  const LegalInfo._();
  static const String operator = String.fromEnvironment('AUTOMETA_OPERATOR');
  static const String contactEmail = String.fromEnvironment('AUTOMETA_CONTACT_EMAIL');
  static const String draftDate = '2026-10-05';
  static const String reviewBanner =
      'Draft prepared for legal review. Not yet reviewed by a lawyer; it may change before public launch.';

  static String get operatorName => operator.isEmpty ? '[operator name not set in this build]' : operator;
  static String get contact => contactEmail.isEmpty ? '[contact address not set in this build]' : contactEmail;
}

class LegalDoc {
  const LegalDoc(this.id, this.title, this.summary, this.sections);
  final String id;
  final String title;
  final String summary;
  final List<(String, String)> sections;
}

/// What a Cloud connection gives Autometa access to. Shown before connecting.
class IntegrationDisclosure {
  const IntegrationDisclosure({required this.access, required this.use, this.extra});
  final List<String> access;
  final String use;
  final String? extra;

  static const Map<String, IntegrationDisclosure> byIntegration = <String, IntegrationDisclosure>{
    'gmail': IntegrationDisclosure(
      access: <String>[
        'Read your email messages and their metadata (gmail.readonly), for the "new email" trigger',
        'Send email as you (gmail.send), for the "send email" action',
      ],
      use: 'Only your own Cloud automations use this access, and only when they run. Autometa does not read your '
          'mailbox for any other purpose, does not use it for advertising, does not sell it, and does not use it to '
          'train AI models. Email content is kept only as part of your run history.',
      extra: 'Autometa\'s use of information received from Google APIs will adhere to the Google API Services User '
          'Data Policy, including the Limited Use requirements. You can revoke access at any time in your Google '
          'Account (Security → Third-party access) or by deleting the connection.',
    ),
    'telegram': IntegrationDisclosure(
      access: <String>['Your bot token, to send messages from your bot to the chats you choose'],
      use: 'The token is stored encrypted on the Autometa Cloud server and used only by your Cloud automations.',
    ),
    'whatsapp': IntegrationDisclosure(
      access: <String>['Your WhatsApp Business phone number ID and access token (official Meta Cloud API)'],
      use: 'Used only to send the messages your automations define, through Meta\'s official API. Meta\'s '
          'WhatsApp Business terms and messaging policies apply to you as the sender.',
    ),
  };
}

const String _intro = 'This document is a draft prepared for legal review. It is written to match how the app works today.';

final List<LegalDoc> legalDocs = <LegalDoc>[
  LegalDoc('privacy', 'Privacy Policy', 'What data Autometa handles, where it lives and your choices.', <(String, String)>[
    ('Status', _intro),
    ('Who we are', 'Autometa is operated by ${LegalInfo.operatorName}. Contact: ${LegalInfo.contact}.'),
    ('On-device automations',
        'Automations set to "On this device", their history, contacts and settings are stored only on your phone. '
            'API keys you enter are kept in Android\'s encrypted storage. This data is not sent to Autometa servers. '
            'Uninstalling the app or clearing its data deletes it.'),
    ('Autometa Cloud account',
        'If you create a Cloud account, the server stores your email, a password hash, your time zone, your Cloud '
            'automations, run history (including the data each run processed, such as an email subject or a webhook payload), '
            'connections, notification records and device push tokens. Connection credentials are encrypted at rest. '
            'Session tokens are stored only as hashes.'),
    ('Personal WhatsApp',
        'For a personal WhatsApp account, Autometa only opens WhatsApp with a message filled in, and you tap Send. Autometa has no access '
            'to your chats and never sends from your personal account.'),
    ('Third-party services',
        'Some features send data to services you connect (Google/Gmail, Meta WhatsApp Business, Telegram, an AI '
            'provider you configure, Firebase Cloud Messaging for alerts). See "Third-party services".'),
    ('Google user data',
        'Autometa\'s use of information received from Google APIs will adhere to the Google API Services User Data '
            'Policy, including the Limited Use requirements. Gmail data is used only to run your automations, and it is not '
            'used for advertising, not sold, not used to train AI models and not read by people, except with your consent, for '
            'security, or where the law requires.'),
    ('Retention',
        'Cloud data is kept while your account exists. Deleting your account removes your workspace, automations, '
            'connections and history from the live database. Backups made by the operator may keep copies for a limited time.'),
    ('Your choices',
        'Export your Cloud data or delete your account in Settings → Autometa Cloud account → Your data. '
            'Turn off phone alerts in the same screen. Revoke a provider\'s access in that provider\'s settings.'),
    ('Children', 'Autometa is not directed to children under 13 (or the minimum age in your country).'),
    ('Changes', 'We will update this page and its date when practices change. Draft date: ${LegalInfo.draftDate}.'),
  ]),
  LegalDoc('terms', 'Terms of Service', 'The rules for using Autometa.', <(String, String)>[
    ('Status', _intro),
    ('The service',
        'Autometa lets you build automations that run on your phone or on Autometa Cloud. Features depend on your '
            'plan, your device and the services you connect.'),
    ('Your responsibilities',
        'You are responsible for your automations and the messages they send, for having permission to message the '
            'people you contact, and for following the terms of every service you connect (for example Meta\'s WhatsApp '
            'Business policies and Google\'s terms).'),
    ('No guarantee of delivery',
        'On-device schedules depend on Android, battery settings and the phone being on. Cloud runs depend on the '
            'server and third-party services. Do not rely on Autometa for safety-critical, medical or emergency tasks.'),
    ('Acceptable use', 'Your use must follow the Acceptable Use Policy.'),
    ('Accounts & termination',
        'You can delete your account at any time. We may suspend accounts that break these terms or the Acceptable '
            'Use Policy, or that put the service or others at risk.'),
    ('Paid plans', 'Prices and billing terms are shown at purchase and handled by the store or payment provider.'),
    ('Liability', '[To be completed with legal review: warranty disclaimer, limitation of liability, governing law.]'),
    ('Contact', '${LegalInfo.operatorName} · ${LegalInfo.contact}'),
  ]),
  LegalDoc('aup', 'Acceptable Use Policy', 'What you may not use Autometa for.', <(String, String)>[
    ('Status', _intro),
    ('Not allowed', '• Spam, bulk unsolicited messages, or messaging people who have not agreed to hear from you.\n'
        '• Harassment, threats, fraud, phishing or impersonation.\n'
        '• Breaking the terms of a connected service, including WhatsApp Business messaging and template policies.\n'
        '• Using unofficial clients, UI automation or scraping to control consumer messaging apps.\n'
        '• Attacking, overloading or probing Autometa or other systems (including through webhooks or HTTP steps).\n'
        '• Illegal content or activity.'),
    ('Limits', 'Plans have run and rate limits to protect the service. Automations that fail repeatedly are paused.'),
    ('Reporting', 'Report abuse to ${LegalInfo.contact}.'),
  ]),
  LegalDoc('third_party', 'Third-party services', 'Services Autometa can send data to, and when.', <(String, String)>[
    ('Status', _intro),
    ('Google (Gmail API)', 'Only if you connect Gmail to Cloud. Scopes: gmail.readonly and gmail.send. Limited Use applies.'),
    ('Meta (WhatsApp Business Platform)', 'Only if you set up WhatsApp Business. Messages are sent through Meta\'s official Cloud API.'),
    ('WhatsApp (personal)', 'The app only opens wa.me click-to-chat links. You send the message yourself.'),
    ('Telegram', 'Only if you connect a Telegram bot. Messages are sent through the Telegram Bot API.'),
    ('Firebase Cloud Messaging (Google)', 'Delivers Cloud alerts to your phone when enabled. It receives a device token and the alert text.'),
    ('AI provider', 'Only if you configure one. The prompt text of AI steps is sent to the provider you chose.'),
    ('Email delivery (Resend)', 'Password-reset emails, when the operator enables it.'),
    ('Google Play', 'Purchases and subscriptions, when used.'),
    ('HTTP / webhook steps', 'Automations you build can send data to any URL you enter. You choose the destination.'),
  ]),
  LegalDoc('security', 'Security', 'How Autometa protects your data, and how to report a problem.', <(String, String)>[
    ('Status', _intro),
    ('Measures', '• Connection credentials are encrypted at rest on the server. API keys on the phone are kept in Android\'s encrypted storage.\n'
        '• Session tokens are random and stored only as hashes. Changing your password signs out your other sessions.\n'
        '• Release builds only connect to Cloud servers over HTTPS.\n'
        '• Secrets are never written to logs or the health endpoint.\n'
        '• Test runs are simulated and perform no live actions.'),
    ('Limits', 'No system is perfectly secure. The service has not yet had an independent security audit.'),
    ('Report a vulnerability', 'Email ${LegalInfo.contact}. Please do not test against other people\'s accounts.'),
  ]),
];
