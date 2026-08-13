# Changelog

All notable changes to Codex Vitals will be documented here.

## 1.3.2 - 2026-08-13

- Fixed account switching when the OpenAI usage response contains a blank account ID.
- Preserved captured account UUIDs instead of treating internal profile keys as account identities.

## 1.3.1 - 2026-07-15

- Reworked the header into a connected glass control group that matches the RamterStudio menu bar app family.
- Unified the account list into one translucent panel with consistent corner radii, borders, and separators.
- Refined active-account and hover states while reducing plan and workspace badge saturation.
- Improved compact-row typography without increasing the popover width or reducing visible account details.

## 1.3.0 - 2026-07-13

- Added signed in-app updates with manual checks, 24-hour background checks, and optional automatic installation through Sparkle.
- Restored the current app version and update controls in Settings.
- Added confirmation before removing a saved account and exposed removal in the row context menu.
- Clarified toolbar grouping and settings navigation.
- Simplified Launch at Login status messaging so only actionable states are shown.
- Improved quota-window detection when OpenAI temporarily reports only a weekly limit.
- Refined account-row contrast and preserved full-size percentage text at 100%.

## 1.2.2 - 2026-07-13

- Added support for the Codex experience integrated into `ChatGPT.app` while preserving compatibility with the legacy `Codex.app`.

## 1.2.1 - 2026-07-03

- Fixed the menu bar popover toggle so clicking the status bar icon again closes the popover instead of closing and immediately reopening it.

## 1.2 - 2026-07-02

- Added an Auto Refresh setting with Off, 5 min, 10 min, 15 min, and 30 min options.
- Changed the default automatic usage refresh interval to 10 minutes.
- Cached account metadata for 6 hours during automatic refreshes while keeping manual refresh fully fresh.
- Limited concurrent usage and metadata API requests to 4 at a time to reduce network spikes.
- Reduced the passive auth mirror fallback poll from 3 seconds to 30 seconds while keeping file-event syncing active.

## 1.1 - 2026-06-24

- Rebranded the app as Codex Vitals.
- Added a pulse/gauge app icon and Vitals-oriented menu bar symbol.
- Added local display aliases for saved accounts.
- Added plan badges next to account aliases.
- Added a visible reconnect action for accounts that need authentication again.
- Added a sanitized product screenshot to the GitHub README and product website.
- Added an in-popover settings panel for Launch at Login.
- Moved settings and quit controls into the top toolbar and simplified the footer.
- Added manual account reordering from each account row context menu.
- Moved refresh completion feedback into the toolbar refresh button.
- Consolidated view mode and workspace grouping into one toolbar menu.
- Added a compact toolbar search button with a short expandable search field.
- Renamed quota labels from Session/Weekly and S/W to Codex's 5h/1w windows.
- Added local display names for workspace groups, reflected in group headers, workspace chips, and search.
- Refined account rows with capsule quota meters and a subtle active-account rail.
- Added a Codex Vitals brand lockup to the top-left toolbar area.
- Reduced the popover width for a tighter menu bar footprint.
- Removed focused/complete mode switching and kept the full account detail layout as the only view.
- Tightened the full-detail row layout, added full-email tooltips, and refined plan and reset-time badges.
- Added RamterStudio settings links for the studio website and feedback.
- Replaced the settings logo with a cleaner adaptive RamterStudio wordmark.
- Centered the settings panel and tightened its outer spacing.

## 1.0.9-beta.6 - 2026-06-03

- Made account switching terminate Codex.app helpers, Codex app-server, Codex exec, and node_repl processes before replacing live auth.
- Backed up the active `~/.codex/auth.json` before each switch so the previous live auth can be recovered.
- Revalidated the destination profile identity immediately before copying it into live Codex auth.
- Allowed the mirror to accept a newly issued login token even when old local metadata has a newer `last_refresh` timestamp.
- Strengthened tests that guard against refresh-token grant paths and background token refresh services.

## 1.0.9-beta.3 - 2026-05-31

- Closed the remaining account-switch race by terminating default `~/.codex` Codex app-server and node_repl auth consumers before replacing live auth.
- Treated Codex auth consumers without an explicit `CODEX_HOME` as default `~/.codex` consumers, matching Codex's own fallback behavior.
- Added guard coverage so future switches keep closing residual auth consumers, wait for SQLite locks, and avoid reintroducing refresh-token grants.

## 1.0.9-beta.2 - 2026-05-30

- Fixed `Use in Codex` hanging forever after Codex closed when the residual-process scan produced more output than its pipe buffer.
- Captured subprocess output through private temporary files and added a 10-second timeout so account switching returns an error instead of deadlocking.

