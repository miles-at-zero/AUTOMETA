# Autometa Project Handoff

## Session Information
- **Working Branch**: `arena/e7b8cc09-autometa`
- **Base Commit**: `823c58b9de0bb90c894ccbc19a669a3f1600f8ad` (`main`)
- **Reconciled Commit**: `2b3d06235071ed7c28e587de0d33aa09c63420c2` (`arena/8b66c2cf-autometa`)

## Component Status
1. **Server (`server/`)**:
   - Node: Node 22.x compatible (`node:sqlite`).
   - Test suite: 56 passing unit tests covering cloud API, engine, scheduler, guardian health checks, and webhooks.
   - Meta webhook signature checking verified in `server/src/crypto.js` and `server/test/api.test.js`.

2. **Mobile Application (`lib/`)**:
   - Flutter SDK: Stable channel compatible.
   - Cloud + On-Device execution modes supported.
   - Password recovery and login UI hardened.
   - Accessibility and Panel widget boundaries tested.

3. **Release & Build**:
   - Release flavor: `standard`.
   - CI workflow defined in `.github/workflows/flutter.yml`.
   - Artifact: `autometa.apk` and `autometa.apk.sha256` generated via GitHub Actions workflow and attached to releases.
   - Release notes and commit comment include the SHA-256 checksum of the built APK.
