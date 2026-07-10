#!/usr/bin/env zsh

# Smoke test for the dls wire protocol and control plane. Exercises
# everything that does not require a 1Password fingerprint: the streams,
# exit code propagation, verb denial, invalid references, cache clear,
# status and stop. The op read path and the signout re-prompt must be
# verified by a human with a finger.
#
# The test runs against an isolated HOME so it can inject a test verb as
# a real zshctl extension and cannot see the operator's configuration.

emulate -L zsh

typeset root=${ZSH_ARGZERO:A:h:h}
typeset zshctl=${ZSHCTL:-$(command -v zshctl)}
[[ -n $zshctl ]] || { print -r -u 2 -- 'smoke: zshctl not found; set ZSHCTL'; exit 1 }

typeset home
home=$(mktemp -d ${TMPDIR:-/tmp}/dls.smoke.XXXXXX) || exit 1

integer failures=0

function assert {
    typeset name=$1 expected=$2 actual=$3
    if [[ $actual = *$expected* ]]; then
        print -r -- "ok: $name"
    else
        print -r -- "FAIL: $name"
        print -r -- "  expected substring: $expected"
        print -r -- "  actual: $actual"
        (( failures++ ))
    fi
}

function assert_code {
    typeset name=$1
    integer expected=$2 actual=$3
    if (( expected == actual )); then
        print -r -- "ok: $name"
    else
        print -r -- "FAIL: $name: expected exit $expected, got $actual"
        (( failures++ ))
    fi
}

# Inject a secretless test verb as a zshctl extension in the isolated
# HOME. It exercises the full streaming path: both streams, arguments,
# and a non-zero exit code.
mkdir -p $home/.local/share/dls/extensions/smoke/commands/test-echo
cat > $home/.local/share/dls/extensions/smoke/commands/test-echo/command.zsh <<'EOF'
function :help:test-echo {
    heredoc -v help <<'    HELP'
        # desc -- exercise the dls streams
    HELP
}

function :args:test-echo {
    eval "$(args -- -- "$@")"
}

function :execute:test-echo {
    dls_call verb test-echo "$@"
}

function dls:verb:test-echo {
    print -r -- "out: $*"
    print -r -u 2 -- "err: $*"
    return 3
}
EOF

export DLS_SOCKET=$home/dls.socket

function dls {
    HOME=$home $zshctl $root/bin/dls "$@"
}

integer server=0
{
    dls serve > $home/serve.log 2>&1 &
    server=$!

    integer i
    for i in {1..100}; do
        [[ -S $DLS_SOCKET ]] && break
        sleep 0.1
    done
    if [[ ! -S $DLS_SOCKET ]]; then
        print -r -- 'FAIL: server never bound its socket'
        print -r -- "$(<$home/serve.log)"
        exit 1
    fi

    typeset out err
    integer code

    out=$(dls status 2> $home/err)
    assert_code 'status exits zero' 0 $?
    assert 'status reports the socket' $DLS_SOCKET "$out"
    assert 'status reports the verbs' 'verbs: gh, test-echo' "$out"
    assert 'status reports an empty cache' 'cached: (none)' "$out"

    out=$(dls test-echo hello world 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'test-echo exit code propagates' 3 $code
    assert 'test-echo standard out' 'out: hello world' "$out"
    assert 'test-echo standard error' 'err: hello world' "$err"
    if [[ $out != *'err: hello world'* ]]; then
        print -r -- 'ok: streams are separated'
    else
        print -r -- 'FAIL: standard error leaked into standard out'
        (( failures++ ))
    fi

    out=$(dls gh auth token 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'gh auth is denied' 77 $code
    assert 'gh auth denial names the gate' 'denied' "$err"

    out=$(dls gh 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'unresolvable secret fails' 69 $code

    out=$(dls fetch not-a-reference 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'invalid fetch reference fails' 1 $code
    assert 'invalid fetch reference message' 'invalid secret reference' "$err"

    out=$(dls clear 2> $home/err)
    assert_code 'clear exits zero' 0 $?
    assert 'clear reports an empty cache' 'cleared 0' "$out"

    out=$(dls stop 2> $home/err)
    assert_code 'stop exits zero' 0 $?
    assert 'stop reports' 'stopping' "$out"

    for i in {1..100}; do
        kill -0 $server 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 $server 2>/dev/null; then
        print -r -- 'FAIL: server still running after stop'
        (( failures++ ))
    else
        print -r -- 'ok: server exited on stop'
    fi
    if [[ ! -e $DLS_SOCKET ]]; then
        print -r -- 'ok: socket removed on exit'
    else
        print -r -- 'FAIL: socket not removed on exit'
        (( failures++ ))
    fi
} always {
    if (( failures )); then
        print -r -- '--- serve.log ---'
        print -r -- "$(<$home/serve.log)"
    fi
    (( server )) && kill $server 2>/dev/null
    rm -rf $home
}

if (( failures )); then
    print -r -- "smoke: $failures failure(s)"
    exit 1
fi
print -r -- 'smoke: PASS'
