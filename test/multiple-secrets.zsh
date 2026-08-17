#!/usr/bin/env zsh

# Success-path companion to smoke.zsh: fake op on PATH, two secrets on one
# command, driven through the full wire. Verifies map population, one-session
# batching, warm-call signout suppression, masking, and non-export.

emulate -L zsh

typeset root=${ZSH_ARGZERO:A:h:h}
typeset zshctl=${ZSHCTL:-$(command -v zshctl)}
[[ -n $zshctl ]] || { print -r -u 2 -- 'multiple-secrets: zshctl not found'; exit 1 }

typeset home
home=$(mktemp -d ${TMPDIR:-/tmp}/dls.multiple-secrets.XXXXXX) || exit 1

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

function assert_absent {
    typeset name=$1 unexpected=$2 actual=$3
    if [[ $actual != *$unexpected* ]]; then
        print -r -- "ok: $name"
    else
        print -r -- "FAIL: $name"
        print -r -- "  unexpected substring: $unexpected"
        print -r -- "  actual: $actual"
        (( failures++ ))
    fi
}

# The fake op logs every invocation, serves the test references, and accepts
# signout. It is the successful 1Password boundary this test controls.
mkdir -p $home/bin
cat > $home/bin/op <<'EOF'
#!/usr/bin/env zsh
print -r -- "$*" >> ${OP_FAKE_LOG:?}
case $1 in
(read)
    case ${@[-1]} in
    (op://Vault/item/alpha) print -rn -- 'CANARY' ;;
    (op://Vault/item/beta)  print -rn -- 'CANARYTAIL9999' ;;
    (op://Vault/item/gamma) print -rn -- 'ZEBRA-VALUE-9876' ;;
    (*) print -r -u 2 -- "[ERROR] fake op: unknown ref ${@[-1]}"; exit 1 ;;
    esac
    ;;
(signout) ;;
(*) print -r -u 2 -- "[ERROR] fake op: unknown op $1"; exit 1 ;;
esac
EOF
chmod +x $home/bin/op

# A real zshctl extension with two secrets. Observable transforms prove map
# population without exposing values; the raw value separately proves masking.
mkdir -p $home/.local/share/dls/extensions/probe/commands/test-secret
cat > $home/.local/share/dls/extensions/probe/commands/test-secret/command.zsh <<'EOF'
function :help:test-secret {
    heredoc -v help <<'    HELP'
        # desc -- exercise the secret map
    HELP
}

function :args:test-secret {
    eval "$(args -- -- "$@")"
}

function :execute:test-secret {
    dls_execute "$@"
}

# Both reference forms, deliberately. The bare form is what the documentation
# tells an operator to write, so it is the one that must survive the whole path
# from configuration through normalization to the argument `op read` receives;
# the prefixed form is what 1Password's own interface hands you when you copy a
# reference, so it has to keep working too.
: ${dls_secrets[test-secret:alpha]:=Vault/item/alpha}
: ${dls_secrets[test-secret:beta]:=op://Vault/item/beta}

function :dls:test-secret {
    if [[ ${1:-} = probe-cache ]]; then
        typeset _probe_path=$2
        if [[ -v _dls_cache ]]; then
            print -rn -- "${_dls_cache[op://Vault/item/gamma]:-cache unavailable}" > $_probe_path
        else
            print -rn -- 'cache unavailable' > $_probe_path
        fi
        # The other command's literal must stream in the clear. Masking it
        # would mean concealing a value this command was never given, which
        # turns the filter into an oracle: print a guess, watch it vanish, and
        # you have learned a secret you never held.
        print -r -- 'cross-command raw: ZEBRA-VALUE-9876'
        return 0
    fi
    print -r -- "alpha-rev: $(print -rn -- $secret[alpha] | rev)"
    print -r -- "beta-len: ${#secret[beta]}"
    print -r -- "raw: $secret[alpha]"
    print -r -- "raw-long: $secret[beta]"
    PROBE_SECRET=$secret[beta] zsh -c 'print -r -- "child-rev: $(print -rn -- $PROBE_SECRET | rev)"'
    zsh -c '(( ${+secret} )) && print -r -- "child sees secret map" || print -r -- "child sees no secret map"'
    zsh -c '[[ -n ${PROBE_SECRET:-} ]] && print -r -- "prefix leaked past its child" || print -r -- "prefix did not leak"'
}
EOF

# A second command receives a disjoint secret. Once it has run, test-secret
# must not be able to read this value from the server's global cache.
mkdir -p $home/.local/share/dls/extensions/probe/commands/test-other
cat > $home/.local/share/dls/extensions/probe/commands/test-other/command.zsh <<'EOF'
function :help:test-other {
    heredoc -v help <<'    HELP'
        # desc -- populate a cache entry owned by another command
    HELP
}

function :args:test-other {
    eval "$(args -- -- "$@")"
}

function :execute:test-other {
    dls_execute "$@"
}

: ${dls_secrets[test-other:gamma]:=Vault/item/gamma}

function :dls:test-other {
    print -r -- "gamma-len: ${#secret[gamma]}"
}
EOF

export DLS_SOCKET=$home/dls.socket
export OP_FAKE_LOG=$home/op.log
export PATH=$home/bin:$PATH
touch $OP_FAKE_LOG

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
    [[ -S $DLS_SOCKET ]] || { print -r -- 'FAIL: server never bound'; exit 1 }

    typeset out log

    # Cold: two reads, one signout, populated map, masked raw output.
    out=$(dls test-secret 2> $home/err)
    assert 'alpha reaches the map' 'alpha-rev: YRANAC' "$out"
    assert 'beta reaches the map' 'beta-len: 14' "$out"
    assert 'raw print is masked' 'raw: <concealed by dls>' "$out"
    assert_absent 'longer secret tail is masked' 'TAIL9999' "$out"
    assert 'prefix hands one value to one child' 'child-rev: 9999LIATYRANAC' "$out"
    assert 'map does not reach external children' 'child sees no secret map' "$out"
    assert 'prefix scope ends with its child' 'prefix did not leak' "$out"

    log="$(<$OP_FAKE_LOG)"
    integer reads=${#${(M)${(f)log}:#read*}} signouts=${#${(M)${(f)log}:#signout*}}
    assert 'cold call reads twice' 2 $reads
    assert 'cold call signs out once' 1 $signouts

    # Warm: no additional op contact, same populated map.
    out=$(dls test-secret 2> $home/err)
    log="$(<$OP_FAKE_LOG)"
    reads=${#${(M)${(f)log}:#read*}}
    signouts=${#${(M)${(f)log}:#signout*}}
    assert 'warm call still populates' 'alpha-rev: YRANAC' "$out"
    assert 'warm call adds no reads' 2 $reads
    assert 'warm call adds no signout' 1 $signouts

    out=$(dls test-other 2> $home/err)
    assert 'second command receives its secret' 'gamma-len: 16' "$out"

    typeset probe=$home/cache-probe
    out=$(dls test-secret probe-cache $probe 2> $home/err)
    assert 'command cannot read another cache entry' 'cache unavailable' "$(<$probe)"
    assert 'another command value is not concealed' \
        'cross-command raw: ZEBRA-VALUE-9876' "$out"

    dls stop > /dev/null 2>&1
} always {
    # `$server` may name the shell wrapper around zshctl rather than the broker
    # itself, so a bare kill is aimed at a pid that may not be the one holding
    # the socket. `dls stop` is a request, so it reaches the server whatever its
    # pid, and it costs nothing on a run that already stopped.
    [[ -S $DLS_SOCKET ]] && dls stop > /dev/null 2>&1
    (( server )) && kill $server 2>/dev/null
    if (( failures )); then
        print -r -- '--- serve.log ---'
        print -r -- "$(<$home/serve.log)"
        print -r -- '--- op.log ---'
        print -r -- "$(<$OP_FAKE_LOG)"
    fi
    rm -rf $home
}

if (( failures )); then
    print -r -- "multiple-secrets: $failures failure(s)"
    exit 1
fi
print -r -- 'multiple-secrets: PASS'
