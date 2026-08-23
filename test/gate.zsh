#!/usr/bin/env zsh

# Regression suite for the restart gate. The gate's claim is that the code a
# human approved by restarting the server is the code the server runs, and this
# file asserts that claim against the three routes that were open before it was
# closed. Each route ends with a canary value reaching somewhere it should not,
# so a failure appears as evidence on disk rather than as an argument.
#
# The three routes are not variations on one theme; they are three different
# places code can enter, and a fix for any one of them leaves the others open.
#
#   swap      a command's own helper, edited on disk after the restart. The
#             helper resolves inside the forked request, so before the fix the
#             parent held an unresolved stub and every request re-read the file.
#
#   shadow    a framework name that an extension also ships, resolved through
#             fpath. Extension directories lead fpath, so the extension copy
#             wins unless the framework reclaims the name by absolute path.
#
#   define    a framework name that an extension writes outright in its command
#             file. Command files are sourced in the parent, and `autoload +X`
#             will not replace an existing definition, so eager loading alone
#             does not displace it.
#
# The shadowing functions here are written to behave correctly as well as to
# leave a marker. That is deliberate: if one of them wins, the suite should fail
# on the marker rather than collapse in a cascade of unrelated errors, so the
# report names the route that opened rather than the first thing that broke.
#
# The op boundary is a local fake that fails closed, so a machine with a live
# 1Password integration can never turn a test into a biometric prompt.

emulate -L zsh

typeset root=${ZSH_ARGZERO:A:h:h}
typeset zshctl=${ZSHCTL:-$(command -v zshctl)}
[[ -n $zshctl ]] || { print -r -u 2 -- 'gate: zshctl not found; set ZSHCTL'; exit 1 }

typeset home
home=$(mktemp -d ${TMPDIR:-/tmp}/dls.gate.XXXXXX) || exit 1

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

function assert_absent_file {
    typeset name=$1 path=$2
    if [[ ! -e $path ]]; then
        print -r -- "ok: $name"
    else
        print -r -- "FAIL: $name"
        print -r -- "  file exists with: $(<$path)"
        (( failures++ ))
    fi
}

export DLS_SOCKET=$home/dls.socket
export OP_FAKE_LOG=$home/op.log
export GATE_LOOT=$home/loot
export GATE_MARK=$home/mark
touch $OP_FAKE_LOG

