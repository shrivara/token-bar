# token-bar

A minimal macOS menu bar app showing today's AI usage: spend, tokens in/out, and cache hit rate.

```
$4.82  1.2M↑ 48K↓  91%
```

Click the item for a breakdown by tool and model.

## Supported tools

| Tool | Source | Cost |
|---|---|---|
| [Claude Code](https://claude.com/claude-code) | `~/.claude/projects/**/*.jsonl` | Computed from published API rates |
| [OpenCode](https://opencode.ai) | `~/.local/share/opencode/opencode.db` | OpenCode's own per-message cost |
| [pi](https://github.com/badlogic/pi-mono) | `~/.pi/agent/sessions/**/*.jsonl` | pi's own per-message cost |

Updates instantly via file-system events when a session writes new usage, with a 60s timer as backstop (and midnight rollover).

## Install

### Homebrew

```sh
brew install shrivara/tap/token-bar
brew services start token-bar   # start now + at login
```

### From source

```sh
git clone https://github.com/shrivara/token-bar
cd token-bar
./build.sh
open TokenBar.app
```

Add `TokenBar.app` to System Settings → Login Items to start it at login.

## Notes

- Spend is API-equivalent pricing. If you're on a subscription plan (e.g. Claude Max), the dollar figure shows what the usage *would* cost via the API, not what you're billed.
- Claude pricing is a small hardcoded table in `Sources/token-bar/main.swift`; unknown models fall back to Opus rates and are marked `~` in the dropdown.
- Everything is read locally. No network access, no telemetry.

## License

MIT
