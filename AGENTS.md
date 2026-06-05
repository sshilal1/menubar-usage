# AGENTS.md — menubar-usage

macOS menu bar app showing **Codex** and **ChatGPT (Codex)** usage — rolling
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

## Architecture (files in `Sources/MenubarUsage/`)

- `UsageModel.swift` — `UsageSnapshot`, `Provider` (`.Codex`, `.codex`),
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
- **Codex:** `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token
  from `~/.Codex/.credentials.json` **or the macOS Keychain** (`Codex
  Code-credentials`). Offline fallback: token estimate from `~/.Codex/projects`.
- **ChatGPT:** `GET https://chatgpt.com/backend-api/wham/usage` with the token in
  `~/.codex/auth.json`. Offline fallback: `~/.codex/sessions/**/rollout-*.jsonl`.

## Gotchas / non-obvious decisions

- **Keychain is the tricky part.** This machine has no `~/.Codex/.credentials.json`,
  so the Codex token comes from the Keychain. A *synchronous* `SecItemCopyMatching`
  from a non-Codex binary **blocks on a SecurityAgent prompt** — that froze the
  whole refresh originally. Fix: `ClaudeCredentials.currentNonBlocking()` reads the
  Keychain on a background queue and returns whatever's cached now (so Codex shows
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

## What's next / open items

1. **[User action] Approve the Keychain prompt once** (*"menubar-usage wants to use
   the Codex-credentials keychain item"* → **Always Allow**). Until then the
   Codex gauge shows the local estimate (`est.` in the popover), not live numbers.
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
   stop updating, verify those endpoints and the token files first (`--once` +
   `MENUBAR_USAGE_DEBUG=1` are the fastest way to see what each collector returns).

## Conventions
- Keep the data layer faithful to upstream behavior (caching intervals, fallbacks);
  the upstream tuned these against rate limits. New UI lives in the menu-bar files.
- Credit the upstream project in `README.md` (data-collection approach).
