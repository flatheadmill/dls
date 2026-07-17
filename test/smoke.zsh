#!/usr/bin/env zsh

# Smoke test for the dls wire protocol and control plane. Exercises
# everything that does not require a 1Password fingerprint: the streams,
# exit code propagation, command refusal, invalid references, cache clear,
# status and stop. The op read path and the signout re-prompt must be
# verified by a human with a finger.
#
# The test runs against an isolated HOME so it can inject a test command as
# a real zshctl extension and cannot see the operator's configuration.

emulate -L zsh

typeset root=${ZSH_ARGZERO:A:h:h}
typeset zshctl=${ZSHCTL:-$(command -v zshctl)}
[[ -n $zshctl ]] || { print -r -u 2 -- 'smoke: zshctl not found; set ZSHCTL'; exit 1 }

typeset home
home=$(mktemp -d ${TMPDIR:-/tmp}/dls.smoke.XXXXXX) || exit 1

integer failures=0

# This suite owns its failure path. Never let a machine's live 1Password
# integration turn an expected resolution failure into a biometric prompt.
mkdir -p $home/bin
cat > $home/bin/op <<'EOF'
#!/usr/bin/env zsh
exit 1
EOF
chmod +x $home/bin/op
export PATH=$home/bin:$PATH

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

# Inject a secretless test command as a zshctl extension in the isolated
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
    dls_execute "$@"
}

function :dls:test-echo {
    if [[ ${1:-} = refuse ]]; then
        print -r -u 2 -- 'dls: test-echo refuses this request'
        return 77
    fi
    print -r -- "out: $*"
    print -r -u 2 -- "err: $*"
    return 3
}
EOF

export DLS_SOCKET=$home/dls.socket

function dls {
    HOME=$home $zshctl $root/bin/dls "$@"
}

# Malformed secret-table structure is an operator configuration error and must
# fail at the restart gate, before a socket exists for an agent to call.
typeset malformed_home=$home/malformed-home
typeset malformed_socket=$home/malformed.socket
mkdir -p $malformed_home/.config/dls
cat > $malformed_home/.config/dls/config.zsh <<'EOF'
dls_secrets[badkey]=op://Private/item/field
EOF
typeset malformed_out
malformed_out=$(HOME=$malformed_home DLS_SOCKET=$malformed_socket \
    $zshctl $root/bin/dls serve 2>&1)
integer malformed_code=$?
assert_code 'malformed secrets key refuses startup' 1 $malformed_code
assert 'malformed secrets key is named' 'badkey' "$malformed_out"
if [[ ! -e $malformed_socket ]]; then
    print -r -- 'ok: malformed secrets key never binds'
else
    print -r -- 'FAIL: malformed secrets key bound a socket'
    (( failures++ ))
fi

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
    assert 'status reports the commands' 'commands: gh, test-echo' "$out"
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

    out=$(dls test-echo refuse 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'in-command refusal exits 77' 77 $code
    assert 'in-command refusal explains itself' 'test-echo refuses this request' "$err"

    out=$(dls gh auth token 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'gh auth fails unresolved' 69 $code
    assert 'gh auth names the resolution failure' 'unable to resolve secret reference' "$err"

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
