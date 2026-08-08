# Development

Requires macOS 14+ and the Xcode Command Line Tools.

## Build from source

```sh
git clone https://github.com/shrivara/token-bar
cd token-bar
./build.sh
open TokenBar.app
```

Add `TokenBar.app` to System Settings → Login Items if you want the development build to start at login.

## Debug usage scanning

The `--print` diagnostic is available only in debug builds. SwiftPM uses the
debug configuration by default:

```sh
swift run token-bar --print
```

This prints today's per-model breakdown and totals to stdout, then exits.

## Updating prices

The **Daily pricing release** GitHub Actions workflow checks models.dev once a day. If the normalized catalog changed, it bumps the patch version, runs the tests, builds the app, and commits and tags the new version. It then triggers the Homebrew tap to update its formula and build bottles; the tap's own daily check is a fallback. If nothing changed, no release is created.

To update manually, run `./Scripts/update-model-pricing.sh` to regenerate the checked-in snapshot and `./Scripts/bump-patch-version.sh` to bump the app version. Normal builds do not fetch the network.
