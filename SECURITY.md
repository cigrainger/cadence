# Security and privacy

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting](https://github.com/cigrainger/cadence/security/advisories/new) for this repository. Include the affected version, a minimal original fixture and steps to reproduce. Do not publish secrets or an exploit against another person's system in a public issue. If private reporting is unavailable, open an issue requesting a private contact without vulnerability details.

The latest public preview is the supported release. This is a small volunteer project: there is no guaranteed response time or claim of a professional security audit.

## Boundaries

- Native macOS app; ad hoc signed preview, **not notarised and not App Sandbox isolated**. It runs with the logged-in user's normal file permissions. It requests microphone access for local pitch analysis.
- Keys are stored in macOS Keychain. The default AI transport accepts only HTTPS POST requests to OpenRouter's chat-completions endpoint and refuses redirects. Provider responses are untrusted and validated before becoming editable models.
- AI is optional and uses the learner's own account. Requests require ZDR provider routing; this does not substitute for reading the provider's terms. Selected content is sent only for the requested operation.
- Score WebKit views load bundled code with nonpersistent storage, a restrictive content policy, exact entry-page navigation and main-frame message handling. EPUB content is extracted/sanitised; remote resources and active document scripts are not enabled.
- Archive, score and persistence parsers impose limits and validate structure. Oversized or corrupt saves are preserved and surface an error rather than silently replacing the original. These limits reduce risks; they do not prove that arbitrary hostile input is harmless.
- No app telemetry, advertising SDK, tracking pixel or website analytics. Help/source links open external websites when selected.

## Repository hygiene

Do not commit credentials, `.env` files, private scores/books, Application Support data, model request/response logs, personal recordings, crash dumps or build artifacts. Only named original PDF/EPUB fixtures are allowed by the repository check. Gitleaks runs before publication and in CI, with redacted reports. Dependency hashes/licenses are checked and an SBOM is generated for releases. OSV checks cover only resolvable package versions; an incomplete upstream bundle inventory is explicitly reported.

Secrets scanning, regression tests and advisory databases are complementary checks, not a certification. Rotate a leaked credential even if it has been removed from Git history.
