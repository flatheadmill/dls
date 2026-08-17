#!/usr/bin/env zsh

# File secrets: declared in `dls_files`, materialized into the request's own
# directory, delivered to the command as a path rather than a value.
#
# The suite checks the three things that make that a real facility rather than
# a convenience. Text arrives intact, including the trailing newline that a
# certificate owns, and a NUL-bearing file exercises byte-preserving delivery
# rather than text-only delivery. The directory they land in cannot be
# enumerated, which is the whole of the file-side mechanism — a recursive sweep
# stops at `opendir` while a program handed the exact path opens it and notices
# nothing. And the directory does not outlive the request that made it.
#
# It also checks the two refusals, which exist for different reasons and are
# worth keeping distinct. A newline in a value survives an environment
# variable perfectly well; it is refused because it is the tell that a file was
# meant. A null byte does not survive at all — nothing carries one through
# `execve` — so refusing it prevents a child receiving a truncated credential
# and failing somewhere far from the cause.

emulate -L zsh

typeset root=${ZSH_ARGZERO:A:h:h}
typeset zshctl=${ZSHCTL:-$(command -v zshctl)}
[[ -n $zshctl ]] || { print -r -u 2 -- 'files: zshctl not found'; exit 1 }

typeset home
home=$(mktemp -d ${TMPDIR:-/tmp}/dls.files.XXXXXX) || exit 1

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

export DLS_SOCKET=$home/dls.socket
export PROBE_OUT=$home/probe

