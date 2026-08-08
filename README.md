# token-bar

A minimal macOS menu bar app showing today's AI usage: spend, tokens in/out, and cache hit rate.

<p align="center">
  <img src="docs/screenshot.png" width="425" alt="Token Bar panel showing yearly spend, token usage, cache hit rate, a spend graph, and per-model breakdowns">
</p>

The numbers roll odometer-style whenever new usage lands. Left-click the menu bar item for a panel with the period's totals, a spend graph, and a per-tool, per-model breakdown; the **D / W / M / Y** buttons switch between day, week, month, and year. The camera button copies a clean Retina PNG to the clipboard as both an image and a pasteable file. Right-click (or Control-click) for view options — toggle the spend graph, provider icons, and full vs. short model names. Quit is at the bottom of the left-click panel.

## Supported tools

| Tool | Source | Cost |
|---|---|---|
| [Claude Code](https://claude.com/claude-code) | `~/.claude/projects/**/*.jsonl` | Computed from bundled models.dev rates |
| [Codex](https://developers.openai.com/codex/) | `~/.codex/sessions/**/*.jsonl` | Computed from bundled models.dev rates |
| [OpenCode](https://opencode.ai) | `~/.local/share/opencode/opencode.db` | Computed from bundled models.dev rates |
| [pi](https://github.com/badlogic/pi-mono) | `~/.pi/agent/sessions/**/*.jsonl` | Computed from bundled models.dev rates |

Updates are instant: file-system events fire the moment a session writes new usage (coalesced to at most about one refresh per second while streaming), with a 60s timer as backstop and for the midnight rollover. Tools with no activity today are hidden from the panel.

## Homebrew

### Install

```sh
brew install shrivara/tap/token-bar
brew services start token-bar   # start now + at login
```

### Update

```sh
brew update
brew upgrade token-bar
brew services restart token-bar
```

## Notes

- Spend is API-equivalent pricing. If you're on a subscription plan (e.g. Claude Max), the dollar figure shows what the usage *would* cost via the API, not what you're billed.
- API-equivalent pricing comes from an offline snapshot of [models.dev](https://models.dev/), bundled with the app under its MIT license. Prices are looked up by provider and model for every message, including cache and reasoning tokens. Qualified provider variants fall back to their base provider: for example, `openai-codex` falls back to the matching `openai` model price. Because this is an approximation, it remains marked `~`. A model that isn't in the catalog (or lacks a complete price) contributes $0 and is marked `~` in the panel — the tool's own recorded cost is not trusted, and there is no rate guessing.
- Everything is read locally at runtime. No network access, no telemetry.

## License

MIT
