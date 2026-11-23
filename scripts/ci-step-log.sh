#!/usr/bin/env bash
# BASH_ENV entry for direct GitHub Actions runner scripts only. Do not source
# command text, inspect environments, change umask/options, or wrap child shells.
# Bash 3.2 sets $0 to the interpreter while reading BASH_ENV. Defer
# initialization until its first script command, then immediately remove this
# one-shot DEBUG hook. Never intercept subsequent commands or user traps.
[[ ${GITHUB_ACTIONS-} == true && -z ${TURTLEGIT_CI_STEP_LOG_ACTIVE-} ]] || return 0
[[ -z $(trap -p DEBUG) ]] || return 0
__turtlegit_ci_step_start() {
    trap - DEBUG
    [[ ${GITHUB_ACTIONS-} == true ]] || return 0
    [[ -z ${TURTLEGIT_CI_STEP_LOG_ACTIVE-} && -z ${BASH_EXECUTION_STRING-} ]] || return 0
    [[ ${RUNNER_TEMP-} == /* && ${GITHUB_WORKSPACE-} == /* ]] || return 0
    [[ $0 == "$RUNNER_TEMP/"* && ${0%/*} == "$RUNNER_TEMP" ]] || return 0
    __turtlegit_ci_step_uuid=${0##*/}
    [[ $__turtlegit_ci_step_uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.sh$ ]] || return 0
    [[ -f $0 && ! -L $0 && -d $RUNNER_TEMP && ! -L $RUNNER_TEMP ]] || return 0
    # Respect another entry hook's EXIT ownership; a replaced EXIT trap later in the
    # step is reported as an incomplete record, rather than intercepting DEBUG/trap.
    [[ -z $(trap -p EXIT) ]] || return 0
    __turtlegit_ci_step_uuid=${__turtlegit_ci_step_uuid%.sh}
    # macOS /bin/bash is 3.2: use no Bash-4 dynamic descriptors. Never take
    # descriptors already owned by the caller (including its hooks/child shells).
    if ( : >&8 ) 2>/dev/null; then return 0; fi
    if ( : >&9 ) 2>/dev/null; then return 0; fi
    __turtlegit_ci_step_dir=$GITHUB_WORKSPACE/build/ci-step-logs
    [[ ! -L $GITHUB_WORKSPACE/build && ! -L $__turtlegit_ci_step_dir ]] || return 0
    /bin/mkdir -p "$__turtlegit_ci_step_dir" 2>/dev/null || return 0
    [[ -d $__turtlegit_ci_step_dir && ! -L $__turtlegit_ci_step_dir ]] || return 0
    __turtlegit_ci_step_out=$__turtlegit_ci_step_dir/$__turtlegit_ci_step_uuid.stdout.log
    __turtlegit_ci_step_err=$__turtlegit_ci_step_dir/$__turtlegit_ci_step_uuid.stderr.log
    __turtlegit_ci_step_status=$__turtlegit_ci_step_dir/$__turtlegit_ci_step_uuid.status
    [[ ! -e $__turtlegit_ci_step_out && ! -L $__turtlegit_ci_step_out && ! -e $__turtlegit_ci_step_err && ! -L $__turtlegit_ci_step_err && ! -e $__turtlegit_ci_step_status && ! -L $__turtlegit_ci_step_status ]] || return 0
    # noclobber is confined to a subshell. File modes are private without changing
    # the caller's umask (and therefore its Git/hooks/subprocess behavior).
    ( set -C; : > "$__turtlegit_ci_step_out" && : > "$__turtlegit_ci_step_err" ) 2>/dev/null || return 0
    /bin/chmod 600 "$__turtlegit_ci_step_out" "$__turtlegit_ci_step_err" 2>/dev/null || return 0
    exec 8>&1 9>&2
    exec > >(/usr/bin/tee -a "$__turtlegit_ci_step_out")
    __turtlegit_ci_out_pid=$!
    exec 2> >(/usr/bin/tee -a "$__turtlegit_ci_step_err" >&9)
    __turtlegit_ci_err_pid=$!
    # This diagnostic-only identity prevents inherited BASH_ENV recapture, including
    # nested UUID scripts, and lets the collector exclude only its own active step.
    export TURTLEGIT_CI_STEP_LOG_ACTIVE=$__turtlegit_ci_step_uuid
    __turtlegit_ci_step_finish() {
        local __turtlegit_ci_result=$1
        # Restore the exact original streams first: this closes the owned pipe ends.
        exec 1>&8 2>&9
        exec 8>&- 9>&-
        wait "$__turtlegit_ci_out_pid" 2>/dev/null || :
        wait "$__turtlegit_ci_err_pid" 2>/dev/null || :
        ( set -C; printf '%s\n' "$__turtlegit_ci_result" > "$__turtlegit_ci_step_status" ) 2>/dev/null || :
        /bin/chmod 600 "$__turtlegit_ci_step_status" 2>/dev/null || :
        exit "$__turtlegit_ci_result"
    }
    trap '__turtlegit_ci_step_finish "$?"' EXIT
}
trap '__turtlegit_ci_step_start' DEBUG
