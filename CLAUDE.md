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
- **Claude:** `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token.
  Token sources, in order: the app's **own copy** at
  `~/.config/menubar-usage/credentials.json`, then `~/.claude/.credentials.json`,
  then the macOS **Keychain** (`Claude Code-credentials`, read once to bootstrap the
  app copy). The access token is short-lived (~8h); when it's expired the app
  **refreshes it itself** via `POST https://platform.claude.com/v1/oauth/token`
  (client id `9d1c250a-…`, baked into the Claude Code binary) using the stored
  refresh token, and writes the new credential to its **own file** (`writeToFile`) —
  **not** back to the Keychain (see the prompt-fatigue gotcha). Offline fallback:
  token estimate from `~/.claude/projects`.
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
- **Refreshed tokens go to our own file, NOT the Keychain — to avoid prompt fatigue.**
  Reading another app's Keychain item is fine after one "Always Allow", but
  *modifying* it (`SecItemUpdate`) re-prompts **every session**. We hit this: the
  earlier design wrote the rotated token back to `Claude Code-credentials` and the
  user got "menubar-usage wants to modify…" on every laptop wake (~once per 8h token
  expiry). Fix: `refreshIfPossible` writes the new credential to
  `~/.config/menubar-usage/credentials.json` (`writeToFile`, mode 0600), and
  `readFromFile` reads that **first**. The Keychain is now **read-only** (one bootstrap
  read, also mirrored into our file). Both reference projects avoid Keychain writes
  too — `neelashkannan/usage-touchbar` is read-only with no refresh, and
  `Artzainnn/ClaudeUsageBar` uses a pasted `claude.ai` cookie. **Trade-off:** refresh
  tokens rotate, so the CLI's Keychain copy drifts out of date; the `claude` CLI may
  ask you to log in once. Acceptable since the gauge's whole job is to *read* usage.
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

1. **No token yet (Keychain bootstrap).** If `~/.config/menubar-usage/credentials.json`
   doesn't exist yet, the app does a one-time Keychain read to seed it, which pops
   *"menubar-usage wants to use the Claude Code-credentials item"* — click **Always
   Allow** once. Log shows `claude-cred: keychain read FAILED — … (OSStatus
   -25308/-25293/-128)` if denied, or `keychain read OK … cached to file` on success.
   After that the app reads its own file and never prompts again. (Ad-hoc signing
   changes the cdhash each build, so a *reinstall* can re-trigger this one read — see
   open item #2. To skip even that, pre-seed the file:
   `security find-generic-password -s "Claude Code-credentials" -w >
   ~/.config/menubar-usage/credentials.json && chmod 600 …`.)
2. **Expired token.** The access token is short-lived (~8h). The app **refreshes it
   automatically** with the stored refresh token (`refreshIfPossible`) and saves the
   new credential to **its own file** (no Keychain write → no prompt). Log shows
   `claude: access token expired/expiring — refreshing` → `claude-cred: token
   REFRESHED ok … file write ok`. If refresh returns non-200 (`token refresh FAILED —
   HTTP 4xx`), the refresh token is revoked: re-login Claude Code (`claude`), which
   rewrites the Keychain — then delete `~/.config/menubar-usage/credentials.json` so
   the app re-bootstraps from it.
3. **Rate-limited (HTTP 429).** `oauth/usage` is aggressively throttled. Log shows
   `claude: live API returned HTTP 429`. After any failure the app now backs off
   (`liveFailureBackoff` = 90s, or the server's `Retry-After`) instead of re-hitting
   every 20s tick — important, because hammering a 429 perpetuates it. *Fix:* wait;
   it self-recovers and logs `LIVE ok`.

After fixing, click the gauge (or `kickstart -k`) to force a refresh and watch the
log flip from `ESTIMATE` to `LIVE ok`.

## What's next / open items

1. **[User action] Approve the one-time Keychain bootstrap prompt** (*"menubar-usage
   wants to use the Claude Code-credentials keychain item"* → **Always Allow**) the
   first time, *or* pre-seed `~/.config/menubar-usage/credentials.json` (see
   Troubleshooting #1). After that the app is file-based and never prompts again.
2. **Re-prompt on every reinstall.** Ad-hoc signing changes the cdhash each build, so
   `./scripts/install.sh` can re-trigger the one bootstrap Keychain *read* (not the
   per-session write — that's gone). A stable self-signed code-signing certificate
   would make "Always Allow" survive updates; pre-seeding the file sidesteps it
   entirely. Not done yet (personal-use tradeoff).
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
