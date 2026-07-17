#!/bin/bash
# Regenerates the offline pricing catalog bundled with token-bar.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Sources/TokenBarCore/Resources

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl --fail --location --silent --show-error https://models.dev/api.json |
    jq -S '{
        source: "https://models.dev/api.json",
        license: "MIT (c) models.dev",
        providers: with_entries(
            .value = {
                models: (
                    .value.models |
                    with_entries(select(.value.cost != null) | .value = .value.cost)
                )
            }
        )
    }' > "$tmp"

mv "$tmp" Sources/TokenBarCore/Resources/model-pricing.json
