#!/usr/bin/env zsh

# One generic application owns record parsing, selection, renewal, and expiry.
emulate -L zsh
unset CODEX_VERSION CLAUDECODE
typeset root=${ZSH_ARGZERO:A:h:h}
typeset runner=${ZSHCTL:-$(command -v zshctl)}
[[ -n $runner ]] || exit 1

python3 - "$root" "$runner" <<'PY'
import base64
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root, runner = sys.argv[1:]
gpg, real_mv = shutil.which('gpg'), shutil.which('mv')
assert gpg and real_mv
with tempfile.TemporaryDirectory(prefix='dls.admission.') as temporary:
    fixture = Path(temporary)
    home, keys, tools = (fixture / name for name in ('home', 'keys', 'bin'))
    for directory in (home / '.config/dls', keys, tools):
        directory.mkdir(parents=True, mode=0o700)
    address = fixture / 'broker.socket'
    token_path = home / '.local/state/dls/tokens.gpg'
    env = dict(os.environ, HOME=str(home), GNUPGHOME=str(keys),
               DLS_SOCKET=str(address), PATH=f'{tools}:{os.environ["PATH"]}',
               DLS_TEST_FIXTURE=str(fixture), DLS_TEST_GPG=gpg, DLS_TEST_MV=real_mv)
    command = [runner, str(Path(root) / 'bin/dls')]
    server = log_file = None
    for name, value in (('epoch', '0'), ('renewals', ''), ('islands', ''), ('hooks', '')):
        (fixture / name).write_text(value)

    (tools / 'op').write_text('''#!/bin/zsh -f
case $1 in
(read)
    case ${@[-1]} in
    (*/prefix) print -rn -- access_one ;;
    (*/document) print -r -- 'fixture file' ;;
    (*) exit 99 ;;
    esac ;;
(signout) ;;
(*) exit 99 ;;
esac
''')
    (tools / 'gpg').write_text('''#!/bin/zsh -f
if [[ " $* " = *' --encrypt '* ]]; then
    [[ ! -e $DLS_TEST_FIXTURE/fail-encrypt ]] || exit 1
fi
exec $DLS_TEST_GPG "$@"
''')
    (tools / 'mv').write_text('''#!/bin/zsh -f
[[ ! -e $DLS_TEST_FIXTURE/fail-rename ]] || exit 1
exec $DLS_TEST_MV "$@"
''')
    # Reject reuse of an old record, just as a rotating application might.
    # Everything here is fixture data in a disposable home.
    (tools / 'fixture-provider').write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time
fixture = Path(os.environ['DLS_TEST_FIXTURE'])
record = sys.stdin.read()
identity, generation = record.split(':')
expected = fixture / ('expected-' + identity)
assert record == expected.read_text(), 'stale record reused'
time.sleep(0.1)
replacement = f'{identity}:{int(generation) + 1}'
expected.write_text(replacement)
with (fixture / 'renewals').open('a') as output:
    output.write(record + '\\n')
sys.stdout.write(replacement + '\\naccess_' + replacement.replace(':', '_'))
''')
    for path in tools.iterdir():
        path.chmod(0o700)

    extension = home / '.local/share/dls/extensions/fixture'
    commands = extension / 'commands'
    for name in ('store', 'use', 'probe', 'inspect'):
        (commands / name).mkdir(parents=True)
    (extension / 'functions').mkdir()
    (extension / 'functions/fixture_exchange').write_text('''
emulate -L zsh -o pipefail
builtin print -rn -- "$1" | command fixture-provider
''')
    (commands / 'store/command.zsh').write_text('''
function :help:store { help='# desc -- store a fixture record' }
function :args:store { eval "$(args -C -- "$@")" }
function :execute:store { dls_token_put "$@" }
''')
    # This helper checks both broad maps and the narrower transient locals.
    (extension / 'functions/fixture_island').write_text('''
emulate -L zsh
typeset variable
for variable in _dls_cache _dls_masks _dls_tokens _dls_token_states \
        _dls_selected _dls_next_tokens _dls_loaded_tokens _dls_record \
        _dls_document _dls_frame _dls_encoded _dls_keyed token_state \
        _dls_admission_active record response error access; do
    [[ ! -v $variable ]] || { print -u 2 -- "inherited $variable"; return 91; }