## 1.0.9-beta.1 - 2026-05-30

- Hardened `Use in Codex` so Vitals stops Codex/app-server auth consumers before replacing the active auth file.
- Replaced remove-then-write auth updates with atomic replacements so `auth.json` does not temporarily disappear during switches or mirrors.
- Mirrored fresh Codex auth into every captured duplicate for the same identity instead of skipping ambiguous duplicate profiles.
- Avoided creating stale `accounts.json` entries when a duplicate captured profile has an old source key.
- Detected the active Codex account by matching token values instead of comparing whole JSON files, which can differ only by local metadata.

## 1.0.8 - 2026-05-29

- Removed every `grant_type=refresh_token` path from Vitals; the app now never spends refresh tokens.
- Kept only explicit login code exchange (`grant_type=authorization_code`) for adding or re-logging accounts.
- Added a production-source guard test so refresh-token grants cannot be reintroduced silently.
- Added a local read-only auth watcher script for diagnosing Codex auth rotations without logging raw tokens.
- Left token freshness to Codex itself, with Vitals passively mirroring `~/.codex/auth.json` after Codex rotates it.

## 1.0.7 - 2026-05-29

- Added a Codex auth mirror that keeps captured profiles fresh when `~/.codex/auth.json` changes after Codex or ChatGPT rotates tokens.
- Synced the live Codex auth back into its matching captured profile before switching accounts so rotated refresh tokens are not lost.
- Added just-in-time account switching refresh. Superseded by 1.0.8 because Vitals should never spend refresh tokens.
- Restarted Codex/app-server after account switches so the running session does not keep an old token in memory.
- Skipped token mirroring when no saved profile matches the live identity or when multiple profiles match ambiguously.

## 1.0.6 - 2026-05-27

- Fixed targeted re-login getting stuck after the ChatGPT consent screen by making the local OAuth callback server read and respond to the browser callback immediately.
- Kept usage refresh out of the login callback path so account capture can finish before balance checks run in the background.

## 1.0.5 - 2026-05-27

- Disabled background OAuth token refresh during usage updates so Codex Vitals does not rotate refresh tokens while Codex sessions are active.
- Kept expired accounts visible with their re-login state instead of trying to repair them silently.
- Added an OpenAI `login_hint` for targeted re-login flows so the selected account email can be prefilled by the auth page.

## 1.0.4 - 2026-05-22

- Added automatic access-token refresh when a Codex usage request returns `401`.
- Persisted refreshed tokens back to the local account store and captured Codex profiles.
- Retried usage fetches with the refreshed access token before requiring manual re-login.
- Showed `Refresh failed - re-login required` when refresh tokens are missing, reused, rejected, or still produce a rejected access token.
- Distinguished invalidated and revoked tokens from expired tokens so the app does not burn refresh tokens on unrecoverable auth states.

## 1.0.3 - 2026-05-21

- Added collapsible waiting-for-reset sections, including a dedicated collapsed-by-default free-plan group.
- Added clearer free-plan reset timing when session quota is depleted but weekly quota remains.
- Kept the selected compact/expanded information mode across popover opens.
- Improved exhausted-account ordering so paid accounts surface before free-plan reset waiters, then by soonest reset.
- Preserved re-login controls for free-plan waiting rows and added coverage for the new reset-state behavior.

## 1.0.2 - 2026-05-14

- Fixed an account list bug where accounts with failed or unavailable usage responses could disappear from the menu bar list.
- Kept errored accounts visible with their error/re-login state instead of filtering them out of search and list sections.
- Labeled expired/revoked auth errors as `Expired or revoked` and made the `Re-login` action persistent for those accounts.

## 1.0.1 - 2026-05-12

- Improved account capture responsiveness by saving new OAuth accounts from local token identity without making an extra workspace metadata call in the post-login path.
- Debounced the refresh that runs after adding or relogging an account, so repeated account setup does not trigger unnecessary full refreshes between captures.
- Queued one follow-up refresh when a refresh is requested while another refresh is still running, avoiding stale state without blocking the UI.
- Reduced auxiliary metadata request timeouts so workspace/account details cannot hold up the main usage refresh for too long.
- Added a 15-second OAuth token exchange timeout.
- Hardened the localhost OAuth callback listener by waiting for ready connections before reading requests and force-closing callback responses.
- Removed the local mock account mode and seed script from the release build path.
- Refined the menubar UI with a clearer expand/compact toggle and a contextual `Use in Codex` account action.
