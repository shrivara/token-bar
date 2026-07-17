# token-bar

A minimal macOS menu bar app showing today's AI usage: spend, tokens in/out, and cache hit rate.

<p align="center">
  <img src="docs/screenshot.png" width="367" alt="token-bar in the menu bar with its dropdown panel open, showing today's spend, tokens, cache hit rate, and a per-model breakdown">
</p>

The numbers roll odometer-style whenever new usage lands. Click the item for a panel with the day's totals and a per-tool, per-model breakdown.

## Supported tools

| Tool | Source | Cost |
|---|---|---|
| [Claude Code](https://claude.com/claude-code) | `~/.claude/projects/**/*.jsonl` | Computed from bundled models.dev rates |
| [Codex](https://developers.openai.com/codex/) | `~/.codex/sessions/**/*.jsonl` | Computed from bundled models.dev rates |
| [OpenCode](https://opencode.ai) | `~/.local/share/opencode/opencode.db` | Computed from bundled models.dev rates, with stored-cost fallback |
| [pi](https://github.com/badlogic/pi-mono) | `~/.pi/agent/sessions/**/*.jsonl` | Computed from bundled models.dev rates, with stored-cost fallback |

Updates are instant: file-system events fire the moment a session writes new usage (coalesced to at most about one refresh per second while streaming), with a 60s timer as backstop and for the midnight rollover. Tools with no activity today are hidden from the panel.

## Install

### Homebrew

```sh
brew install shrivara/tap/token-bar
brew services start token-bar   # start now + at login
```

### From source

Requires macOS 14+ and the Xcode Command Line Tools.

```sh
git clone https://github.com/shrivara/token-bar
cd token-bar
./build.sh
open TokenBar.app
```

Add `TokenBar.app` to System Settings → Login Items to start it at login.

### Check the numbers without the app

```sh
token-bar --print   # or ./TokenBar.app/Contents/MacOS/TokenBar --print
```

Prints today's per-model breakdown and totals to stdout, then exits.

## Notes

- Spend is API-equivalent pricing. If you're on a subscription plan (e.g. Claude Max), the dollar figure shows what the usage *would* cost via the API, not what you're billed.
- API-equivalent pricing comes from an offline snapshot of [models.dev](https://models.dev/), bundled with the app under its MIT license. Prices are looked up by provider and model for every message, including cache and reasoning tokens. Models without a complete catalog price use the tool's recorded cost where available and are marked `~` in the panel. Unknown Claude models use the bundled Claude Opus 4.6 rate and are marked `~`.
- Everything is read locally at runtime. No network access, no telemetry.

## Updating prices

Run `./Scripts/update-model-pricing.sh` to fetch the current models.dev catalog and regenerate the checked-in pricing snapshot. Review and commit the resulting JSON with the release; normal builds do not fetch the network.

## License

MIT
