# Legal & trust centre

**Status: DRAFTS PREPARED FOR LEGAL REVIEW.** Nothing here has been reviewed by a lawyer. Do not present these texts as compliant or final.

* In-app: Settings → About → Legal & privacy (`lib/ui/screens/legal_screen.dart`). Texts are in `lib/legal/legal_texts.dart`.
* Every screen shows the banner "Draft prepared for legal review".
* Documents:
  * Privacy Policy;
  * Terms of Service;
  * Acceptable Use Policy;
  * Third-party services;
  * Security;
  * Open-source licences (Flutter's generated licence page);
  * Contact.
* Operator identity is supplied at build time, so no fake company or address is ever shown:
  `--dart-define=AUTOMETA_OPERATOR="Example Ltd" --dart-define=AUTOMETA_CONTACT_EMAIL=privacy@example.com`.
  If these aren't set, the documents show "[… not set in this build]".
* Statements match the code:
  * on-device data stays on the phone;
  * connection secrets are encrypted at rest;
  * session tokens are stored hashed;
  * test runs are simulated;
  * export contains no secrets (server test);
  * account deletion cascades (server test);
  * personal WhatsApp only uses wa.me links.
* Integration disclosures: before connecting Gmail, Telegram or WhatsApp Business to Cloud, a dialog lists exactly what access is granted and how it is used. For Gmail, this includes the Google API Services User Data Policy / Limited Use statement.
* Your data, in Cloud account → Your data:
  * **Export** calls `GET /v1/me/export` and saves JSON to the app's external files folder, with an option to copy it.
  * **Delete account** calls `DELETE /v1/me`. It needs the password plus typing `DELETE`. A wrong password doesn't sign you out.

## Before public launch (USER / EXTERNAL)
1. Have a lawyer review and complete every document. The liability and governing-law sections of the Terms are deliberately left as placeholders.
2. Host the reviewed Privacy Policy and Terms at public URLs on your verified domain. Google OAuth verification and the Play Console require this.
3. Set the operator name and contact email at build time.
4. Fill in the Play Console Data safety form so that it matches the Privacy Policy.
