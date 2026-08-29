#!/bin/bash
# Regenerates the offline pricing catalog bundled with token-bar.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Sources/TokenBarCore/Resources

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl --fail --location --silent --show-error --retry 3 https://models.dev/api.json |
    jq -S '
        # OpenCode exposes each models.dev experimental mode as a separate
        # `${model}-${mode}` model. Project the same ids into this pricing-only
        # catalog, with a mode cost overriding the corresponding base fields.
        def model_costs:
            . as $models
            | (reduce ($models | to_entries[]) as $model
                ({};
                 if $model.value.cost == null then .
                 else .[$model.key] = $model.value.cost
                 end)) as $base
            | (reduce ($models | to_entries[]) as $model
                ({};
                 reduce (($model.value.experimental.modes // {}) | to_entries[]) as $mode
                    (.;
                     (($model.value.cost // {}) + ($mode.value.cost // {})) as $cost
                     | if ($cost.input | type) == "number" and ($cost.output | type) == "number"
                       then .[$model.key + "-" + $mode.key] = $cost
                       else .
                       end))) as $modes
            # An explicit upstream model is authoritative if an id ever collides.
            | $modes + $base;

        {
            source: "https://models.dev/api.json",
            license: "MIT (c) models.dev",
            providers: with_entries(
                .value = {models: (.value.models | model_costs)}
            )
        }
    ' > "$tmp"

mv "$tmp" Sources/TokenBarCore/Resources/model-pricing.json
