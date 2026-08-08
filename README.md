# token-bar

A macOS menu bar app for local AI usage: spend, input/output tokens, and cache hit rate.

<p align="center">
  <img src="docs/screenshot.png" width="425" alt="Token Bar panel showing yearly spend, token usage, cache hit rate, a spend graph, and per-model breakdowns">
</p>

Left-click for day, week, month, or year totals, a spend graph, model breakdowns, screenshots, and Quit. Right-click for display options.

## Supported tools

| Tool | Local data |
|---|---|
| [Claude Code](https://claude.com/claude-code) | `~/.claude/projects/**/*.jsonl` |
| [Codex](https://developers.openai.com/codex/) | `~/.codex/sessions/**/*.jsonl` |
| [OpenCode](https://opencode.ai) | `~/.local/share/opencode/opencode.db` |
| [pi](https://github.com/badlogic/pi-mono) | `~/.pi/agent/sessions/**/*.jsonl` |

Token Bar watches these sources for changes and refreshes immediately, with a 60-second fallback.

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

- Spend is API-equivalent pricing, not your subscription bill.
- Rates come from a bundled [models.dev](https://models.dev/) snapshot. Unknown prices contribute $0 and are marked `~`.
- Everything stays local: no network access or telemetry.

## License

MIT
