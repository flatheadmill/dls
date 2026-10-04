#!/usr/bin/env zsh

# Custody only: one generic extension, opaque records, disposable software keys.
emulate -L zsh
unset CODEX_VERSION CLAUDECODE
typeset root=${ZSH_ARGZERO:A:h:h}
typeset runner=${ZSHCTL:-$(command -v zshctl)}
[[ -n $runner ]] || exit 1

python3 - "$root" "$runner" <<'PY'
import base64
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

root, runner = sys.argv[1:]
gpg, real_mv = shutil.which('gpg'), shutil.which('mv')
assert gpg and real_mv, 'gpg and mv are required'


def b64(value):
    return base64.b64encode(value)


def row(app, identity, value):
    return b'\t'.join(map(b64, (app, identity, value))) + b'\n'


def frame(app, identity, value):
    return b'DLS-TOKEN 1\n' + row(app, identity, value)


with tempfile.TemporaryDirectory(prefix='dls.tokens.') as temporary:
    fixture = Path(temporary)
    home, keys, tools = (fixture / name for name in ('home', 'keys', 'bin'))
    for directory in (home / '.config/dls', keys, tools):
        directory.mkdir(parents=True, mode=0o700)
    config = home / '.config/dls/config.zsh'
    token_path = home / '.local/state/dls/tokens.gpg'
    address = fixture / 'broker.socket'
    env = dict(os.environ, HOME=str(home), GNUPGHOME=str(keys),
               DLS_SOCKET=str(address), PATH=f'{tools}:{os.environ["PATH"]}',
               DLS_TEST_FIXTURE=str(fixture), DLS_TEST_GPG=gpg, DLS_TEST_MV=real_mv)
    command = [runner, str(Path(root) / 'bin/dls')]
    gpg_log = fixture / 'gpg.log'
    gpg_log.touch()
    server = None
    log_file = None
    counter = 0

    (tools / 'op').write_text('#!/bin/zsh -f\nexit 99\n')
    (tools / 'gpg').write_text('''#!/bin/zsh -f
print -r -- "$*" >> $DLS_TEST_FIXTURE/gpg.log
if [[ " $* " = *' --encrypt '* ]]; then
    [[ ! -e $DLS_TEST_FIXTURE/fail-encrypt ]] || exit 1
    if [[ -e $DLS_TEST_FIXTURE/hold-encrypt ]]; then
        : > $DLS_TEST_FIXTURE/encrypt-ready
        while [[ ! -e $DLS_TEST_FIXTURE/release-encrypt ]]; do sleep 0.02; done
    fi
fi
exec $DLS_TEST_GPG "$@"
''')
    (tools / 'mv').write_text('''#!/bin/zsh -f
[[ ! -e $DLS_TEST_FIXTURE/fail-rename ]] || exit 1
exec $DLS_TEST_MV "$@"
''')
    for path in tools.iterdir():
        path.chmod(0o700)

    extension = home / '.local/share/dls/extensions/fixture/commands'
    for name in ('store', 'probe'):
        (extension / name).mkdir(parents=True)
    (extension / 'store/command.zsh').write_text('''
function :help:store { help='# desc -- store one opaque fixture record' }
function :args:store { eval "$(args -C -- "$@")" }
function :execute:store { dls_token_put "$@" }
''')
    (extension / 'probe/command.zsh').write_text('''
function :help:probe { help='# desc -- check the request island' }
function :args:probe { eval "$(args -C -- "$@")" }
function :execute:probe { dls_execute "$@" }
function :dls:probe {
    [[ ! -v _dls_tokens && ! -v _dls_cache && ! -v _dls_masks &&
       ! -v _dls_next_tokens && ! -v _dls_loaded_tokens &&
       ! -v _dls_frame && ! -v _dls_document ]] || return 91
    (( ${#secret} == 0 )) || return 92
    print -r -- island
}
''')

    def run(*args, data=None, code=0, timeout=15):
        result = subprocess.run([*command, *args], input=data, capture_output=True,
                                env=env, timeout=timeout)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr,
                                          (fixture / 'server.log').read_text()[-3000:])
        return result

    def wait_for(predicate, timeout=8):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            if predicate():
                return
            time.sleep(0.02)
        raise AssertionError('fixture deadline expired')

    def start(refuse=False):
        global server, log_file
        log_file = (fixture / 'server.log').open('wb')
        server = subprocess.Popen([*command, 'serve'], env=env, stdout=log_file,
                                  stderr=subprocess.STDOUT, start_new_session=True)
        try:
            wait_for(lambda: address.exists() or server.poll() is not None)
        except AssertionError:
            raise AssertionError((fixture / 'server.log').read_text()) from None
        if refuse:
            assert not address.exists(), 'invalid token bundle bound a socket'
            assert server.wait(timeout=5) != 0
            server = None
            log_file.close()
        else:
            assert server.poll() is None, (fixture / 'server.log').read_text()
            run('status')

    def stop():
        global server
        run('stop')
        assert server.wait(timeout=5) == 0
        server = None
        log_file.close()

    def stored(expected):
        plaintext = subprocess.run([gpg, '--homedir', str(keys), '--batch', '--decrypt',
                                    str(token_path)], capture_output=True, check=True).stdout
        assert plaintext.startswith(b'DLS-TOKENS 1\n')
        actual = {}
        for line in plaintext.splitlines()[1:]:
            app, identity, value = map(base64.b64decode, line.split(b'\t'))
            assert (app, identity) not in actual
            actual[app, identity] = value
        assert actual == expected, 'stored records differ'

    def encrypt(document):
        result = subprocess.run([gpg, '--homedir', str(keys), '--no-options', '--batch',
                                 '--trust-model', 'always', '--recipient', pin + '!',
                                 '--output', '-', '--encrypt'], input=document,
                                capture_output=True, check=True)
        token_path.write_bytes(result.stdout)
        token_path.chmod(0o600)

    def raw_put(payload, *, hold=False, die=False, private=True):
        """Exercise the wire boundary independently of the foreground helper."""
        global counter
        counter += 1
        directory = fixture / f'ingress-{counter}'
        directory.mkdir(mode=0o700)
        paths = [directory / name for name in ('out', 'err', 'in')]
        for path in paths:
            os.mkfifo(path, 0o600)
        if not private:
            paths[2].chmod(0o644)
        outputs = [os.open(path, os.O_RDONLY | os.O_NONBLOCK) for path in paths[:2]]
        release = threading.Event()
        producer = None
        started = time.monotonic()
        try:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(8)
                connection.connect(str(address))
                words = ['token-put', '-', str(fixture), *(str(path) for path in paths)]
                connection.sendall((' '.join(map(shlex.quote, words)) + '\n').encode())
                if payload is not None:
                    if die:
                        producer = subprocess.Popen([sys.executable, '-c', '''
import os, signal, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.write(fd, sys.stdin.buffer.read())
os.kill(os.getpid(), signal.SIGKILL)
''', str(paths[2])], stdin=subprocess.PIPE)
                        producer.stdin.write(payload)
                        producer.stdin.close()
                    else:
                        def write():
                            try:
                                with paths[2].open('wb', buffering=0) as output:
                                    view = memoryview(payload)
                                    while view:
                                        view = view[output.write(view):]
                                    if hold:
                                        release.wait(10)
                            except BrokenPipeError:
                                pass
                        producer = threading.Thread(target=write, daemon=True)
                        producer.start()
                response = b''
                while part := connection.recv(1024):
                    response += part
                output, error = (os.read(fd, 65536) for fd in outputs)
                return response, output, error, time.monotonic() - started
        finally:
            release.set()
            if isinstance(producer, threading.Thread):
                producer.join(timeout=2)
                assert not producer.is_alive(), 'producer retained a FIFO endpoint'
            elif producer:
                assert producer.wait(timeout=2) == -signal.SIGKILL
            for fd in outputs:
                os.close(fd)
            shutil.rmtree(directory)

    try:
        subprocess.run([gpg, '--homedir', str(keys), '--batch', '--pinentry-mode', 'loopback',
                        '--passphrase', '', '--quick-generate-key',
                        'Custody fixture <custody@example.invalid>', 'ed25519', 'cert', '0'],
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

        # No existing bundle requires neither recipient configuration nor GPG.
        config.write_text('dls[source]=op\n')
        start()
        assert b'tokens: 0 records' in run('status').stdout
        assert not gpg_log.read_bytes()
        run('store', 'fixture', 'one', data=b'opaque', code=78)
        assert not token_path.exists()
        stop()
        config.write_text(f'dls[source]=op\ndls[recipient]={pin}\n')
        start()
        assert not gpg_log.read_bytes()

        first = (b'opaque\x00record\n$(touch ' +
                 shlex.quote(str(fixture / 'should-not-execute')).encode() + b')\n')
        expected = {(b'fixture', b'one'): first}
        result = run('store', 'fixture', 'one', data=first)
        assert result.stdout == b'dls: token record stored\n'
        assert not result.stderr
        assert token_path.stat().st_mode & 0o777 == 0o600
        assert token_path.parent.stat().st_mode & 0o777 == 0o700
        stored(expected)
        assert run('probe').stdout == b'island\n'
        assert b'tokens: 1 records' in run('status').stdout

        # Neither a failed encrypt nor a failed rename changes the parent map.
        for failure in ('fail-encrypt', 'fail-rename'):
            before = token_path.read_bytes()
            (fixture / failure).touch()
            run('store', 'fixture', 'one', data=b'unpublished', code=74)
            (fixture / failure).unlink()
            assert token_path.read_bytes() == before
            assert not list(token_path.parent.glob('.dls-token-bundle.*'))
            identity = failure.encode()
            run('store', 'fixture', failure, data=b'independent')
            expected[b'fixture', identity] = b'independent'
            stored(expected)

        before = token_path.read_bytes()
        invalid = [
            (b'DLS-TOKEN 1\n', {}, 65),
            (frame(b'fixture', b'one', b'bad')[:-1], {'die': True}, 65),
            (b'DLS-TOKENS 1\n' + row(b'fixture', b'one', b'bad'), {}, 65),
            (frame(b'fixture', b'one', b'bad') + row(b'fixture', b'two', b'bad'), {}, 65),
            (b'DLS-TOKEN 1\nZg==\taQ==\tYR==\n', {}, 65),
            (frame(b'', b'one', b'bad'), {}, 65),
            (frame(b'fixture', b'one', b''), {}, 65),
            (frame(b'fixture', b'one', b'x' * 65537), {}, 65),
            (b'x' * 131073, {}, 65),
            (None, {}, 75),
            (frame(b'fixture', b'one', b'bad'), {'hold': True}, 75),
            (None, {'private': False}, 65),
        ]
        for payload, options, code in invalid:
            response, output, error, elapsed = raw_put(payload, **options)
            assert response == f'exit {code}\n'.encode(), (response, error)
            assert not output
            assert elapsed < 7, ('ingress did not return within its deadline', elapsed)
            assert token_path.read_bytes() == before
            assert run('probe').stdout == b'island\n'
        run('store', 'fixture', 'after-refusals', data=b'accepted')
        expected[b'fixture', b'after-refusals'] = b'accepted'
        stored(expected)

        # The producer gets success only after the replacement is published.
        before = token_path.read_bytes()
        (fixture / 'hold-encrypt').touch()
        pending = subprocess.Popen([*command, 'store', 'fixture', 'one'], env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        pending.stdin.write(b'replacement')
        pending.stdin.close()
        pending.stdin = None
        try:
            wait_for(lambda: (fixture / 'encrypt-ready').exists())
            assert pending.poll() is None
            assert token_path.read_bytes() == before
        finally:
            (fixture / 'release-encrypt').touch()
        output, error = pending.communicate(timeout=10)
        assert pending.returncode == 0, error
        assert output == b'dls: token record stored\n'
        (fixture / 'hold-encrypt').unlink()
        expected[b'fixture', b'one'] = b'replacement'
        stored(expected)
        assert '--decrypt' not in gpg_log.read_text()
        stop()

        # One bundle decrypt loads every identity; subsequent puts preserve it.
        gpg_log.write_text('')
        start()
        assert gpg_log.read_text().count('--decrypt') == 1
        assert b'tokens: 4 records' in run('status').stdout
        assert run('probe').stdout == b'island\n'
        run('store', 'another-application', 'one', data=b'separate namespace')
        expected[b'another-application', b'one'] = b'separate namespace'
        largest = bytes(range(256)) * 256
        run('store', 'fixture', 'binary-limit', data=largest)
        expected[b'fixture', b'binary-limit'] = largest
        stored(expected)
        stop()

        good = token_path.read_bytes()
        for invalid_document in (
            b'DLS-TOKENS 2\n',
            b'DLS-TOKENS 1\n' + row(b'fixture', b'one', b'a') * 2,
            b'DLS-TOKENS 1\n' + row(b'fixture', b'one', b'a')[:-1],
        ):
            encrypt(invalid_document)
            start(refuse=True)
        token_path.write_bytes(b'not encrypted')
        start(refuse=True)
        token_path.write_bytes(good)
        token_path.chmod(0o644)
        start(refuse=True)
        token_path.chmod(0o600)

        # Snapshot replenishment is separate; a combined start decrypts twice.
        run('sync')
        assert token_path.read_bytes() == good
        config.write_text(f'dls[source]=snapshot\ndls[recipient]={pin}\n')
        gpg_log.write_text('')
        start()
        assert gpg_log.read_text().count('--decrypt') == 2
        assert b'tokens: 6 records' in run('status').stdout
        assert run('probe').stdout == b'island\n'
        stop()
        assert not list(token_path.parent.glob('.dls-token-bundle.*'))
        assert not (fixture / 'should-not-execute').exists()
        print('tokens: PASS')
    finally:
        (fixture / 'release-encrypt').touch()
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
