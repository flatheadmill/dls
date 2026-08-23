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
zmodload zsh/datetime

typeset root=${ZSH_ARGZERO:A:h:h}
typeset zshctl=${ZSHCTL:-$(command -v zshctl)}
[[ -n $zshctl ]] || { print -r -u 2 -- 'smoke: zshctl not found; set ZSHCTL'; exit 1 }

typeset home
home=$(mktemp -d ${TMPDIR:-/tmp}/dls.smoke.XXXXXX) || exit 1

integer failures=0

# Keep GitHub CLI's two independent state roots inside the disposable HOME.
# The production command must replace both; leaving either ambient would make
# this suite miss an installed alias or extension on a configured machine.
unset GH_CONFIG_DIR XDG_CONFIG_HOME XDG_DATA_HOME

# This suite owns its failure path. Never let a machine's live 1Password
# integration turn an expected resolution failure into a biometric prompt.
mkdir -p $home/bin
cat > $home/bin/op <<'EOF'
#!/usr/bin/env zsh
case $1:${@[-1]} in
(read:op://Private/github/token)
    [[ -f $OP_FAKE_STATE ]] || exit 1
    print -rn -- 'smoke-github-token'
    ;;
(signout:*)
    ;;
(*)
    exit 1
    ;;
esac
EOF
chmod +x $home/bin/op
export PATH=$home/bin:$PATH
export OP_FAKE_STATE=$home/op-state

mkdir -p $home/.config/dls
cat > $home/.config/dls/config.zsh <<'EOF'
dls_secrets[gh:token]=Test/Private/github/token
EOF

# The boundary fixtures below are real gh registrations, so this suite needs a
# real gh. Refuse rather than skip: a run that quietly omits the alias and
# extension assertions would report PASS while proving nothing about the one
# boundary this command claims, which is worse than not running at all.
if ! command -v gh > /dev/null 2>&1; then
    print -r -u 2 -- \
        'smoke: gh not found; the alias and extension boundary fixtures require it'
    exit 1
fi

# Put executable doors in both places GitHub CLI discovers them. These are
# genuine gh registrations rather than argv lookalikes: before dls supplies
# sterile state roots, each top-level name runs with GH_TOKEN in its
# environment and writes it beyond the output masker.
HOME=$home gh alias set --shell peek \
    "printf %s \"\$GH_TOKEN\" > $home/gh-alias-loot" || exit 1
mkdir -p $home/.local/share/gh/extensions/gh-peekext
cat > $home/.local/share/gh/extensions/gh-peekext/gh-peekext <<EOF
#!/bin/sh
printf %s "\$GH_TOKEN" > "$home/gh-extension-loot"
EOF
chmod +x $home/.local/share/gh/extensions/gh-peekext/gh-peekext

# Fail at fixture construction, not later with a misleading boundary result,
# if this installed gh resolves either kind of registration differently.
HOME=$home GH_TOKEN=fixture gh peek || exit 1
[[ $(<$home/gh-alias-loot) = fixture ]] || exit 1
HOME=$home GH_TOKEN=fixture gh peekext || exit 1
[[ $(<$home/gh-extension-loot) = fixture ]] || exit 1
rm -f $home/gh-alias-loot $home/gh-extension-loot

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
    if [[ ${1:-} = detach ]]; then
        # A detached child that has released the standard three descriptors
        # no longer belongs to the request. It may outlive the client without
        # retaining any of the masking pipes.
        ( exec sleep 4 ) >/dev/null 2>&1 </dev/null &!
        return 0
    fi
    if [[ ${1:-} = detach-fork ]]; then
        # The same case without the exec. Today the two are identical because
        # no descriptor here is close-on-exec, so both forms carry whatever the
        # command tree carries. They would diverge the moment anything is
        # marked close-on-exec, because an exec'd binary drops such a
        # descriptor while a forked shell keeps it — so the exec form alone
        # would stop probing the forked channel. Both are pinned now.
        ( sleep 4 ) >/dev/null 2>&1 </dev/null &!
        return 0
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
dls_secrets[badkey]=Test/Private/item/field
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

# Helper functions are bound at startup rather than read from disk per request.
# This asserts that positively, by the one consequence visible from outside: a
# helper that cannot be resolved has to stop the server at the gate. If helpers
# were still resolved lazily inside each forked request, an unparseable one
# would be invisible at startup and the server would bind its socket happily —
# which is exactly what it did before this was fixed. So a server that refuses
# here is the only proof from out here that the binding happens at all.
typeset unbindable_home=$home/unbindable-home
typeset unbindable_socket=$home/unbindable.socket
typeset unbindable_ext=$unbindable_home/.local/share/dls/extensions/probe
mkdir -p $unbindable_ext/commands/test-helper $unbindable_ext/functions
cat > $unbindable_ext/commands/test-helper/command.zsh <<'EOF'
function :help:test-helper {
    heredoc -v help <<'    HELP'
        # desc -- calls a library helper
    HELP
}

function :args:test-helper {
    eval "$(args -- -- "$@")"
}

function :execute:test-helper {
    dls_execute "$@"
}

function :dls:test-helper {
    test_helper
}
EOF
print -r -- "print -r -- 'unterminated" > $unbindable_ext/functions/test_helper
# Backgrounded rather than captured, because the failure mode here is a server
# that starts. A command substitution would then wait on a foreground server
# that never returns, and the suite would hang instead of reporting — a test
# that hangs on regression is barely better than one that passes on it.
HOME=$unbindable_home DLS_SOCKET=$unbindable_socket \
    $zshctl $root/bin/dls serve > $home/unbindable.log 2>&1 &
integer unbindable_server=$!
integer unbindable_started=0
for i in {1..100}; do
    [[ -S $unbindable_socket ]] && { unbindable_started=1; break }
    kill -0 $unbindable_server 2>/dev/null || break
    sleep 0.1
done
if (( unbindable_started )); then
    print -r -- 'FAIL: unresolvable helper bound a socket and served'
    (( failures++ ))
    HOME=$unbindable_home DLS_SOCKET=$unbindable_socket \
        $zshctl $root/bin/dls stop > /dev/null 2>&1
    kill $unbindable_server 2>/dev/null
else
    print -r -- 'ok: unresolvable helper never binds'
fi
wait $unbindable_server 2>/dev/null
# `cat` rather than the `$(<file)` form, which is read during a `zsh -n` syntax
# check when it appears as a command argument — the file does not exist at that
# point and the check fails. Oddly it is only that position: the same form in a
# `typeset` assignment passes `zsh -n` silently. `cat` sidesteps the question
# and tolerates the file's absence quietly.
typeset unbindable_out=$(cat $home/unbindable.log 2>/dev/null)
assert 'unresolvable helper is named' 'test_helper' "$unbindable_out"

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

    # Round trip time is the oracle here because the property under test is
    # client liveness. A descriptor census would be more direct and is hostage
    # to sandboxes and platform restrictions; wall clock is not. The asymmetry
    # is what makes a timing assertion safe in this one spot: a leaked
    # completion descriptor holds the client for the child's full lifetime, and
    # load only ever makes that worse, so a false pass is not reachable. A
    # false fail needs the healthy round trip, which measures hundredths of a
    # second, to stall past the threshold — so the threshold is set an order of
    # magnitude above it, and the child outlives the threshold by as much
    # again.
    #
    # This assertion is not specific to any one descriptor. The child holds
    # everything it inherited, so reverting the `report` close, or the fd 3
    # close, or leaking any future scaffolding descriptor into the command tree
    # all land here as a stalled client.
    float started elapsed
    typeset form
    for form in detach detach-fork; do
        started=$EPOCHREALTIME
        out=$(dls test-echo $form 2> $home/err)
        code=$?
        elapsed=$(( EPOCHREALTIME - started ))
        assert_code "$form command exits zero" 0 $code
        if (( elapsed < 2.0 )); then
            print -r -- "ok: $form command releases the client"
        else
            printf 'FAIL: %s command held the client for %.3fs\n' $form $elapsed
            (( failures++ ))
        fi
    done

    out=$(dls test-echo refuse 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'in-command refusal exits 77' 77 $code
    assert 'in-command refusal explains itself' 'test-echo refuses this request' "$err"

    out=$(dls gh 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'unresolvable secret fails' 69 $code
    assert 'unresolvable secret explains itself' 'unable to resolve secret reference' "$err"

    # Both repository option forms, because they take different numbers of
    # words as the parser walks past them. The attached form is one step; the
    # two-token form is the only arm whose miscounting could step over the
    # family word and hand a refused family through to gh.
    touch $OP_FAKE_STATE
    typeset family
    for family in auth alias extension; do
        out=$(dls gh --repo=owner/repo $family list 2> $home/err)
        code=$?
        err=$(<$home/err)
        assert_code "gh $family refusal exits 77" 77 $code
        assert "gh $family refusal explains itself" \
            "dls: gh $family is blocked" "$err"

        out=$(dls gh -R owner/repo $family list 2> $home/err)
        code=$?
        err=$(<$home/err)
        assert_code "gh $family refusal exits 77 past -R" 77 $code
    done

    out=$(dls gh peek 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'configured gh alias is unavailable' 1 $code
    assert 'configured gh alias reports unknown' 'unknown command "peek"' "$err"
    if [[ ! -e $home/gh-alias-loot ]]; then
        print -r -- 'ok: configured gh alias did not receive the token'
    else
        print -r -- 'FAIL: configured gh alias received the token'
        (( failures++ ))
    fi

    out=$(dls gh peekext 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'installed gh extension is unavailable' 1 $code
    assert 'installed gh extension reports unknown' 'unknown command "peekext"' "$err"
    if [[ ! -e $home/gh-extension-loot ]]; then
        print -r -- 'ok: installed gh extension did not receive the token'
    else
        print -r -- 'FAIL: installed gh extension received the token'
        (( failures++ ))
    fi

    out=$(dls fetch not-a-reference 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'invalid fetch reference fails' 1 $code
    assert 'invalid fetch reference message' 'invalid secret reference' "$err"

    out=$(dls fetch op://Private/github/token 2> $home/err)
    code=$?
    err=$(<$home/err)
    assert_code 'op reference is not a DLS reference' 1 $code
    assert 'op reference rejection is explained' 'invalid secret reference' "$err"

    out=$(dls clear 2> $home/err)
    assert_code 'clear exits zero' 0 $?
    assert 'clear reports the cached token' 'cleared 1' "$out"

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

    # A signal must be sufficient by itself. Do not wake the listener with a
    # request after sending it: that is the event that concealed the blocking
    # accept bug by giving the loop a chance to observe its cleared run flag.
    typeset signal signal_name signal_status signal_line
    integer launcher actual
    for signal in INT TERM; do
        signal_name=${(L)signal}
        export DLS_SOCKET=$home/dls-$signal_name.socket
        dls serve > $home/serve-$signal_name.log 2>&1 &
        launcher=$!
        server=$launcher

        for i in {1..100}; do
            [[ -S $DLS_SOCKET ]] && break
            sleep 0.1
        done
        if [[ ! -S $DLS_SOCKET ]]; then
            print -r -- "FAIL: $signal_name server never bound its socket"
            (( failures++ ))
            continue
        fi

        # `$!` can be the shell wrapper around zshctl. Ask the server for its
        # own pid before the signal, then make no further connection.
        actual=0
        signal_status=$(dls status 2> $home/err)
        for signal_line in ${(f)signal_status}; do
            [[ $signal_line = '  pid: '* ]] || continue
            actual=${signal_line#'  pid: '}
        done
        if (( ! actual )); then
            print -r -- "FAIL: $signal_name status did not report the server pid"
            (( failures++ ))
            dls stop > /dev/null 2>&1
            wait $launcher 2>/dev/null
            server=0
            continue
        fi
        server=$actual

        kill -s $signal $server
        for i in {1..30}; do
            kill -0 $server 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 $server 2>/dev/null; then
            print -r -- "FAIL: server still running after SIG$signal"
            (( failures++ ))
            kill -KILL $server 2>/dev/null
        else
            print -r -- "ok: server exited after SIG$signal without a request"
        fi
        wait $launcher 2>/dev/null
        server=0

        if [[ ! -e $DLS_SOCKET ]]; then
            print -r -- "ok: SIG$signal removed the socket"
        else
            print -r -- "FAIL: SIG$signal left the socket behind"
            (( failures++ ))
        fi
    done
} always {
    if (( failures )); then
        print -r -- '--- serve.log ---'
        print -r -- "$(<$home/serve.log)"
    fi
    # An aborted run cannot rely on pids, but the socket knows who is listening.
    # `$server` may name the shell wrapper around zshctl rather than the broker
    # — the signal cases below ask the server for its own pid for exactly that
    # reason — so a bare kill here is aimed at a process that may not be the one
    # holding the socket. Whether that actually strands a broker was not
    # reproduced: three attempts, including a process group interrupt mid-run,
    # all tore down cleanly. So this is a cheap guard against a measured
    # property rather than a fix for an observed leak. Stopping by protocol
    # reaches the server whatever its pid and costs nothing on a run that
    # already stopped, which is enough to keep on its own terms.
    [[ -S $DLS_SOCKET ]] && dls stop > /dev/null 2>&1
    (( server )) && kill $server 2>/dev/null
    rm -rf $home
}

if (( failures )); then
    print -r -- "smoke: $failures failure(s)"
    exit 1
fi
print -r -- 'smoke: PASS'
