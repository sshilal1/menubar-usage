# Menubar Usage

A tiny macOS menu bar app that shows your **Claude** and **ChatGPT** usage —
both the rolling **5‑hour** and **weekly** limits — at a glance. It lives only
in the menu bar (no Dock icon) and refreshes automatically.

This is a menu‑bar port of Neelash Kannan's
[usage-touchbar](https://github.com/neelashkannan/usage-touchbar), which does the
same thing for the MacBook Touch Bar. The data-collection layer is adapted from
that project; the menu bar UI is new.

## What it shows

In the menu bar, each provider gets a 2‑letter badge (`CL`, `GP`) and two slim
gauge bars — the left bar is the **5‑hour** window, the right is the **weekly**
window — color‑graded green → orange → red as you approach the limit.

Click the menu bar item to open a popover with the exact percentages, when each
window resets, your plan, and a **Refresh** button.

## Where the numbers come from

Everything is read locally from the tools you're already signed into — no extra
login, no scraping.

- **Claude** — `GET https://api.anthropic.com/api/oauth/usage`, authenticated with
  the OAuth token from `~/.claude/.credentials.json`, or, if that file doesn't
  exist, from the macOS **Keychain** (`Claude Code-credentials`). This is the same
  data Claude Code's `/usage` command shows. Falls back to a local token estimate
  from `~/.claude/projects/**/*.jsonl` when the live numbers aren't available.

  **One-time Keychain approval:** if your Claude token lives in the Keychain
  (no `~/.claude/.credentials.json`), macOS shows a prompt the first time —
  *"menubar-usage wants to use the Claude Code-credentials keychain item."* Click
  **Always Allow**. Until you do, the Claude gauge shows the local estimate
  (tagged `est.` in the popover) instead of the live percentages. The read happens
  in the background, so the menu bar never freezes while the prompt is open.
- **ChatGPT** — `GET https://chatgpt.com/backend-api/wham/usage`, authenticated
  with the token Codex wrote to `~/.codex/auth.json`. Codex runs against your
  ChatGPT plan, so these are your ChatGPT subscription's 5‑hour and weekly
  windows. Falls back to scanning `~/.codex/sessions/.../rollout-*.jsonl`.

If a provider isn't signed in, its gauge dims and the popover offers a sign‑in
link.

## Build & run

Requires macOS 13+ and a Swift 6 toolchain (Xcode 16+).

```bash
swift build -c release
.build/release/menubar-usage
```

A one‑shot text readout (handy for checking it works without the UI):

```bash
.build/release/menubar-usage --once
```

## Start automatically at login

```bash
./scripts/install.sh
```

This installs the binary to `~/.local/bin` and registers a LaunchAgent that
starts the app at login and relaunches it if it quits. To remove:

```bash
./scripts/install.sh uninstall
```

## Configuration (optional)

Anthropic doesn't publish exact Claude token limits, so the **offline** Claude
estimate uses budgets you can override at
`~/.config/menubar-usage/config.json`:

```json
{
  "claudeFiveHourTokenBudget": 90000000,
  "claudeWeeklyTokenBudget": 440000000,
  "claudePlanLabel": "Max 20x"
}
```

These only affect the offline fallback; when the live API is reachable the real
percentages are used.

## Credits

Data-collection approach adapted from
[neelashkannan/usage-touchbar](https://github.com/neelashkannan/usage-touchbar).
