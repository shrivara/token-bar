# Development

## Requirements

- macOS 14 or later and a Swift 5.9 or newer toolchain from Xcode or the Xcode
  Command Line Tools.
- Node.js 24, npm, and Python 3 for the CLI integration tests.
- `curl` and `jq` to update the pricing catalog.

Run the commands below from the repository root unless noted otherwise.

## Build from source

If you normally use the Homebrew service, stop it before running a development
build so you can identify which version is active:

```sh
brew services stop token-bar
```

Clone the repository, build the app, and open it:

```sh
git clone https://github.com/shrivara/token-bar.git
cd token-bar
./build.sh
./Scripts/verify-app.sh
open TokenBar.app
```

`build.sh` creates a release build of `TokenBar.app` with its resources, icon, and
an ad-hoc code signature. `verify-app.sh` checks the bundle structure, version,
and code signature. The build uses the checked-in pricing catalog; it does not
fetch new prices.

Add `TokenBar.app` in **System Settings → General → Login Items** to start a
source-built app at login. After quitting the development build, use
`brew services start token-bar` to start the installed version again.

### App icon

Regenerate the checked-in icon after changing its drawing script:

```sh
./Scripts/generate-app-icon.swift Assets/AppIcon.icns
```

CI regenerates the icon on macOS 15 and compares it with the checked-in file.

## Unit tests

```sh
swift test
```

The suite covers usage scanning, pricing, reporting periods, OpenCode 1.x and
2.x databases, remote-history caching, and preference migration. Tests that require
installed agent CLIs are skipped unless enabled by the integration script below.

CI runs tests, builds the app, and verifies the bundle on macOS 15 and 26.
Markdown-only changes, changes under `docs/`, and license-only changes are
excluded from that workflow. A successful CI run does not publish a release.

## Debug usage scanning

The `--print` diagnostic is available only in debug builds. SwiftPM uses the
debug configuration by default:

```sh
swift run token-bar --print
```

This scans today's local history, prints per-model usage and overall totals,
then exits. It does not use the remote machine selected in the app.

## CLI integration tests

The integration script runs the real Claude Code, Codex, OpenCode 1.x,
OpenCode 2.x, and pi CLIs against local mock APIs, then scans the history they
write. It uses temporary homes and workspaces, dummy credentials, and no paid
model requests.

Install the CLIs locally. OpenCode 1.x and 2.x use separate prefixes because both
provide an `opencode` executable:

```sh
npm install --prefix .build/harness-integrations --no-audit --no-fund \
  @anthropic-ai/claude-code@latest \
  @earendil-works/pi-coding-agent@latest \
  @openai/codex@latest \
  opencode-ai@latest
npm install --prefix .build/opencode-v2 --no-audit --no-fund \
  @opencode/cli@latest
```

Run all five integrations:

```sh
PATH="$PWD/.build/harness-integrations/node_modules/.bin:$PATH" \
OPENCODE_V2_BIN="$PWD/.build/opencode-v2/node_modules/.bin/opencode" \
  ./Scripts/test-harness-integration.sh
```

Pass `claude-code`, `codex`, `opencode`, `opencode-v2`, or `pi` to run just one
integration. Keep the same environment settings when selecting a single test.
For custom installations, the script accepts `CLAUDE_BIN`, `CODEX_BIN`,
`OPENCODE_BIN`, `OPENCODE_V2_BIN`, and `PI_BIN` overrides.

The **Harness integrations** workflow runs on macOS 15 for matching source,
test, or workflow changes, on a daily schedule, and when manually dispatched.
It installs the latest CLI versions to detect upstream storage-format changes:

```sh
gh workflow run harness-integration.yml --repo shrivara/token-bar --ref main
```

## Updating prices

Regenerate the bundled catalog from models.dev and review the changes:

```sh
./Scripts/update-model-pricing.sh
git diff -- Sources/TokenBarCore/Resources/model-pricing.json
swift test
```

The script normalizes upstream prices and includes experimental model modes
with separate costs. It updates the snapshot but does not bump the app version,
create a tag, or publish a release.

The **Daily pricing release** workflow checks for catalog changes every day and
publishes a patch release only when the snapshot differs. Feature releases do
not require a pricing change. See [Releasing Token Bar](RELEASING.md) for both
release paths and Homebrew synchronization.
