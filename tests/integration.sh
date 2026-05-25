#!/bin/bash
# End-to-end tests for the `track` CLI.
# Each case runs against an isolated $HOME so jobs land in $HOME/.status-bar/jobs/.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACK="$REPO_DIR/.build/release/track"

passed=0
failed=0
failures=()

bold()  { printf '\033[1m%s\033[0m' "$*"; }
red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

setup_home() {
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    export PATH="$REPO_DIR/.build/release:$PATH"
}

teardown_home() {
    rm -rf "$TEST_HOME"
}

# Path to the single job file under the current TEST_HOME.
job_file() {
    ls "$TEST_HOME/.status-bar/jobs"/*.json 2>/dev/null | head -1
}

# Read a single field from a pretty-printed sorted JSON file.
# Works for both string and numeric values.
json_get() {
    local file="$1" key="$2"
    grep "\"$key\"" "$file" | head -1 | sed -E 's/.*: *"?([^",}]*)"?,?.*/\1/'
}

assert_eq() {
    local got="$1" want="$2" desc="$3"
    if [ "$got" = "$want" ]; then
        return 0
    fi
    echo
    echo "    $(red FAIL): $desc — wanted [$want], got [$got]"
    return 1
}

run_test() {
    local name="$1"; shift
    printf '  %-32s ' "$name"
    setup_home
    if "$@"; then
        passed=$((passed + 1))
        echo "$(green ok)"
    else
        failed=$((failed + 1))
        failures+=("$name")
        echo "  $(red FAIL)"
    fi
    teardown_home
}

# ---------- test cases ----------

test_wrap_success() {
    "$TRACK" wrap-ok -- echo hello >/dev/null
    rc=$?
    assert_eq "$rc" "0" "track exit code" || return 1
    local f; f="$(job_file)"
    [ -n "$f" ] || { echo "    no job file written"; return 1; }
    assert_eq "$(json_get "$f" state)" "completed" "state" || return 1
    assert_eq "$(json_get "$f" exitCode)" "0" "exitCode" || return 1
}

test_wrap_failure() {
    "$TRACK" wrap-fail -- sh -c 'exit 3' >/dev/null
    rc=$?
    assert_eq "$rc" "3" "track propagates child exit" || return 1
    local f; f="$(job_file)"
    assert_eq "$(json_get "$f" state)" "failed" "state" || return 1
    assert_eq "$(json_get "$f" exitCode)" "3" "exitCode" || return 1
}

test_begin_end_success() {
    local id; id="$("$TRACK" begin "begin-end")"
    "$TRACK" end "$id" 0
    local f="$TEST_HOME/.status-bar/jobs/$id.json"
    assert_eq "$(json_get "$f" state)" "completed" "state" || return 1
    assert_eq "$(json_get "$f" exitCode)" "0" "exitCode" || return 1
}

test_begin_end_failure() {
    local id; id="$("$TRACK" begin "begin-end-fail")"
    "$TRACK" end "$id" 11
    local f="$TEST_HOME/.status-bar/jobs/$id.json"
    assert_eq "$(json_get "$f" state)" "failed" "state" || return 1
    assert_eq "$(json_get "$f" exitCode)" "11" "exitCode" || return 1
}

test_zsh_pipeline_failure() {
    if ! command -v zsh >/dev/null; then
        echo -n "(zsh not available, skipped) "
        return 0
    fi
    zsh -c '
        eval "$(track shell-init zsh)"
        status_begin "zsh-pipe"
        true | sh -c "exit 7" | true
        status_end
    '
    local f; f="$(job_file)"
    assert_eq "$(json_get "$f" state)" "failed" "state" || return 1
    assert_eq "$(json_get "$f" exitCode)" "7" "exitCode via pipestatus" || return 1
}

test_bash_pipeline_failure() {
    bash -c '
        eval "$(track shell-init bash)"
        status_begin "bash-pipe"
        true | sh -c "exit 5" | true
        status_end
    '
    local f; f="$(job_file)"
    assert_eq "$(json_get "$f" state)" "failed" "state" || return 1
    assert_eq "$(json_get "$f" exitCode)" "5" "exitCode via PIPESTATUS" || return 1
}

test_attach_completion() {
    sleep 0.5 &
    local pid=$!
    "$TRACK" attach "$pid" "attached" >/dev/null
    local f; f="$(job_file)"
    # Attach never gets the real exit code (kernel only delivers it to the parent),
    # so we just check that the kernel-observed exit transitioned us to completed.
    assert_eq "$(json_get "$f" state)" "completed" "state" || return 1
}

test_attach_interrupted() {
    sleep 5 &
    local target=$!
    "$TRACK" attach "$target" "interrupted" >/dev/null &
    local watcher=$!
    # Give the watcher time to install signal handlers + enter kevent().
    sleep 0.3
    kill -INT "$watcher"
    wait "$watcher" 2>/dev/null
    kill "$target" 2>/dev/null
    wait "$target" 2>/dev/null
    local f; f="$(job_file)"
    assert_eq "$(json_get "$f" state)" "failed" "state after SIGINT" || return 1
    # 128 + SIGINT(2) = 130
    assert_eq "$(json_get "$f" exitCode)" "130" "exitCode 128+SIGINT" || return 1
}

# ---------- runner ----------

if [ ! -x "$TRACK" ]; then
    echo "Building track first..."
    (cd "$REPO_DIR" && swift build -c release) || exit 1
fi

echo "$(bold "track integration tests")"
echo "binary: $TRACK"
echo

run_test "wrap success"          test_wrap_success
run_test "wrap failure"          test_wrap_failure
run_test "begin/end success"     test_begin_end_success
run_test "begin/end failure"     test_begin_end_failure
run_test "zsh pipeline failure"  test_zsh_pipeline_failure
run_test "bash pipeline failure" test_bash_pipeline_failure
run_test "attach completion"     test_attach_completion
run_test "attach interrupted"    test_attach_interrupted

echo
if [ "$failed" -eq 0 ]; then
    echo "$(green "all $passed passed")"
    exit 0
fi
echo "$(red "$failed failed"), $passed passed"
for name in "${failures[@]}"; do echo "  - $name"; done
exit 1
