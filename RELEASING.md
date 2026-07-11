# Releasing token-bar

1. **Test and tag** (in this repo):
   ```sh
   swift test
   # bump CFBundleShortVersionString in build.sh
   git commit -am "Bump version to X.Y.Z"
   git push && git tag vX.Y.Z && git push origin vX.Y.Z
   ```

2. **Update the formula** (in `shrivara/homebrew-tap`):
   ```sh
   curl -fsSL https://github.com/shrivara/token-bar/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   # set url + sha256 in Formula/token-bar.rb, commit, push
   ```

3. **Build bottles** (prebuilt binaries so users don't compile):
   ```sh
   gh workflow run bottle.yml --repo shrivara/homebrew-tap
   ```
   The workflow builds on macOS 14/15/26 (arm64), uploads bottles to a
   `bottles-token-bar-X.Y.Z` release on the tap, and commits the `bottle do`
   block into the formula. Verify the run went green before announcing.

Users then get the new version via `brew update && brew upgrade token-bar`.
