#!/usr/bin/env zsh

# Real OpenPGP, disposable software keys, and a fake provider. This proves the
# data and process boundaries; a physical token ceremony is a separate check.
emulate -L zsh -o pipefail
zmodload zsh/stat

typeset root=${ZSH_ARGZERO:A:h:h}
typeset runner=${ZSHCTL:-$(command -v zshctl)} real_gpg=$(command -v gpg)
typeset real_base64=$(command -v base64)
[[ -n $runner && -n $real_gpg ]] || exit 1
typeset fixture=$(mktemp -d ${TMPDIR:-/tmp}/dls.snapshot.XXXXXX) || exit 1
typeset test_home=$fixture/user key_home=$fixture/keys
typeset snapshot=$test_home/.local/state/dls/snapshot.gpg
typeset socket=$fixture/dls.socket pin other_pin output log before
integer server=0 failures=0 code
mkdir -p -m 700 $test_home/.config/dls $key_home $fixture/bin
touch $fixture/op.log $fixture/gpg.log
print -r -- first > $fixture/generation
printf '\000fixture\nlast\n' > $fixture/binary

function check {
    if "$@"; then
        return 0
    fi
    print -r -- "FAIL: ${(j: :)${(@q)@}}"
    (( failures++ ))
    return 1
}

function run_dls {
    env HOME=$test_home GNUPGHOME=$key_home DLS_SOCKET=$socket \
        PATH=$fixture/bin:$PATH DLS_TEST_FIXTURE=$fixture DLS_TEST_GPG=$real_gpg \
        DLS_TEST_BASE64=$real_base64 \
        DLS_TEST_PROGRESS_FILE=${DLS_TEST_PROGRESS_FILE:-} \
        DLS_TEST_PROGRESS_TOTAL=${DLS_TEST_PROGRESS_TOTAL:-} \
        DLS_TEST_COMPLETE_TOTAL=${DLS_TEST_COMPLETE_TOTAL:-} \
        $runner $root/bin/dls "$@"
}

function configure {
    print -r -- "dls[source]=${2:-snapshot}" > $test_home/.config/dls/config.zsh
    print -r -- "dls[recipient]=$1" >> $test_home/.config/dls/config.zsh
}

function start_server {
    run_dls serve > $fixture/serve.log 2>&1 &
    server=$!
    integer i
    for i in {1..100}; do
        [[ -S $socket ]] && return 0
        kill -0 $server 2>/dev/null || break
        sleep 0.05
    done
    print -r -- 'FAIL: snapshot server did not bind'
    cat $fixture/serve.log
    return 1
}

function stop_server {
    run_dls stop > /dev/null 2>&1
    wait $server 2>/dev/null
    server=0
}

function refuses_start {
    run_dls serve > $fixture/refusal.log 2>&1 &
    server=$!
    integer i
    for i in {1..100}; do
        if [[ -S $socket ]]; then
            stop_server
            print -r -- 'FAIL: invalid snapshot bound a socket'
            return 1
        fi
        kill -0 $server 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 $server 2>/dev/null; then
        kill $server 2>/dev/null
        wait $server 2>/dev/null
        server=0
        return 1
    fi
    wait $server 2>/dev/null
    code=$?
    server=0
    (( code != 0 ))
}

function encrypt_fixture {
    $real_gpg --homedir $key_home --no-options --batch --trust-model always \
        --recipient "${pin}!" --output - --encrypt > $snapshot
    chmod 600 $snapshot
}