done
dls_token_select fixture one && return 92
dls_token_replace unavailable && return 93
dls_admit unavailable unavailable && return 94
return 0
''')
    (commands / 'probe/command.zsh').write_text('''
function :help:probe { help='# desc -- check an unrelated command' }
function :args:probe { eval "$(args -C -- "$@")" }
function :execute:probe { dls_execute "$@" }
function :dls:probe {
    fixture_island || return $?
    (( ${#secret} == 0 )) || return 95
    print -r -- access_one_1
}
''')
    (commands / 'inspect/command.zsh').write_text(r'''
function :help:inspect { help='# desc -- check opaque selected bytes' }
function :args:inspect { eval "$(args -C -- "$@")" }
function :execute:inspect { dls_execute "$@" }
function :admit:inspect {
    dls_token_select another one || return $?
    [[ $REPLY = $'unrelated\x00opaque\nrecord' ]] || return 65
    if [[ $1 = cold ]]; then
        [[ -z $token_state ]] || return 66
    else
        [[ $token_state = $'runtime\x00opaque\nstate\n' ]] || return 67
    fi
    token_state=$'runtime\x00opaque\nstate\n'
    dls_admit proof verified
}
function :dls:inspect {
    fixture_island || return $?
    (( ${#secret} == 1 )) && [[ $secret[proof] = verified ]] || return 98
    print -r -- inspected
}
''')
    use_path = commands / 'use/command.zsh'
    use_source = r'''
function :help:use { help='# desc -- use one fixture identity' }
function :args:use { eval "$(args -C -- "$@")" }
function :execute:use { dls_execute "$@" }
function :admit:use {
    emulate -L zsh
    # Identity is the second argument. Selection is application code.
    [[ $# = 3 && $1 = run ]] || return 64
    print -r -- called >> $DLS_TEST_FIXTURE/hooks
    dls_token_select fixture "$2" || return $?
    typeset record=$REPLY response error access epoch=$(<$DLS_TEST_FIXTURE/epoch)
    case $3 in
    (second) dls_token_select fixture two; return 0 ;;
    (empty-record) dls_token_replace ''; return 0 ;;
    (large-record) dls_token_replace "${(pl:65537::x:)}"; return 0 ;;
    (newline) dls_admit bad $'invalid\nvalue'; return 0 ;;
    (null) dls_admit bad $'invalid\x00value'; return 0 ;;
    (collision) dls_admit prefix invalid; return 0 ;;
    esac
    if [[ -z $token_state || ${token_state%%:*} != $epoch ]]; then
        pocket response error fixture_exchange "$record" || return 69
        record=${response%%$'\n'*}
        access=${response#*$'\n'}
        [[ $record = "$2":<-> && $access = access_* ]] || return 65
        dls_token_replace "$record" || return $?
        token_state="$epoch:$access"
    fi
    access=${token_state#*:}
    # Neither stream nor REPLY may escape the private parent call.
    print -r -- "hook-output:$record:$access"
    print -r -u 2 -- "hook-error:$record:$access"
    REPLY="hook-reply:$record:$access"
    [[ $3 != fail ]] || return 42
    dls_admit token "$access" || return $?
    dls_admit other "${access}_longer" || return $?
}
function :dls:use {
    fixture_island || return $?
    (( ${#secret} == 4 )) || return 96
    [[ $(<$secret[document]) = 'fixture file' ]] || return 97
    print -r -- "$2" >> $DLS_TEST_FIXTURE/islands
    print -r -- "$2:$secret[token]:$secret[other]:$secret[prefix]"
    print -r -u 2 -- "$secret[token]"
}
'''
    use_path.write_text(use_source)

    def run(*args, data=None, code=0):
        result = subprocess.run([*command, *args], input=data, capture_output=True,
                                env=env, timeout=15)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr,
                                          (fixture / 'server.log').read_text()[-3000:])
        return result

    def start():
        global server, log_file
        log_file = (fixture / 'server.log').open('wb')
        server = subprocess.Popen([*command, 'serve'], env=env, stdout=log_file,
                                  stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 8
        while not address.exists() and server.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        assert address.exists() and server.poll() is None, (fixture / 'server.log').read_text()
        run('status')

    def stop():
        global server
        run('stop')
        assert server.wait(timeout=5) == 0
        server = None
        log_file.close()
        assert 'hook-' not in (fixture / 'server.log').read_text()

    def put(identity, value, application='fixture', code=0):
        run('store', application, identity, data=value, code=code)
        if code == 0 and application == 'fixture':
            (fixture / ('expected-' + identity)).write_bytes(value)

    def renewals():
        return (fixture / 'renewals').read_text().splitlines()

    def stored():
        plaintext = subprocess.run([gpg, '--homedir', str(keys), '--batch', '--decrypt',
                                    str(token_path)], capture_output=True, check=True).stdout
        assert plaintext.startswith(b'DLS-TOKENS 1\n')
        return {tuple(map(base64.b64decode, fields[:2])): base64.b64decode(fields[2])
                for line in plaintext.splitlines()[1:] for fields in [line.split(b'\t')]}

    def use(identity='one', mode='normal', code=0):
        before = (fixture / 'islands').read_bytes()
        result = run('use', 'run', identity, mode, code=code)
        if code:
            assert result.stdout == b''
            assert result.stderr == b'dls: request admission failed; verify extension state and token storage\n'
            assert (fixture / 'islands').read_bytes() == before, 'failed admission launched island'
            files = fixture / 'files'
            files.chmod(0o700)
            assert not list(files.iterdir()), 'failed admission retained request files'
            files.chmod(0o300)
        else:
            assert result.stdout == identity.encode() + b':<concealed by dls>:<concealed by dls>:<concealed by dls>\n'
            assert result.stderr == b'<concealed by dls>\n'
        return result

    try:
        subprocess.run([gpg, '--homedir', str(keys), '--batch', '--pinentry-mode', 'loopback',
                        '--passphrase', '', '--quick-generate-key',
                        'Admission fixture <admission@example.invalid>', 'ed25519', 'cert', '0'],
                       capture_output=True, check=True)
        listing = subprocess.run([gpg, '--homedir', str(keys), '--with-colons', '--list-keys'],
                                 capture_output=True, check=True).stdout.decode().splitlines()
        primary = next(line.split(':')[9] for line in listing if line.startswith('fpr:'))
        subprocess.run([gpg, '--homedir', str(keys), '--batch', '--pinentry-mode', 'loopback',
                        '--passphrase', '', '--quick-add-key', primary, 'cv25519', 'encr', '0'],
                       capture_output=True, check=True)
        listing = subprocess.run([gpg, '--homedir', str(keys), '--with-colons', '--list-keys'],
                                 capture_output=True, check=True).stdout.decode().splitlines()
        pin = [line.split(':')[9] for line in listing if line.startswith('fpr:')][-1]
        (home / '.config/dls/config.zsh').write_text(
            f'dls[source]=op\ndls[recipient]={pin}\n'
            'dls_secrets[use:prefix]=Test/Vault/Fixture/prefix\n'
            'dls_files[use:document]=Test/Vault/Fixture/document\n')
        start()
        put('one', b'one:0')
        put('two', b'two:0')
        put('one', b'unrelated\x00opaque\nrecord', application='another')
        before = token_path.read_bytes()
        assert run('inspect', 'cold').stdout == b'inspected\n'
        assert run('inspect', 'warm').stdout == b'inspected\n'
        assert token_path.read_bytes() == before, 'runtime state entered durable storage'
        use('missing', code=69)
        for mode in ('second', 'empty-record', 'large-record', 'newline', 'null', 'collision'):
            use(mode=mode, code=69)
        assert not renewals()
        assert run('probe').stdout == b'access_one_1\n'

        use()
        use()
        assert renewals() == ['one:0'], 'warm state was lost after the request'
        use('two')
        assert renewals() == ['one:0', 'two:0'], 'identity selection was ignored'
        assert stored() == {(b'fixture', b'one'): b'one:1', (b'fixture', b'two'): b'two:1',
                            (b'another', b'one'): b'unrelated\x00opaque\nrecord'}
        assert run('probe').stdout == b'access_one_1\n', 'unrelated values became masks'

        # The parent retains one completed renewal for subsequent requests.
        (fixture / 'epoch').write_text('1')
        use()
        use()
        assert renewals().count('one:1') == 1
        assert stored()[b'fixture', b'one'] == b'one:2'

        # A replacement survives both encryption and publication failure.
        # Retry must publish before reentering extension code; an old record
        # would be rejected by the fake provider if it were ever retried.
        for epoch, failure in ((2, 'fail-encrypt'), (3, 'fail-rename')):
            (fixture / 'epoch').write_text(str(epoch))
            before = token_path.read_bytes()
            (fixture / failure).touch()
            use(code=69)
            count = len(renewals())
            hook_count = (fixture / 'hooks').read_bytes()
            use(code=69)
            assert len(renewals()) == count
            assert (fixture / 'hooks').read_bytes() == hook_count
            assert token_path.read_bytes() == before
            assert not list(token_path.parent.glob('.dls-token-bundle.*'))
            assert run('probe').stdout == b'access_one_1\n'
            (fixture / failure).unlink()
            use()
            assert len(renewals()) == count, 'failed publication lost warm state'
            assert stored()[b'fixture', b'one'] == (fixture / 'expected-one').read_bytes()

        # Even a later hook failure cannot undo a completed provider rotation.
        (fixture / 'epoch').write_text('4')
        use(mode='fail', code=69)
        count = len(renewals())
        use()
        assert len(renewals()) == count
        assert stored()[b'fixture', b'one'] == (fixture / 'expected-one').read_bytes()

        # A foreground merge can publish pending replacements without losing
        # their runtime state or giving the submitter a broad map to replace.
        (fixture / 'epoch').write_text('pending')
        (fixture / 'fail-encrypt').touch()
        use(code=69)
        count = len(renewals())
        (fixture / 'fail-encrypt').unlink()
        put('three', b'three:0')
        assert stored()[b'fixture', b'one'] == (fixture / 'expected-one').read_bytes()
        use()
        assert len(renewals()) == count

        # Foreground enrollment invalidates its own state, not another record.
        use('two')
        put('one', b'one:20')
        count = len(renewals())
        use('two')
        assert len(renewals()) == count
        use()
        assert renewals()[-1] == 'one:20'
        (fixture / 'fail-encrypt').touch()
        put('one', b'one:30', code=74)
        (fixture / 'fail-encrypt').unlink()
        count = len(renewals())
        use()
        assert len(renewals()) == count, 'failed put invalidated runtime state'

        # Hook and helper bodies obey the same restart gate as command bodies.
        use_path.write_text(use_source.replace('dls_token_select fixture "$2"', 'return 71'))
        (extension / 'functions/fixture_exchange').write_text('return 72\n')
        (fixture / 'epoch').write_text('5')
        use()
        stop()
        start()
        use(code=69)
        stop()
        use_path.write_text(use_source)
        (extension / 'functions/fixture_exchange').write_text(
            'emulate -L zsh -o pipefail\nbuiltin print -rn -- "$1" | command fixture-provider\n')
        start()
        assert run('inspect', 'cold').stdout == b'inspected\n'
        count = len(renewals())
        use()
        assert len(renewals()) == count + 1, 'runtime state survived restart'
        assert stored()[b'fixture', b'one'] == (fixture / 'expected-one').read_bytes()
        stop()
        print('admission: PASS')
    finally:
        if server is not None:
            try:
                subprocess.run([*command, 'stop'], env=env, capture_output=True, timeout=7)
            except subprocess.TimeoutExpired:
                pass
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=5)
            log_file.close()
        subprocess.run(['gpgconf', '--homedir', str(keys), '--kill', 'all'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        files = fixture / 'files'
        if files.exists():
            files.chmod(0o700)
PY
