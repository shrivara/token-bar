#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
harness=${1:-all}

case "$harness" in
    all|claude-code|codex|opencode|pi) ;;
    *)
        echo "usage: $0 [all|claude-code|codex|opencode|pi]" >&2
        exit 2
        ;;
esac

work=$(mktemp -d)
server_pids=
cleanup() {
    for pid in $server_pids; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

resolve_bin() {
    local candidate=$1
    if [[ "$candidate" == */* ]]; then
        if [[ ! -x "$candidate" ]]; then
            echo "Harness executable not found: $candidate" >&2
            exit 1
        fi
        RESOLVED_BIN=$candidate
    else
        RESOLVED_BIN=$(command -v "$candidate" || true)
        if [[ -z "$RESOLVED_BIN" ]]; then
            echo "Harness is not installed: $candidate" >&2
            exit 1
        fi
    fi
}

start_mock() {
    local name=$1
    local script=$2
    local port_file="$work/$name-port"
    MOCK_LOG="$work/$name-server.log"

    python3 "$repo_root/$script" "$port_file" >"$work/$name-server.out" 2>"$MOCK_LOG" &
    local pid=$!
    server_pids="$server_pids $pid"

    for _ in $(seq 1 100); do
        if [[ -s "$port_file" ]]; then
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "$name mock server exited during startup:" >&2
            cat "$MOCK_LOG" >&2
            exit 1
        fi
        sleep 0.05
    done
    if [[ ! -s "$port_file" ]]; then
        echo "Timed out starting the $name mock server." >&2
        cat "$MOCK_LOG" >&2
        exit 1
    fi
    MOCK_PORT=$(cat "$port_file")
}

show_failure() {
    local name=$1
    local stdout=$2
    local stderr=$3
    local server_log=$4
    echo "$name failed:" >&2
    cat "$stdout" >&2
    cat "$stderr" >&2
    cat "$server_log" >&2
}

run_claude_code() {
    echo "=== Claude Code integration ==="
    resolve_bin "${CLAUDE_BIN:-claude}"
    local bin=$RESOLVED_BIN
    local root="$work/claude-code"
    local home="$root/home"
    local workspace="$root/workspace"
    mkdir -p "$home" "$workspace"
    start_mock claude-code Tests/Integration/anthropic_mock_server.py
    local port=$MOCK_PORT
    local server_log=$MOCK_LOG

    "$bin" --version
    if ! (
        cd "$workspace"
        HOME="$home" \
        ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
        ANTHROPIC_API_KEY=dummy \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1 \
        DISABLE_AUTOUPDATER=1 \
        DISABLE_ERROR_REPORTING=1 \
        DISABLE_TELEMETRY=1 \
            "$bin" --print \
            --model claude-token-bar-integration \
            --permission-mode bypassPermissions \
            --tools '' \
            --disable-slash-commands \
            --no-chrome \
            --system-prompt 'Reply once without tools.' \
            'Reply with done.'
    ) </dev/null >"$root/claude.out" 2>"$root/claude.err"; then
        show_failure "Claude Code" "$root/claude.out" "$root/claude.err" "$server_log"
        exit 1
    fi

    RUN_CLAUDE_CODE_INTEGRATION=1 \
    CLAUDE_CODE_INTEGRATION_PROJECTS="$home/.claude/projects" \
    CLAUDE_CODE_INTEGRATION_WORKSPACE="$workspace" \
        swift test --package-path "$repo_root" --filter ClaudeCodeIntegrationTests
}

run_codex() {
    echo "=== Codex integration ==="
    resolve_bin "${CODEX_BIN:-codex}"
    local bin=$RESOLVED_BIN
    local root="$work/codex"
    local home="$root/home"
    local codex_home="$home/.codex"
    local workspace="$root/workspace"
    mkdir -p "$codex_home" "$workspace"
    start_mock codex Tests/Integration/codex_mock_server.py
    local port=$MOCK_PORT
    local server_log=$MOCK_LOG

    "$bin" --version
    if ! HOME="$home" CODEX_HOME="$codex_home" "$bin" exec \
        --skip-git-repo-check \
        --ignore-user-config \
        --disable plugins \
        --sandbox danger-full-access \
        --cd "$workspace" \
        --model gpt-token-bar-integration \
        --config 'model_provider="token_bar_mock"' \
        --config "model_providers.token_bar_mock={name=\"Token Bar mock\",base_url=\"http://127.0.0.1:$port/v1\",wire_api=\"responses\",requires_openai_auth=false,supports_websockets=false}" \
        'Reply with done without using tools.' \
        </dev/null >"$root/codex.out" 2>"$root/codex.err"; then
        show_failure "Codex" "$root/codex.out" "$root/codex.err" "$server_log"
        exit 1
    fi

    RUN_CODEX_INTEGRATION=1 \
    CODEX_INTEGRATION_SESSIONS="$codex_home/sessions" \
    CODEX_INTEGRATION_WORKSPACE="$workspace" \
        swift test --package-path "$repo_root" --filter CodexIntegrationTests
}

run_opencode() {
    echo "=== OpenCode integration ==="
    resolve_bin "${OPENCODE_BIN:-opencode}"
    local bin=$RESOLVED_BIN
    local root="$work/opencode"
    local home="$root/home"
    local workspace="$root/workspace"
    mkdir -p "$home" "$workspace"
    start_mock opencode Tests/Integration/openai_chat_mock_server.py
    local port=$MOCK_PORT
    local server_log=$MOCK_LOG
    local config
    config=$(cat <<JSON
{"autoupdate":false,"model":"token-bar-mock/gpt-token-bar-integration","provider":{"token-bar-mock":{"npm":"@ai-sdk/openai-compatible","name":"Token Bar mock","options":{"baseURL":"http://127.0.0.1:$port/v1","apiKey":"dummy"},"models":{"gpt-token-bar-integration":{"name":"Token Bar integration","limit":{"context":128000,"output":4096}}}}}}
JSON
)

    "$bin" --version
    if ! (
        cd "$workspace"
        HOME="$home" \
        XDG_DATA_HOME="$home/.local/share" \
        XDG_CONFIG_HOME="$home/.config" \
        XDG_CACHE_HOME="$home/.cache" \
        XDG_STATE_HOME="$home/.local/state" \
        OPENCODE_CONFIG_CONTENT="$config" \
        OPENCODE_DISABLE_PROJECT_CONFIG=1 \
        OPENCODE_PURE=true \
            "$bin" run --pure \
            --model token-bar-mock/gpt-token-bar-integration \
            --format json \
            'Reply with done without using tools.'
    ) </dev/null >"$root/opencode.out" 2>"$root/opencode.err"; then
        show_failure "OpenCode" "$root/opencode.out" "$root/opencode.err" "$server_log"
        exit 1
    fi

    RUN_OPENCODE_INTEGRATION=1 \
    OPENCODE_INTEGRATION_DB="$home/.local/share/opencode/opencode.db" \
    OPENCODE_INTEGRATION_WORKSPACE="$workspace" \
        swift test --package-path "$repo_root" --filter OpenCodeIntegrationTests
}

run_pi() {
    echo "=== pi integration ==="
    resolve_bin "${PI_BIN:-pi}"
    local bin=$RESOLVED_BIN
    local root="$work/pi"
    local home="$root/home"
    local agent_dir="$home/.pi/agent"
    local sessions="$agent_dir/sessions"
    local workspace="$root/workspace"
    mkdir -p "$agent_dir" "$workspace"
    start_mock pi Tests/Integration/openai_chat_mock_server.py
    local port=$MOCK_PORT
    local server_log=$MOCK_LOG

    cat >"$agent_dir/models.json" <<JSON
{"providers":{"token-bar-mock":{"baseUrl":"http://127.0.0.1:$port/v1","api":"openai-completions","apiKey":"dummy","models":[{"id":"gpt-token-bar-integration","name":"Token Bar integration","reasoning":false,"input":["text"],"cost":{"input":2,"output":10,"cacheRead":0.2,"cacheWrite":4},"contextWindow":128000,"maxTokens":4096}]}}}
JSON
    printf '%s\n' '{"enableInstallTelemetry":false}' >"$agent_dir/settings.json"

    "$bin" --version
    if ! (
        cd "$workspace"
        HOME="$home" \
        PI_OFFLINE=1 \
        PI_TELEMETRY=0 \
            "$bin" --print \
            --provider token-bar-mock \
            --model gpt-token-bar-integration \
            --api-key dummy \
            --no-tools \
            --no-extensions \
            --no-skills \
            --no-prompt-templates \
            --no-themes \
            --no-context-files \
            --system-prompt 'Reply once without tools.' \
            'Reply with done.'
    ) </dev/null >"$root/pi.out" 2>"$root/pi.err"; then
        show_failure "pi" "$root/pi.out" "$root/pi.err" "$server_log"
        exit 1
    fi

    RUN_PI_INTEGRATION=1 \
    PI_INTEGRATION_SESSIONS="$sessions" \
    PI_INTEGRATION_WORKSPACE="$workspace" \
        swift test --package-path "$repo_root" --filter PiIntegrationTests
}

case "$harness" in
    all)
        run_claude_code
        run_codex
        run_opencode
        run_pi
        ;;
    claude-code) run_claude_code ;;
    codex) run_codex ;;
    opencode) run_opencode ;;
    pi) run_pi ;;
esac