# A certificate-shaped body, deliberately ending in a newline, and a value
# carrying a null byte so the second refusal has something to refuse.
mkdir -p $home/bin
cat > $home/bin/op <<'EOF'
#!/usr/bin/env zsh
case $1 in
(read)
    case ${@[-1]} in
    (op://Vault/item/cert)    printf -- '-----BEGIN CANARY-----\nLINE-ONE\n-----END CANARY-----\n' ;;
    (op://Vault/item/token)   print -rn -- 'plain-token-value' ;;
    (op://Vault/item/multi)   printf -- 'first\nsecond' ;;
    (op://Vault/item/nulled)  printf -- 'head\000tail' ;;
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
mkdir -p $ext/commands/{holder,badvalue,badnul}

cat > $ext/commands/holder/command.zsh <<'EOF'
function :help:holder { heredoc -v help <<'    HELP'
        # desc -- receives a file and a value
    HELP
}
function :args:holder { eval "$(args -- -- "$@")" }
function :execute:holder { dls_execute "$@" }

: ${dls_files[holder:CERT]:=Vault/item/cert}
: ${dls_files[holder:BINARY]:=Vault/item/nulled}
: ${dls_secrets[holder:token]:=Vault/item/token}

function :dls:holder {
    # Report facts about the path rather than its content, so the suite can
    # check the file without the body printing a secret it was handed.
    print -r -- "path-is-absolute: ${${secret[CERT]}[1]}"
    print -r -- "path-basename: ${secret[CERT]:t}"
    print -r -- "file-exists: $([[ -f $secret[CERT] ]] && print yes || print no)"
    print -r -- "file-bytes: $(wc -c < $secret[CERT] | tr -d ' ')"
    print -r -- "binary-bytes: $(wc -c < $secret[BINARY] | tr -d ' ')"
    print -r -- "file-mode: $(zstat +mode -s $secret[CERT] 2>/dev/null || stat -f '%Sp' $secret[CERT])"
    print -r -- "value-arrived: $([[ $secret[token] = plain-token-value ]] && print yes || print no)"
    # Hand the path and the directory out so the suite can inspect both after
    # the request has finished.
    print -rn -- "$secret[CERT]" > ${PROBE_OUT:?}.path
    print -rn -- "$request_dir" > ${PROBE_OUT:?}.dir
    cp $secret[CERT] ${PROBE_OUT:?}.copy
    cp $secret[BINARY] ${PROBE_OUT:?}.binary
}
EOF

cat > $ext/commands/badvalue/command.zsh <<'EOF'
function :help:badvalue { heredoc -v help <<'    HELP'
        # desc -- a multi-line body declared as a value
    HELP
}
function :args:badvalue { eval "$(args -- -- "$@")" }
function :execute:badvalue { dls_execute "$@" }
: ${dls_secrets[badvalue:body]:=Vault/item/multi}
function :dls:badvalue { print -r -- 'badvalue ran' }
EOF

cat > $ext/commands/badnul/command.zsh <<'EOF'
function :help:badnul { heredoc -v help <<'    HELP'
        # desc -- a null-bearing body declared as a value
    HELP
}
function :args:badnul { eval "$(args -- -- "$@")" }
function :execute:badnul { dls_execute "$@" }
: ${dls_secrets[badnul:body]:=Vault/item/nulled}
function :dls:badnul { print -r -- 'badnul ran' }
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
    [[ -S $DLS_SOCKET ]] || {
        print -r -- 'FAIL: server never bound'
        print -r -- "$(cat $home/serve.log 2>/dev/null)"
        exit 1
    }

    typeset out err
    integer code

    out=$(dls holder 2> $home/err)
    code=$?
    assert 'a file secret arrives as an absolute path' 'path-is-absolute: /' "$out"
    assert 'the file is named for its key' 'path-basename: CERT' "$out"
    assert 'the file exists while the command runs' 'file-exists: yes' "$out"
    assert 'a value secret still arrives as a value' 'value-arrived: yes' "$out"

    # The trailing newline is the byte a careless path trims, so it is the one
    # worth counting: the body is 53 bytes and must arrive as 53.
    assert 'the file keeps every byte, trailing newline included' 'file-bytes: 53' "$out"
    assert 'a NUL-bearing file keeps every byte' 'binary-bytes: 9' "$out"
    assert 'the file is not readable by anyone else' 'file-mode: -rw-------' "$out"

    typeset dir=$(cat $PROBE_OUT.dir 2>/dev/null)
    typeset filepath=$(cat $PROBE_OUT.path 2>/dev/null)
    typeset filesroot=${dir:h}

    if printf -- '-----BEGIN CANARY-----\nLINE-ONE\n-----END CANARY-----\n' | cmp -s - $PROBE_OUT.copy; then
        print -r -- 'ok: the bytes are the bytes op returned'
    else
        print -r -- 'FAIL: the materialized file differs from the source'
        (( failures++ ))
    fi

    if printf -- 'head\000tail' | cmp -s - $PROBE_OUT.binary; then
        print -r -- 'ok: binary file bytes survive the cache'
    else
        print -r -- 'FAIL: binary file bytes differ from the source'
        (( failures++ ))
    fi

    # The mechanism, checked rather than assumed: the root cannot be walked
    # while an exact path inside it opens.
    if find $filesroot -type f > /dev/null 2>&1; then
        print -r -- 'FAIL: a recursive sweep entered the files root'
        (( failures++ ))
    else
        print -r -- 'ok: a recursive sweep cannot enter the files root'
    fi

    # The request is over, so its directory is too.
    if [[ -e $dir ]]; then
        print -r -- 'FAIL: the request directory outlived the request'
        (( failures++ ))
    else
        print -r -- 'ok: the request directory does not outlive the request'
    fi

    out=$(dls badvalue 2> $home/err)
    code=$?
    err=$(cat $home/err 2>/dev/null)
    if (( code == 69 )); then
        print -r -- 'ok: a newline in a value fails the resolve'
    else
        print -r -- "FAIL: a newline in a value exited $code, wanted 69"
        (( failures++ ))
    fi
    assert 'the newline refusal names the entry and the remedy' \
        'newline in dls_secrets[badvalue:body]: declare it in dls_files' "$err"

    # `nulled` is already warm from its file delivery above. Decoding that same
    # canonical cache entry as a value must reach the value-shape refusal.
    out=$(dls badnul 2> $home/err)
    code=$?
    err=$(cat $home/err 2>/dev/null)
    if (( code == 69 )); then
        print -r -- 'ok: a null byte in a value fails the resolve'
    else
        print -r -- "FAIL: a null byte in a value exited $code, wanted 69"
        (( failures++ ))
    fi
    assert 'the null refusal names the entry and the remedy' \
        'null byte in dls_secrets[badnul:body]: declare it in dls_files' "$err"

    dls stop > /dev/null 2>&1
} always {
    [[ -S $DLS_SOCKET ]] && dls stop > /dev/null 2>&1
    (( server )) && kill $server 2>/dev/null
    if (( failures )); then
        print -r -- '--- serve.log ---'
        print -r -- "$(cat $home/serve.log 2>/dev/null)"
    fi
    chmod -R u+rwX $home 2>/dev/null
    rm -rf $home
}

if (( failures )); then
    print -r -- "files: $failures failure(s)"
    exit 1
fi
print -r -- 'files: PASS'
