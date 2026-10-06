# Conditions (V1)

Simple filters, not a programming language.

* Operators (both engines): equals, does not equal, contains, does not contain,
  plus starts with, greater/less than, is empty / is not empty. Comparisons ignore case.
* Up to 5 rules per condition block, combined with **All (AND)** or **Any (OR)**.
  Free: up to 3 rules per block. More needs Plus (`advancedConditions`).
* Left side: a workflow variable, e.g. `{{payload.status}}`, `{{email.subject}}`,
  `{{steps.s1.messageId}}`, `{{weekday}}`.
* Validation before activation (server `validate.js`):
  - unknown variable root, e.g. `{{emial.subject}}` → "Unknown variable" with the list of valid ones
  - `steps.<id>` that doesn't run earlier → rejected
  - unsupported operator or match mode → rejected (never silently coerced)
  - empty condition (no rules / no field) → rejected; the app validator also blocks empty conditions
* Results: each run records `✓/✕ rule (was "actual value")` joined by AND/OR,
  shown in the test result, the execution log and the Cloud run screen. A field
  that is missing at runtime shows "(field not available in this run)".
* Cloud semantics: "continue only if it passes". ELSE branches are on-device
  only (**ELSE in Cloud: DEFERRED FROM V1**). The app blocks Cloud activation
  when an ELSE branch exists.
