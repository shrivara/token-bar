# Releasing token-bar

The `Daily pricing release` workflow checks models.dev every day. A changed catalog is tested and built, then committed to `main` with an automatic patch-version bump and `vX.Y.Z` tag. An unchanged catalog does nothing. The workflow immediately starts the tap's `Sync token-bar` workflow, which updates the formula and builds bottles. The tap also checks daily as a fallback.

## One-time tap trigger setup

Create a fine-grained personal access token scoped only to `shrivara/homebrew-tap`, with **Actions: read and write**, then add it to this repository as the `TAP_WORKFLOW_TOKEN` Actions secret:

```sh
gh secret set TAP_WORKFLOW_TOKEN --repo shrivara/token-bar
```

The steps below are for feature releases or workflow recovery.

1. **Test and tag manually**:
    ```sh
    ./Scripts/update-model-pricing.sh  # review the updated snapshot
    ./Scripts/bump-patch-version.sh    # or set the desired version in both files
    swift test && ./build.sh
    git commit -am "Release vX.Y.Z"
    git push && git tag vX.Y.Z && git push origin vX.Y.Z
    ```

2. **Update the formula manually** (in `shrivara/homebrew-tap`):
   ```sh
   curl -fsSL https://github.com/shrivara/token-bar/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   # set url + sha256 in Formula/token-bar.rb, commit, push
   ```

3. **Build bottles manually** (prebuilt binaries so users don't compile):
   ```sh
   gh workflow run bottle.yml --repo shrivara/homebrew-tap
   ```
   The workflow builds on macOS 14/15/26 (arm64), uploads bottles to a
   `bottles-token-bar-X.Y.Z` release on the tap, and commits the `bottle do`
   block into the formula. Verify the run went green before announcing.

Users then get the new version via `brew update && brew upgrade token-bar`.
