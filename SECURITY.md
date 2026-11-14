# Security

## Threat Model

Codex Vitals is a local-only macOS menu bar and Windows system tray utility. Its main sensitive assets are the user's Codex/OpenAI auth data and saved Claude Code and Gemini/Antigravity OAuth credentials.

Codex Vitals assumes:

- The signed-in macOS or Windows user account is trusted.
- Other local users and processes should not be able to read Codex Vitals token files.
- Network responses from unofficial ChatGPT/Codex endpoints may fail or change shape.
- Users only add and switch accounts/workspaces they own or are authorized to use.

## Local Storage

On macOS, Codex Vitals stores token-containing files under `~/Library/Application Support/CodexVitals/` with owner-only permissions. On Windows, app data is stored under `%APPDATA%\CodexVitals` inside the current user's profile. The app writes the active `.codex/auth.json` only after an explicit manual switch action.

Codex Vitals does not intentionally log access tokens, refresh tokens, ID tokens, bearer headers, OAuth response bodies, or full auth JSON.

## Claude Integration

On macOS, saved Claude credentials are stored in the app-specific Keychain service `com.ramterstudio.CodexVitals.Claude`. `claude-accounts.json` contains only account identity metadata, aliases, ordering, workspace labels, visibility, available plan metadata, and optional user-entered renewal dates; it does not contain access or refresh tokens. Hiding the active Claude profile from Codex Vitals does not sign it out of Claude Code. A previous credential generation is retained only in the same app-specific Keychain service to recover from an interrupted token update.

Interactive add and reconnect actions invoke the installed Claude Code executable with the fixed argument sequence `auth login --claudeai` and an optional email hint. The app does not invoke a shell and does not pass credentials through command arguments or environment variables. Temporary command output is owner-only and deleted when the login process exits.

A manual Claude switch snapshots the current state in memory, mirrors the outgoing account into the app Keychain, creates a short-lived Keychain safety item, composes the target credential with an allowlist of current machine-wide shared fields, updates Claude Code's active Keychain item, and replaces only `oauthAccount` in `~/.claude.json`. The app verifies both destinations. Any failure restores the original active credential and exact original config bytes; the next launch also detects and repairs an interrupted switch before reading usage. If `~/.claude/.credentials.json` already exists, it is rewritten for Claude Code hot reload; Codex Vitals never creates that plaintext file.

## Experimental Gemini Integration

Saved Gemini consumer credentials use the app-specific Keychain service `app.codexvitals.menubar.Gemini`. The active Antigravity credential uses service `gemini`, account `antigravity`. `gemini-accounts.json` contains email identities, aliases, ordering, visibility, workspace labels, plan metadata, and optional renewal dates, but no tokens. Metadata and usage snapshots still contain personal information and must not be published.

Add and Reconnect invoke only the installed CLI's fixed `agy acp --login` flow, without a shell or credential arguments. Usage refresh calls Google directly and does not launch a model or use `agy -p`. Expiring Google access tokens may be refreshed; OAuth client metadata is resolved from the installed CLI, not embedded in the repository. Tokens are not written to metadata, snapshots, logs, or screenshots.

Manual switching verifies the selected saved identity, preserves the outgoing credential, changes only the native Antigravity Keychain item, and verifies the result or attempts rollback. Running `agy` or Antigravity sessions block add, reconnect, and switch operations. Unlike the Claude interrupted-switch recovery mechanism, Gemini rollback is in-process only; an app or machine crash during a switch is not transactionally recovered on the next launch. No account rotation is automated. Hiding the active profile does not sign out of Antigravity.

Google's [Antigravity FAQ](https://antigravity.google/docs/faq) restricts third-party access and consumer-plan wrappers/account rotation, and warns of account suspension or termination. This experimental integration is not officially supported by Google. Native quota reads or explicit manual switching do not establish that an integration complies with provider terms.

## Network

Codex Vitals calls best-effort ChatGPT/Codex, Anthropic OAuth, and Google Antigravity usage endpoints directly from the local app. Expiring inactive Claude accounts may use Anthropic's OAuth token endpoint; Gemini accounts may use Google's OAuth token endpoint. Credentials are sent only to the corresponding provider for authentication and quota access, not to RamterStudio or an analytics service. The app does not sync tokens or run external automation hooks.

The temporary OAuth callback listener binds to localhost during login capture and closes after success, cancellation, timeout, or app termination.

## Reporting

For now, report security issues privately to the repository owner. Do not include live tokens or full auth files in bug reports.
