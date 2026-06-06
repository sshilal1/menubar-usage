# CLAUDE.md — menubar-usage

macOS menu bar app showing **Claude** and **ChatGPT (Codex)** usage — rolling
**5-hour** and **weekly** limits — as tiny color-graded gauge bars, with a
click-through popover. Menu-bar-only (no Dock icon). Swift 6 / AppKit, no deps.

## Build / run / install

```bash
swift build -c release                 # build
.build/release/menubar-usage           # run (foreground; it's an accessory app)
.build/release/menubar-usage --once    # one-shot text readout of current usage (diagnostics)
MENUBAR_USAGE_DEBUG=1 .build/debug/menubar-usage --once   # + stderr tracing
./scripts/install.sh                   # build, ad-hoc sign, install to ~/.local/bin, load login LaunchAgent
./scripts/install.sh uninstall         # remove agent + binary
```

The installed copy runs via LaunchAgent `com.local.menubar-usage` (RunAtLoad +
KeepAlive). After code changes, re-run `./scripts/install.sh` to update it.

To restart the installed agent without a full reinstall:

```bash
launchctl kickstart -k "gui/$(id -u)/com.local.menubar-usage"
```

## Logging / diagnostics

The app **always** writes a trace log to `~/Library/Logs/menubar-usage.log`
(rotated to `…1.log` past 512 KB). This is the first place to look when the gauge
shows wrong or estimated numbers — it records, per refresh, which path each
provider took (live / stale cache / estimate) and *why* (keychain `OSStatus`,
HTTP status, token expiry, back-off). The LaunchAgent also captures stdout/stderr
to `~/Library/Logs/menubar-usage.{out,err}.log` for crashes.

```bash
tail -f ~/Library/Logs/menubar-usage.log     # watch live
MENUBAR_USAGE_DEBUG=1 .build/release/menubar-usage --once   # also mirror to stderr
```

`--once` now calls `ClaudeCredentials.prewarmBlocking()` first, so on Keychain-only
machines it can actually reach the live API (the GUI's non-blocking path returns
nil on first call and would otherwise always print the estimate).

## Architecture (files in `Sources/MenubarUsage/`)

- `UsageModel.swift` — `UsageSnapshot`, `Provider` (`.claude`, `.codex`),
  `UsageStore` (refresh orchestration + per-provider deadline), `DataFiles`,
  `AppConfig`, `DebugLog`.
- `Collectors.swift` — `ClaudeUsageCollector`, `CodexUsageCollector`,
  `ClaudeCredentials`. The data layer; adapted from
  [neelashkannan/usage-touchbar](https://github.com/neelashkannan/usage-touchbar).
- `Views.swift` — `MenuBarGauge` (renders the status-item image), plus popover
  drawing views (`PopoverLimitBar`, `StatusDotView`, `ProviderBranding`).
- `PopoverViewController.swift` — the click-through popover (cards per provider).
- `MenuBarController.swift` — owns the `NSStatusItem`, `NSPopover`, and the 20s
  refresh `Timer`.
- `main.swift` — `@main` accessory app + the `--once` CLI path.

### Data sources (all local, authenticated, no scraping)
- **Claude:** `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token
  from `~/.claude/.credentials.json` **or the macOS Keychain** (`Claude
  Code-credentials`). The access token is short-lived (~8h); when it's expired the
  app **refreshes it itself** via `POST https://platform.claude.com/v1/oauth/token`
  (client id `9d1c250a-…`, the value baked into the Claude Code binary) using the
  stored refresh token, and writes the rotated credential back to the Keychain so
  the CLI and this app stay in sync. Offline fallback: token estimate from
  `~/.claude/projects`.
- **ChatGPT:** `GET https://chatgpt.com/backend-api/wham/usage` with the token in
  `~/.codex/auth.json`. Offline fallback: `~/.codex/sessions/**/rollout-*.jsonl`.

## Gotchas / non-obvious decisions

- **Keychain is the tricky part.** This machine has no `~/.claude/.credentials.json`,
  so the Claude token comes from the Keychain. A *synchronous* `SecItemCopyMatching`
  from a non-Claude binary **blocks on a SecurityAgent prompt** — that froze the
  whole refresh originally. Fix: `ClaudeCredentials.currentNonBlocking()` reads the
  Keychain on a background queue and returns whatever's cached now (so Claude shows
  the local `est.` until the token is approved, then upgrades to live). It guards
  against concurrent reads (`keychainReading`) and backs off after a denial
  (`keychainRetryAfter`, 5 min) so the prompt doesn't re-pop every tick.
- **Per-provider deadline:** `UsageStore.collectWithDeadline` runs each collector on
  a detached task raced against a 12s timeout via a one-shot `ResumeGate`, so a slow
  or prompt-blocked provider can never freeze the gauge. Don't replace this with a
  plain `withTaskGroup` child + cancellation — structured teardown still *awaits* a
  stuck child, which reintroduces the freeze.
- **`--once` uses `dispatchMain()`, not a semaphore.** Blocking the main thread with
  `DispatchSemaphore.wait()` in a CLI starves the concurrency runtime (tasks never
  run). The GUI app is fine because `app.run()` provides a live run loop.
