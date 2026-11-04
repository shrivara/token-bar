# Releasing Token Bar

Merging application changes into `main` runs CI, but does not publish a release.
Homebrew installs versioned tags, not the latest commit on `main`. Cut a release
to make merged features and fixes available to users.

## Release workflows

- **GitHub release** runs when a `vX.Y.Z` tag is pushed. It publishes a matching
  GitHub release with generated notes, but does not immediately update Homebrew.
- **Daily pricing release** runs on a schedule or manual dispatch. If the
  normalized pricing catalog changed, it bumps the patch version, tests and
  builds the app, commits and tags the update, publishes a GitHub release, and
  attempts to trigger Homebrew synchronization. If prices are unchanged, the
  release job is skipped, even if `main` contains unreleased code changes.
- **Sync token-bar**, in `shrivara/homebrew-tap`, runs on a daily schedule or
  manual dispatch. It updates the formula to the latest version tag and starts
  **Bottle** when a formula update or bottle build is needed.

Automated pricing releases publish directly because tag pushes made with
`GITHUB_TOKEN` do not trigger the **GitHub release** workflow.

## Configure automatic Homebrew synchronization

Create a fine-grained personal access token with access only to
`shrivara/homebrew-tap` and **Actions: read and write** permission. Store it as an
Actions secret in `shrivara/token-bar`:

```sh
gh secret set TAP_WORKFLOW_TOKEN --repo shrivara/token-bar
```

Enter the token at the hidden prompt, not as a command-line argument. Choose an
expiration date and set a renewal reminder. Keep your normal `gh` login separate
from this restricted automation token.

This secret lets **Daily pricing release** dispatch the tap workflow. A missing
secret skips immediate dispatch with a warning; an invalid or expired secret
fails that step even if the release was already published. The tap's daily sync
is a fallback. The built-in `GITHUB_TOKEN` is provided automatically and does
not need to be stored as a repository secret.

## Publish a feature or fix release

Use an authenticated `gh` login with access to both repositories. Run these
commands from the repository root in the same shell so the `version` and `tag`
variables remain available.

### 1. Prepare the version

Start with a clean working tree and update `main`:

```sh
git switch main
git pull --ff-only
git status --short
gh run list --repo shrivara/token-bar --workflow daily-pricing.yml --limit 5
```

Wait for any active pricing-release run to finish before choosing the version,
then update `main` again if that run created a commit.

A feature release can use the existing pricing snapshot. Refreshing it is
optional; see [Updating prices](DEVELOPMENT.md#updating-prices).

Bump the patch version in both `build.sh` and `Sources/token-bar/main.swift`:

```sh
version=$(./Scripts/bump-patch-version.sh)
tag="v${version}"
git diff -- Sources/token-bar/main.swift build.sh
```

Confirm that the version is correct and the tag is unused. Do not move or
replace an existing release tag.

### 2. Test, commit, and tag

```sh
swift test
./build.sh
./Scripts/verify-app.sh
```

Resolve any failures before continuing. For scanner or CLI compatibility
changes, also run the [CLI integration tests](DEVELOPMENT.md#cli-integration-tests).

Stage only the intended release changes. If you refreshed the pricing catalog,
review and stage that file separately before committing.

```sh
git add -- Sources/token-bar/main.swift build.sh
git commit -m "Release $tag"
git tag "$tag"
git push --atomic origin main "$tag"
```

The atomic push publishes the branch and tag together. The tag starts
**GitHub release**, while the branch update starts CI.

### 3. Verify publication and update Homebrew

Find the runs for the release commit:

```sh
gh run list --repo shrivara/token-bar --commit "$(git rev-parse "$tag")"
```

Wait for CI and **GitHub release** to succeed. Replace `RUN_ID` with each run's
ID to follow its result:

```sh
gh run watch RUN_ID --repo shrivara/token-bar --exit-status
```

Then confirm the release and start Homebrew synchronization:

```sh
gh release view "$tag" --repo shrivara/token-bar
gh workflow run sync-token-bar.yml --repo shrivara/homebrew-tap --ref main
gh run list --repo shrivara/homebrew-tap --limit 5
```

The sync workflow calculates the source archive checksum, updates the formula,
and starts **Bottle**. There is no need to edit the formula manually for a
normal release.

Wait for both **Sync token-bar** and **Bottle** to succeed, using their run IDs
with the tap repository:

```sh
gh run watch RUN_ID --repo shrivara/homebrew-tap --exit-status
```

Then check the bottle release:

```sh
gh release view "bottles-token-bar-${version}" --repo shrivara/homebrew-tap
```

The bottle workflow builds and tests Apple Silicon packages on macOS 15 and 26,
uploads them to the tap's release, and commits their checksums to the formula.
These are the build environments, not the app's supported OS range: Token Bar
supports macOS 14 and later. Homebrew selects a compatible bottle when available
and otherwise builds from source with the Xcode Command Line Tools. GitHub has
retired its macOS 14 runners, so new releases no longer include Sonoma bottles.

Only announce Homebrew availability after the bottle build and publish job
succeeds. Users can then update with:

```sh
brew update
brew upgrade token-bar
brew services restart token-bar
```

## Recover a partial release

These steps assume you are recovering the latest intended release. Sync always
selects the latest version tag; it does not roll Homebrew back to an older one.

Set `tag` and `version` to that release before using the commands below (for
example, `tag=vX.Y.Z` and `version=X.Y.Z`, replacing `X.Y.Z` with the actual version).

- If tests passed and the tag exists but the GitHub release was not published,
  inspect the failed workflow before retrying. You can publish it manually:

  ```sh
  gh release create "$tag" --repo shrivara/token-bar --verify-tag \
    --title "$tag" --generate-notes --latest
  ```

- If the release exists but tap dispatch failed, fix `TAP_WORKFLOW_TOKEN` if
  necessary and run **Sync token-bar**. Do not rerun an old pricing-release job
  just to retry the tap: it can bump another version or reuse an old catalog.

  ```sh
  gh workflow run sync-token-bar.yml --repo shrivara/homebrew-tap --ref main
  ```

- If the formula already points to the intended version but its bottles failed,
  rerun the bottle workflow with the expected version:

  ```sh
  gh workflow run bottle.yml --repo shrivara/homebrew-tap --ref main \
    -f version="$version"
  ```

Rebuilding bottles can replace existing bottle assets and update the formula's
checksums. Verify the publish job before considering recovery complete.