# A terminal signals the process group. Also signal only the parent and let the
# child finish successfully: cancellation must still prevent the next read or
# publication. Python owns the isolated group, so the suite itself is untouched.
function interrupt_sync {
    env HOME=$test_home GNUPGHOME=$key_home DLS_SOCKET=$socket \
        PATH=$fixture/bin:$PATH DLS_TEST_FIXTURE=$fixture DLS_TEST_GPG=$real_gpg \
        DLS_TEST_BASE64=$real_base64 DLS_TEST_INTERRUPT=$1 \
        python3 - "$fixture" "$2" "$3" "$runner" "$root/bin/dls" <<'PY'
from pathlib import Path
import os
import signal
import subprocess
import sys
import time

fixture = Path(sys.argv[1])
sig = getattr(signal, 'SIG' + sys.argv[2])
target = sys.argv[3]
stage = os.environ['DLS_TEST_INTERRUPT']
snapshot = Path(os.environ['HOME']) / '.local/state/dls/snapshot.gpg'
before = snapshot.read_bytes()
ready = fixture / 'interrupt-ready'
release = fixture / 'interrupt-release'
for path in (ready, release):
    path.unlink(missing_ok=True)
for name in ('op.log', 'gpg.log'):
    (fixture / name).write_text('')
process = subprocess.Popen(
    [*sys.argv[4:], 'sync'], start_new_session=True,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
try:
    deadline = time.monotonic() + 10
    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    assert ready.exists(), f'{stage}: sync did not reach interruption point'
    if target == 'group':
        os.killpg(process.pid, sig)
    else:
        os.kill(process.pid, sig)
        release.touch()
    out, err = process.communicate(timeout=10)
    context = f'{stage} {sig.name} {target}'
    assert process.returncode == 128 + sig, (context, process.returncode, err)
    calls = (fixture / 'op.log').read_text().splitlines()
    reads = [line for line in calls if line.startswith('read ')]
    signouts = [line for line in calls if line.startswith('signout ')]
    accounts = sorted({line.split('--account ', 1)[1].split()[0] for line in reads})
    assert signouts == [f'signout --account {account}' for account in accounts], (context, calls)
    assert len(reads) == (1 if stage == 'read' else 5), (context, calls)
    if stage == 'read':
        assert not (fixture / 'gpg.log').read_text(), (context, 'GPG called after cancellation')
    assert snapshot.read_bytes() == before, (context, 'old snapshot changed')
    assert not list(snapshot.parent.glob('.dls-snapshot.*')), (context, 'temporary ciphertext remains')
    assert b'wrote complete snapshot' not in out, (context, 'success reported')
    assert not out, (context, 'stdout was not empty', out)
    assert b'dls: reading 1/5 A/Vault/item/binary\n' in err, (context, err)
    if stage == 'read':
        assert b'dls: reading 2/5 ' not in err, (context, 'later read reported', err)
        assert b'dls: encrypting complete snapshot' not in err, (
            context, 'later encryption reported', err)
    else:
        assert b'dls: encrypting complete snapshot with 5 references\n' in err, (
            context, err)
finally:
    # Also reap any fixture descendants if an assertion or timeout interrupted
    # the harness. This group contains only this one disposable sync.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.communicate()
    for path in (ready, release):
        path.unlink(missing_ok=True)
PY
}

# Fill stderr with one accepted reference, signal while its progress write is
# blocked, then drain the pipe. The provider must remain beyond the boundary.
function interrupt_progress {
    DLS_TEST_INTERRUPT= DLS_TEST_PROGRESS_FILE= DLS_TEST_PROGRESS_TOTAL= \
    DLS_TEST_COMPLETE_TOTAL= \
    HOME=$test_home GNUPGHOME=$key_home DLS_SOCKET=$socket \
    DLS_TEST_FIXTURE=$fixture DLS_TEST_GPG=$real_gpg \
    DLS_TEST_BASE64=$real_base64 \
    PATH=$fixture/bin:$PATH \
        python3 - "$fixture" "$1" "$runner" "$root/bin/dls" \
        "$ext/commands/probe/command.zsh" <<'PY'
from pathlib import Path
import os
import select
import signal
import subprocess
import sys
import time

fixture = Path(sys.argv[1])
signum = getattr(signal, 'SIG' + sys.argv[2])
command_path = Path(sys.argv[5])
original = command_path.read_bytes()
reference = 'A/Vault/item/' + ('x' * (2 * 1024 * 1024))
source = f'''function :help:probe {{ help='# desc -- inspect fixture delivery' }}
function :args:probe {{ eval "$(args -C -- "$@")" }}
function :execute:probe {{ dls_execute "$@" }}
dls_secrets[probe:token]={reference}
function :dls:probe {{ : }}
'''.encode()
process = None
observed = bytearray()

try:
    command_path.write_bytes(source)
    (fixture / 'op.log').write_text('')
    (fixture / 'gpg.log').write_text('')
    snapshot = Path(os.environ['HOME']) / '.local/state/dls/snapshot.gpg'
    before = snapshot.read_bytes()
    process = subprocess.Popen(
        [sys.argv[3], sys.argv[4], 'sync'],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    assert process.stderr is not None
    fd = process.stderr.fileno()
    os.set_blocking(fd, False)
    deadline = time.monotonic() + 10
    prefix = b'dls: reading 1/1 A/Vault/item/'
    while prefix not in observed and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                observed.extend(os.read(fd, 65536))
            except BlockingIOError:
                pass
        if process.poll() is not None:
            break
    assert prefix in observed, bytes(observed[-1000:])
    time.sleep(0.1)
    assert process.poll() is None
    assert (fixture / 'op.log').read_text() == ''

    os.kill(process.pid, signum)
    os.set_blocking(fd, True)
    stdout, stderr = process.communicate(timeout=10)
    stderr = bytes(observed) + stderr

    assert process.returncode == 128 + signum, process.returncode
    assert stdout == b'', stdout
    assert (fixture / 'op.log').read_text() == ''
    assert (fixture / 'gpg.log').read_text() == ''
    assert b'dls: encrypting complete snapshot' not in stderr
    _, separator, later = stderr.partition(b'\n')
    assert not later, ('later stderr chatter', later)
    assert snapshot.read_bytes() == before
    assert not list(snapshot.parent.glob('.dls-snapshot.*'))
finally:
    command_path.write_bytes(original)
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
PY
}

cat > $fixture/bin/op <<'EOF'
#!/bin/zsh -f
print -r -- "$*" >> $DLS_TEST_FIXTURE/op.log
if [[ -n ${DLS_TEST_PROGRESS_FILE:-} && $1 = read ]]; then
    integer index=$(command grep -c '^read ' $DLS_TEST_FIXTURE/op.log)
    typeset reference=$3/${${@[-1]}#op://}
    command grep -Fqx -- \
        "dls: reading ${index}/${DLS_TEST_PROGRESS_TOTAL} ${(q)reference}" \
        $DLS_TEST_PROGRESS_FILE || {
        print -r -u 2 -- "progress missing before provider read: ${(q)reference}"
        exit 97
    }
fi
[[ -f $DLS_TEST_FIXTURE/op-fail ]] && exit 1
case $1 in
(read)
    if [[ ${DLS_TEST_INTERRUPT:-} = read ]]; then
        : > $DLS_TEST_FIXTURE/interrupt-ready
        while [[ ! -e $DLS_TEST_FIXTURE/interrupt-release ]]; do sleep 0.02; done
    fi
    case ${@[-1]} in
    (op://Vault/item/token) print -rn -- "$(cat $DLS_TEST_FIXTURE/generation)-token" ;;
    (op://Vault/item/binary) cat $DLS_TEST_FIXTURE/binary ;;
    (op://Vault/item/empty) ;;
    (op://Vault/item/other) print -rn -- 'other-command-value' ;;
    (op://Vault/item/odd*) print -rn -- 'odd-file' ;;
    (*) exit 1 ;;
    esac
    ;;
(signout) ;;
(*) exit 1 ;;
esac
EOF
cat > $fixture/bin/gpg <<'EOF'
#!/bin/zsh -f
if [[ -n ${DLS_TEST_PROGRESS_FILE:-} && " $* " = *' --encrypt '* ]]; then
    typeset noun=references
    (( DLS_TEST_COMPLETE_TOTAL == 1 )) && noun=reference
    command grep -Fqx -- \
        "dls: encrypting complete snapshot with ${DLS_TEST_COMPLETE_TOTAL} $noun" \
        $DLS_TEST_PROGRESS_FILE || {
        print -r -u 2 -- 'encryption progress missing before gpg'
        exit 97
    }
fi
print -r -- "$*" >> $DLS_TEST_FIXTURE/gpg.log
[[ -f $DLS_TEST_FIXTURE/gpg-fail ]] && exit 1
if [[ ${DLS_TEST_INTERRUPT:-} = encrypt && " $* " = *' --encrypt '* ]]; then
    : > $DLS_TEST_FIXTURE/interrupt-ready
    while [[ ! -e $DLS_TEST_FIXTURE/interrupt-release ]]; do sleep 0.02; done
fi
exec $DLS_TEST_GPG "$@"
EOF
chmod +x $fixture/bin/{op,gpg}
cat > $fixture/bin/base64 <<'EOF'
#!/bin/zsh -f
[[ -f $DLS_TEST_FIXTURE/encode-fail && $# = 0 ]] && exit 1
[[ -f $DLS_TEST_FIXTURE/decode-fail && ${1:-} = -d ]] && exit 1
exec $DLS_TEST_BASE64 "$@"
EOF
chmod +x $fixture/bin/base64

typeset ext=$test_home/.local/share/dls/extensions/fixture
mkdir -p $ext/commands/probe
cat > $ext/commands/probe/command.zsh <<'EOF'
function :help:probe { help='# desc -- inspect fixture delivery' }
function :args:probe { eval "$(args -C -- "$@")" }
function :execute:probe { dls_execute "$@" }
dls_secrets[probe:token]=A/Vault/item/token
dls_files[probe:binary]=A/Vault/item/binary
dls_files[probe:empty]=A/Vault/item/empty
dls_files[probe:tokenfile]=A/Vault/item/token
dls_files[probe:odd]=$'A/Vault/item/odd\tline\nfield'
# Orphan declarations remain inventory; no new command-existence rule.
dls_secrets[other:value]=B/Vault/item/other
function :dls:probe {
    (( ${#secret} == 5 )) || return 1
    [[ ! -v _dls_cache && ! -v _dls_masks && ! -v _dls_document && ! -v _dls_loaded ]] || return 2
    cmp -s "$secret[binary]" $DLS_TEST_FIXTURE/binary || return 3
    [[ ! -s $secret[empty] && $(cat "$secret[odd]") = odd-file ]] || return 4
    [[ $(cat "$secret[tokenfile]") = "$secret[token]" ]] || return 5
    [[ $secret[token] = "${1:-first}-token" ]] || return 6
    print -r -- "$secret[token]"
}
EOF

{
    # Two keys let a wrong-key test decrypt successfully in GPG and still fail
    # DLS's expected-key check. No real keyring or card is consulted.
    for name in one two; do
        $real_gpg --homedir $key_home --batch --pinentry-mode loopback \
            --passphrase '' --quick-generate-key "DLS fixture $name <${name}@example.invalid>" \
            ed25519 cert 0 > /dev/null 2>&1 || exit 1
        typeset primary=$($real_gpg --homedir $key_home --with-colons --list-keys \
            "${name}@example.invalid" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
        $real_gpg --homedir $key_home --batch --pinentry-mode loopback --passphrase '' \
            --quick-add-key $primary cv25519 encr 0 > /dev/null 2>&1 || exit 1
    done
    pin=$($real_gpg --homedir $key_home --with-colons --list-keys one@example.invalid \
        2>/dev/null | awk -F: '$1 == "sub" {subkey=1} $1 == "fpr" && subkey {print $10; exit}')
    other_pin=$($real_gpg --homedir $key_home --with-colons --list-keys two@example.invalid \
        2>/dev/null | awk -F: '$1 == "sub" {subkey=1} $1 == "fpr" && subkey {print $10; exit}')
    [[ -n $pin && -n $other_pin ]] || exit 1
    configure $pin

    DLS_TEST_PROGRESS_FILE=$fixture/sync.err DLS_TEST_PROGRESS_TOTAL=5 \
        DLS_TEST_COMPLETE_TOTAL=5 \
        run_dls sync > $fixture/sync.out 2> $fixture/sync.err || {
        cat $fixture/sync.err; exit 1
    }
    output=$(<$fixture/sync.out)
    check test "$output" = \
        "dls: wrote complete snapshot: $snapshot"$'\n'\
"dls: a running server keeps its loaded values until stopped and started again"
    typeset -a progress_refs=(
        A/Vault/item/binary
        A/Vault/item/empty
        $'A/Vault/item/odd\tline\nfield'
        A/Vault/item/token
        B/Vault/item/other
    ) expected_progress=()
    integer progress_index=0
    typeset progress_ref
    for progress_ref in "${(@)progress_refs}"; do
        (( progress_index++ ))
        expected_progress+=(
            "dls: reading ${progress_index}/5 ${(q)progress_ref}"
        )
    done
    expected_progress+=( 'dls: encrypting complete snapshot with 5 references' )
    check test "$(<$fixture/sync.err)" = "${(F)expected_progress}"
    check test -s $snapshot
    log=$(<$fixture/op.log)
    check test ${#${(M)${(f)log}:#read *}} -eq 5
    check test ${#${(M)${(f)log}:#signout *}} -eq 2
    log=$(<$fixture/gpg.log)
    check test ${#${(M)${(f)log}:#*--decrypt*}} -eq 0
    typeset -A info
    zstat -H info $snapshot
    check test $(( info[mode] & 8#777 )) -eq $(( 8#600 ))
    zstat -H info ${snapshot:h}
    check test $(( info[mode] & 8#777 )) -eq $(( 8#700 ))

    before=$(cksum $fixture/op.log $fixture/gpg.log)
    output=$(run_dls __complete /dev/null 3 dls sync '' 3) || exit 1
    check test "$before" = "$(cksum $fixture/op.log $fixture/gpg.log)"
    check test "${output#*A/Vault/item/token}" != "$output"
    check test "${output#*B/Vault/item/other}" != "$output"
    typeset -a completions
    typeset -A settings descriptions
    eval "$output"
    integer odd_completed=0
    typeset completed
    for completed in "${(@)completions}"; do
        [[ $completed = $'A/Vault/item/odd\tline\nfield' ]] && odd_completed=1
    done
    check test $odd_completed -eq 1
    run_dls sync A/Vault/item/undeclared > /dev/null 2>&1
    check test $? -ne 0
    check test "$before" = "$(cksum $fixture/op.log $fixture/gpg.log)"

    start_server || exit 1
    output=$(run_dls probe first) || exit 1
    check test "$output" = '<concealed by dls>'
    output=$(run_dls status)
    check test "${output#*source: snapshot}" != "$output"
    check test "${output#*loaded at startup}" != "$output"
    check test "${output#*B/Vault/item/other}" != "$output"

    print -r -- second > $fixture/generation
    : > $fixture/op.log
    : > $fixture/gpg.log
    DLS_TEST_PROGRESS_FILE=$fixture/sync.err DLS_TEST_PROGRESS_TOTAL=1 \
        DLS_TEST_COMPLETE_TOTAL=5 \
        run_dls sync -- A/Vault/item/token A/Vault/item/token \
            > $fixture/sync.out 2> $fixture/sync.err || {
        cat $fixture/sync.err; exit 1
    }
    output=$(<$fixture/sync.out)
    check test "$output" = \
        "dls: wrote complete snapshot: $snapshot"$'\n'\
"dls: a running server keeps its loaded values until stopped and started again"
    check test "$(<$fixture/sync.err)" = \
        'dls: decrypting synchronized secrets; touch the Nitrokey'$'\n'\
'dls: decryption complete'$'\n'\
'dls: reading 1/1 A/Vault/item/token'$'\n'\
'dls: encrypting complete snapshot with 5 references'
    log=$(<$fixture/op.log)
    check test ${#${(M)${(f)log}:#read *}} -eq 1
    check test ${#${(M)${(f)log}:#signout *}} -eq 1
    log=$(<$fixture/gpg.log)
    check test ${#${(M)${(f)log}:#*--decrypt*}} -eq 1
    check test ${#${(M)${(f)log}:#*--encrypt*}} -eq 1
    check run_dls probe first
    stop_server
    start_server || exit 1
    check run_dls probe second
    stop_server

    # A failed read or encryption never replaces the last usable artifact.
    before=$(cksum $snapshot)
    touch $fixture/op-fail
    run_dls sync > $fixture/failure.out 2> $fixture/failure.err
    check test $? -ne 0
    check test "$before" = "$(cksum $snapshot)"
    check test ! -s $fixture/failure.out
    check command grep -Fqx -- \
        'dls: reading 1/5 A/Vault/item/binary' $fixture/failure.err
    check test "${$(<$fixture/failure.err)#*'dls: reading 2/5 '}" = \
        "$(<$fixture/failure.err)"
    check test "${$(<$fixture/failure.err)#*'dls: encrypting complete snapshot'}" = \
        "$(<$fixture/failure.err)"
    rm $fixture/op-fail
    touch $fixture/gpg-fail
    run_dls sync > $fixture/failure.out 2> $fixture/failure.err
    check test $? -ne 0
    check test "$before" = "$(cksum $snapshot)"
    check test ! -s $fixture/failure.out
    check command grep -Fqx -- \
        'dls: encrypting complete snapshot with 5 references' $fixture/failure.err
    rm $fixture/gpg-fail

    # Failure during store preparation is still before the encryption boundary.
    mkdir -m 700 $fixture/not-a-file
    print -r -- "dls[snapshot]=$fixture/not-a-file" >> $test_home/.config/dls/config.zsh
    : > $fixture/gpg.log
    : > $fixture/op.log
    run_dls sync > $fixture/prep.out 2> $fixture/prep.err
    check test $? -ne 0
    check test ! -s $fixture/prep.out
    check test "$before" = "$(cksum $snapshot)"
    check test "${$(<$fixture/prep.err)#*'dls: encrypting complete snapshot'}" = \
        "$(<$fixture/prep.err)"
    log=$(<$fixture/gpg.log)
    check test ${#${(M)${(f)log}:#*--encrypt*}} -eq 0
    configure $pin

    touch $fixture/encode-fail
    : > $fixture/op.log
    run_dls sync > /dev/null 2>&1
    check test $? -ne 0
    check test "$before" = "$(cksum $snapshot)"
    log=$(<$fixture/op.log)
    check test ${#${(M)${(f)log}:#signout *}} -eq 1
    rm $fixture/encode-fail
    check test ${#${(f)"$(find ${snapshot:h} -name '.dls-snapshot.*')"}} -eq 0

    typeset stage signal target
    for stage in read encrypt; do
        for signal in INT TERM; do
            for target in group parent; do
                check interrupt_sync $stage $signal $target
            done
        done
    done
    for signal in INT TERM; do
        check interrupt_progress $signal
    done

    cp $snapshot $fixture/good.gpg
    touch $fixture/decode-fail
    check refuses_start
    rm $fixture/decode-fail
    configure $other_pin
    check refuses_start
    configure $pin
    printf 'broken ciphertext' > $snapshot
    check refuses_start
    cp $fixture/good.gpg $snapshot
    python3 - "$snapshot" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = bytearray(p.read_bytes())
data[-1] ^= 1
p.write_bytes(data)
PY
    check refuses_start
    cp $fixture/good.gpg $snapshot

    # Keep invalid plaintext fixtures in memory or pipes. Each is encrypted with
    # the accepted key so the failure is the document's, not GPG's.
    typeset document=$($real_gpg --homedir $key_home --batch --decrypt $snapshot 2>/dev/null)
    document+=$'\n'
    typeset first_record=${${document#$'DLS-SNAPSHOT 1\n'}%%$'\n'*}
    typeset bad
    for bad in \
        "${document/DLS-SNAPSHOT 1/DLS-SNAPSHOT 2}" \
        "${document}${first_record}"$'\n' \
        "${document%$'\n'}" \
        $'DLS-SNAPSHOT 1\n' \
        $'DLS-SNAPSHOT 1\n!!!!\tYQ==\n' \
        $'DLS-SNAPSHOT 1\nQQ==\tYR==\n'; do
        print -rn -- "$bad" | encrypt_fixture || exit 1
        check refuses_start
        before=$(cksum $fixture/op.log)
        run_dls sync A/Vault/item/token > /dev/null 2>&1
        check test $? -ne 0
        check test "$before" = "$(cksum $fixture/op.log)"
    done
    cp $fixture/good.gpg $snapshot
    print -r -- 'dls_secrets[extra:value]=A/Vault/item/new' >> $test_home/.config/dls/config.zsh
    check refuses_start
    configure $pin
    cp $ext/commands/probe/command.zsh $fixture/command.zsh
    print -r -- 'dls_secrets[other:value]=B/Vault/item/replacement' >> $ext/commands/probe/command.zsh
    check refuses_start
    cp $fixture/command.zsh $ext/commands/probe/command.zsh
    rm $snapshot
    before=$(cksum $fixture/op.log)
    run_dls sync A/Vault/item/token > /dev/null 2>&1
    check test $? -ne 0
    check test "$before" = "$(cksum $fixture/op.log)"
    cp $fixture/good.gpg $snapshot

    # Artifact presence never enrolls an op-mode server or causes a decrypt.
    configure $pin op
    : > $fixture/gpg.log
    start_server || exit 1
    output=$(run_dls status)
    check test "${output#*source: op}" != "$output"
    check test "${output#*'cached: (none)'}" != "$output"
    check test ! -s $fixture/gpg.log
    stop_server

    # A one-entry inventory uses singular grammar for the complete artifact.
    cat > $ext/commands/probe/command.zsh <<'EOF'
function :help:probe { help='# desc -- inspect fixture delivery' }
function :args:probe { eval "$(args -C -- "$@")" }
function :execute:probe { dls_execute "$@" }
dls_secrets[probe:token]=A/Vault/item/token
function :dls:probe { : }
EOF
    : > $fixture/op.log
    : > $fixture/gpg.log
    DLS_TEST_PROGRESS_FILE=$fixture/singular.err DLS_TEST_PROGRESS_TOTAL=1 \
        DLS_TEST_COMPLETE_TOTAL=1 \
        run_dls sync > $fixture/singular.out 2> $fixture/singular.err || {
        cat $fixture/singular.err; exit 1
    }
    check test "$(<$fixture/singular.err)" = \
        'dls: reading 1/1 A/Vault/item/token'$'\n'\
'dls: encrypting complete snapshot with 1 reference'
    check test "$(<$fixture/singular.out)" = \
        "dls: wrote complete snapshot: $snapshot"$'\n'\
"dls: a running server keeps its loaded values until stopped and started again"
} always {
    if (( server )); then
        run_dls stop >/dev/null 2>&1
        kill $server 2>/dev/null
        wait $server 2>/dev/null
    fi
    gpgconf --homedir $key_home --kill all >/dev/null 2>&1
    [[ ! -d $fixture/files ]] || chmod 700 $fixture/files
    rm -rf $fixture
}
(( failures == 0 )) || exit 1
print -r -- 'snapshot: PASS'