- **Ad-hoc signing** in `install.sh` gives the binary a stable identity so the
  Keychain "Always Allow" decision binds reliably (per build).
- **Token refresh writes back to the shared Keychain item.** When the access token
  is expired, `ClaudeCredentials.refreshIfPossible` mints a new one and persists it
  via `SecItemUpdate` (in-place, so the ACL is preserved) into the *same* `Claude
  Code-credentials` item the CLI uses. Refresh tokens **rotate** (the old one dies
  once a new one is issued), so it first probes write access with a no-op
  `SecItemUpdate` and bails if that fails — otherwise a refresh we can't save would
  invalidate the CLI's login. Writeback preserves any sibling top-level JSON keys.
- **Live-fetch back-off ≠ success throttle.** `liveMinInterval` (5 min) only
  throttles *after* a successful fetch (it gates the success cache). A *failed*
  fetch leaves no cache, so without a separate guard `collect()` would re-hit the
  endpoint every 20s tick — which perpetuates a 429. `liveRetryAfter` /
  `setFailureBackoff` adds that guard (90s default, or the server's `Retry-After`,
  capped at 10 min). Don't fold the two together; they gate different states.

## Troubleshooting: Claude shows `est.` or wrong numbers

The Claude card label tells you the data source: a real plan name (`Pro`, `Max 20x`)
means **live** API data; **`est.`** means it fell back to the local token estimate,
which is a guess against assumed budgets (`claudeFiveHourTokenBudget` /
`claudeWeeklyTokenBudget`) — it is routinely wrong, *especially weekly*, and
fabricates the reset schedule. `est.` always means "the live fetch failed." Check
`~/Library/Logs/menubar-usage.log` to see which of these it was:

1. **Keychain prompt not approved.** This machine stores the Claude OAuth token
   only in the Keychain (no `~/.claude/.credentials.json`). The first read pops
   *"menubar-usage wants to use the Claude Code-credentials item"*; until you click
   **Always Allow**, reads return nil and you get `est.`. Log shows
   `claude-cred: keychain read FAILED — … (OSStatus -25308/-25293/-128)` or repeated
   `no token yet (keychain read already in flight)` while the prompt sits unanswered.
   *Fix:* approve the prompt. Ad-hoc signing changes the cdhash every build, so each
   `./scripts/install.sh` re-triggers it (see open item #2).
2. **Expired token.** The access token is short-lived (~8h). The app now **refreshes
   it automatically** with the stored refresh token (`refreshIfPossible`) and writes
   the new credential back to the Keychain. Log shows `claude: access token
   expired/expiring — refreshing` → `claude-cred: token REFRESHED ok`. This needs
   *write* access to the Keychain item, so the first refresh may prompt a second time
   (*"…wants to modify…"*) — click **Always Allow**. If refresh returns non-200
   (`token refresh FAILED — HTTP 4xx`), the refresh token itself is revoked: re-login
   Claude Code (`claude`). Safety: the app probes Keychain writability *before*
   refreshing, so it never rotates a token it can't persist (which would break your
   CLI login).
3. **Rate-limited (HTTP 429).** `oauth/usage` is aggressively throttled. Log shows
   `claude: live API returned HTTP 429`. After any failure the app now backs off
   (`liveFailureBackoff` = 90s, or the server's `Retry-After`) instead of re-hitting
   every 20s tick — important, because hammering a 429 perpetuates it. *Fix:* wait;
   it self-recovers and logs `LIVE ok`.

After fixing, click the gauge (or `kickstart -k`) to force a refresh and watch the
log flip from `ESTIMATE` to `LIVE ok`.

## What's next / open items

1. **[User action] Approve the Keychain prompt once** (*"menubar-usage wants to use
   the Claude Code-credentials keychain item"* → **Always Allow**). Until then the
   Claude gauge shows the local estimate (`est.` in the popover), not live numbers.
   After approving, click the gauge to force a refresh and confirm `est.` → live.
2. **Re-prompt on every reinstall.** Ad-hoc signing changes the cdhash each build,
   so `./scripts/install.sh` re-triggers the Keychain prompt. To make "Always Allow"
   survive updates, sign with a stable self-signed code-signing certificate instead
   of ad-hoc. Not done yet (personal-use tradeoff).
3. **Nice-to-haves (not started):** numeric `%` next to the gauges (toggle), a
   low-limit notification (e.g. >85%), a small Preferences UI (refresh interval,
   which window the gauge prioritizes), a proper `.app` bundle + custom icon, and
   unit tests for the JSONL/rollout parsers.
4. **Endpoint fragility:** `wham/usage` and `oauth/usage` are unofficial. If numbers
   stop updating, check `~/Library/Logs/menubar-usage.log` first (it records the HTTP
   status, token state, and which fallback ran), then verify those endpoints and the
   token files (`--once` + `MENUBAR_USAGE_DEBUG=1` mirror the same trace to stderr).

## Conventions
- Keep the data layer faithful to upstream behavior (caching intervals, fallbacks);
  the upstream tuned these against rate limits. New UI lives in the menu-bar files.
- Credit the upstream project in `README.md` (data-collection approach).