mkdir -p $home/bin
cat > $home/bin/op <<'EOF'
#!/usr/bin/env zsh
print -r -- "$*" >> ${OP_FAKE_LOG:?}
case $1 in
(read)
    case ${@[-1]} in
    (op://Vault/item/token) print -rn -- 'GATE-CANARY-VALUE' ;;
    (*) exit 1 ;;
    esac
    ;;
(signout) ;;
(*) exit 1 ;;
esac
EOF
chmod +x $home/bin/op
export PATH=$home/bin:$PATH

typeset ext=$home/.local/share/dls/extensions/probe
mkdir -p $ext/commands/task $ext/functions

# The command under the swap route. Its body does nothing but call a helper,
# which is the whole point: the helper is the code the gate has to bind.
cat > $ext/commands/task/command.zsh <<'EOF'
function :help:task {
    heredoc -v help <<'    HELP'
        # desc -- calls a library helper
    HELP
}

function :args:task {
    eval "$(args -- -- "$@")"
}

function :execute:task {
    dls_execute "$@"
}

: ${dls_secrets[task:token]:=Test/Vault/item/token}

function :dls:task {
    task_helper
}
EOF

# The reviewed helper: what a human would read before restarting.
cat > $ext/functions/task_helper <<'EOF'
print -r -- 'helper: reviewed body'
EOF

# The shadow route. An extension ships a file named for a framework function.
# It normalizes correctly so that a win is reported by the marker rather than by
# the suite falling apart, and the marker is what must never appear.
cat > $ext/functions/dls_ref <<'EOF'
print -rn -- 'dls_ref' > ${GATE_MARK:?}.shadow
typeset _dls_reference=${1:-}
if [[ $_dls_reference != ?*/?*/?*/?* || $_dls_reference = *//* ||
      /$_dls_reference/ = */./* || /$_dls_reference/ = */../* ]]; then
    REPLY=''
    return 1
fi
REPLY=$_dls_reference
EOF

# The define route. A command file writes a framework function outright, in the
# parent, at source time. This one neuters the op session teardown, so a win is
# visible twice over: the marker appears and the fake op never records a signout.
mkdir -p $ext/commands/direct
cat > $ext/commands/direct/command.zsh <<'EOF'
function :help:direct {
    heredoc -v help <<'    HELP'
        # desc -- defines a framework function outright
    HELP
}

function :args:direct {
    eval "$(args -- -- "$@")"
}

function :execute:direct {
    dls_execute "$@"
}

function :dls:direct {
    print -r -- 'direct ran'
}

function dls_signout {
    print -rn -- 'dls_signout' > ${GATE_MARK:?}.define
}
EOF

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
        print -r -- "$(cat $home/serve.log 2>/dev/null)"
        exit 1
    fi

    typeset out

    # --- route one: the helper swapped after the gate closed -----------------
    #
    # A cold call first, so the reviewed body is known to work and the secret is
    # known to resolve. Then the helper is rewritten to something no human
    # approved, which reads the secret and writes it past the masker. The server
    # is not restarted. It must still run the body that was on disk when it
    # started.

    out=$(dls task 2> $home/err)
    assert 'reviewed helper runs before the swap' 'helper: reviewed body' "$out"

    cat > $ext/functions/task_helper <<'EOF'
print -rn -- "$secret[token]" > ${GATE_LOOT:?}.swap
print -r -- 'helper: swapped body'
EOF

    out=$(dls task 2> $home/err)
    assert 'swapped helper does not run' 'helper: reviewed body' "$out"
    assert_absent_file 'swapped helper reaches no secret' $GATE_LOOT.swap

    # A second call, because the first one after a swap could have been served
    # from a body cached for other reasons. Every request must keep answering
    # from the approved body, not merely the next one.
    out=$(dls task 2> $home/err)
    assert 'swapped helper still does not run on a later call' \
        'helper: reviewed body' "$out"
    assert_absent_file 'swapped helper still reaches no secret' $GATE_LOOT.swap

    # --- route two: a framework name shadowed through fpath ------------------
    #
    # The extension ships `functions/dls_ref`, and extension directories lead
    # fpath. Resolution runs through dls_ref on every cold secret, so if the
    # shadow ever wins, the calls above have already tripped its marker.

    assert_absent_file 'fpath shadow of a framework function never runs' \
        $GATE_MARK.shadow

    # --- route three: a framework name defined in a command file -------------
    #
    # The extension's command file defines dls_signout in the parent at source
    # time. A win shows up twice: its marker appears, and the real signout never
    # runs, so the fake op records no signout for a cold resolution.

    out=$(dls direct 2> $home/err)
    assert 'command with a shadowing definition still runs' 'direct ran' "$out"
    assert_absent_file 'defined framework function never runs' $GATE_MARK.define

    typeset log
    log="$(cat $OP_FAKE_LOG 2>/dev/null)"
    integer signouts=${#${(M)${(f)log}:#signout*}}
    if (( signouts >= 1 )); then
        print -r -- 'ok: the framework signout ran, so its name was not displaced'
    else
        print -r -- 'FAIL: no signout recorded; the framework signout was displaced'
        (( failures++ ))
    fi

    # --- the gate is not a substitute for a restart --------------------------
    #
    # Everything above asserts that unapproved code stayed out. This asserts the
    # other half, so the suite cannot be satisfied by a server that simply never
    # runs anything: restart, and the swapped body — now reviewed by the act of
    # restarting — is what runs.

    dls stop > /dev/null 2>&1
    for i in {1..50}; do
        [[ -e $DLS_SOCKET ]] || break
        sleep 0.1
    done
    wait $server 2>/dev/null
    server=0

    dls serve > $home/serve2.log 2>&1 &
    server=$!
    for i in {1..100}; do
        [[ -S $DLS_SOCKET ]] && break
        sleep 0.1
    done
    if [[ -S $DLS_SOCKET ]]; then
        out=$(dls task 2> $home/err)
        assert 'a restart admits the edited helper' 'helper: swapped body' "$out"
        dls stop > /dev/null 2>&1
    else
        print -r -- 'FAIL: server did not restart'
        print -r -- "$(cat $home/serve2.log 2>/dev/null)"
        (( failures++ ))
    fi
} always {
    [[ -S $DLS_SOCKET ]] && dls stop > /dev/null 2>&1
    (( server )) && kill $server 2>/dev/null
    if (( failures )); then
        print -r -- '--- serve.log ---'
        print -r -- "$(cat $home/serve.log 2>/dev/null)"
        print -r -- '--- op.log ---'
        print -r -- "$(cat $OP_FAKE_LOG 2>/dev/null)"
    fi
    rm -rf $home
}

if (( failures )); then
    print -r -- "gate: $failures failure(s)"
    exit 1
fi
print -r -- 'gate: PASS'
