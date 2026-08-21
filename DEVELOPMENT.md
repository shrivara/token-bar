# Development

Requires macOS 14+ and the Xcode Command Line Tools.

## Build from source

```sh
git clone https://github.com/shrivara/token-bar
cd token-bar
./build.sh                    # release build with an ad-hoc code seal
./Scripts/verify-app.sh
open TokenBar.app
```

Regenerate the checked-in app icon after changing its drawing script:

```sh
./Scripts/generate-app-icon.swift Assets/AppIcon.icns
```

Add `TokenBar.app` to System Settings → Login Items if you want the development build to start at login.

## Debug usage scanning

The `--print` diagnostic is available only in debug builds. SwiftPM uses the
debug configuration by default:

```sh
swift run token-bar --print
```

This prints today's per-model breakdown and totals to stdout, then exits.

## Harness integration tests

The integration tests run the real Claude Code, Codex, OpenCode, and pi CLIs
against local mock APIs, then scan the sessions or database they wrote. They use
no API keys or paid model requests:

```sh
npm install --prefix .build/harness-integrations \
  @anthropic-ai/claude-code@latest \
  @earendil-works/pi-coding-agent@latest \
  @openai/codex@latest \
  opencode-ai@latest
PATH="$PWD/.build/harness-integrations/node_modules/.bin:$PATH" \
  ./Scripts/test-harness-integration.sh
```

Pass `claude-code`, `codex`, `opencode`, or `pi` to run one integration. CI runs
all four against their latest releases on pull requests and daily so upstream
storage-format changes are detected even when this repository is idle.

## Updating prices

The **Daily pricing release** GitHub Actions workflow checks models.dev once a day. If the normalized catalog changed, it bumps the patch version, runs the tests, builds the app, and commits and tags the new version. It then triggers the Homebrew tap to update its formula and build bottles; the tap's own daily check is a fallback. If nothing changed, no release is created.

To update manually, run `./Scripts/update-model-pricing.sh` to regenerate the checked-in snapshot and `./Scripts/bump-patch-version.sh` to bump the app version. Normal builds do not fetch the network.
