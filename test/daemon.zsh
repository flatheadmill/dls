#!/usr/bin/env zsh

# Process ownership and failure injection use only a disposable HOME, fake
# provider/logger, and a private source copy. No enrolled key is involved.
emulate -L zsh
typeset root=${ZSH_ARGZERO:A:h:h}
typeset runner=${ZSHCTL:-$(command -v zshctl)}
python3 - "$root" "$runner" <<'PY'
import errno
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

root, runner = sys.argv[1:]


def wait_for(predicate, timeout=8):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError('fixture deadline expired')


with tempfile.TemporaryDirectory(prefix='dls.daemon.') as temporary:
    fixture = Path(temporary).resolve()
    home, tools, copy = (fixture / name for name in ('home', 'tools', 'source'))
    for directory in (home / '.config/dls', tools):
        directory.mkdir(parents=True)
    shutil.copytree(root, copy, ignore=shutil.ignore_patterns('.git'))
    source = copy / 'share/dls/commands/serve/command.zsh'
    original = source.read_text()
    config = home / '.config/dls/config.zsh'
    config.write_text('')
    address = fixture / 'broker.socket'
    env = dict(os.environ, HOME=str(home), DLS_SOCKET=str(address),
               PATH=f'{tools}:{os.environ["PATH"]}', DLS_TEST_FIXTURE=str(fixture))
    command = [runner, str(copy / 'bin/dls')]
    logs = fixture / 'logger.log'
    logs.touch()
    (tools / 'op').write_text('#!/bin/zsh -f\nprint invoked >> $DLS_TEST_FIXTURE/provider.log\nexit 99\n')
    (tools / 'gpg').write_text('#!/bin/zsh -f\nprint invoked >> $DLS_TEST_FIXTURE/provider.log\nexit 99\n')
    (tools / 'logger').write_text('''#!/bin/zsh -f
print -r -- "$*" >> $DLS_TEST_FIXTURE/logger.log
exit 1
''')
    for tool in tools.iterdir():
        tool.chmod(0o700)
    extension = home / '.local/share/dls/extensions/fixture/commands/probe'
    extension.mkdir(parents=True)
    (extension / 'command.zsh').write_text('''
function :help:probe { help='# desc -- exercise server ownership' }
function :args:probe { eval "$(args -C -- "$@")" }
function :execute:probe { dls_execute "$@" }
function :admit:probe {
    case $1 in
    (owner-exit) exit 23 ;;
    (owner-abend) abend 'fatal: private-owner-text' ;;
    (select-fault) integer held; exec {held}</dev/null; exec {_dls_listen}>&- ;;
    (select-warning) function zselect { print -r -u 2 -- 'private-select-text'; return 1 } ;;
    esac
}
function :dls:probe {
    print -r -- "out:$PWD:$*"
    print -r -u 2 -- 'ordinary stderr'
    exit 7
}
''')
    owners, launches = set(), []

    def run(*args, code=0, cwd=None):
        result = subprocess.run([*command, *args], env=env, cwd=cwd or fixture,
                                capture_output=True, timeout=12)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        return result

    def owner():
        status = run('status').stdout
        pid = int(re.search(rb'  pid: (\d+)', status)[1])
        owners.add(pid)
        assert re.search(rb'  commands: .*probe', status), status
        return pid

    def launch(foreground=False):
        process = subprocess.Popen([*command, 'serve', *(['--foreground'] if foreground else [])],
                                   env=env, cwd=fixture, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        launches.append(process)
        if foreground:
            wait_for(lambda: address.exists() or process.poll() is not None)
            assert process.poll() is None, process.communicate(timeout=1)
        else:
            output, error = process.communicate(timeout=10)
            assert process.returncode == 0, (output, error)
            assert b'dls: serving on ' in output and not error, (output, error)
        pid = owner()
        if foreground:
            assert pid == process.pid
        else:
            assert pid != process.pid
            assert os.getsid(pid) == pid and os.getpgid(pid) == pid
        return process, pid

    def stop():
        result = run('stop')
        assert not address.exists(), 'stop acknowledged before unlink'
        assert result.stdout == b'dls: server stopped\n'

    def raw(payload):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(8)
            connection.connect(str(address))
            connection.sendall(payload)
            connection.shutdown(socket.SHUT_WR)
            response = b''
            while chunk := connection.recv(1024):
                response += chunk
            return response

    try:
        # Facilities are checked before provider or key work, and only daemon
        # mode uses them. Config is deliberately trusted fault-injection code.
        for refusal in (
            'function zmodload { [[ $* != zsh/clone ]] || return 1; builtin zmodload "$@" }\n',
            'function whence { [[ $* != "-p logger" ]] || return 1; builtin whence "$@" }\n',
        ):
            config.write_text(refusal + 'dls[source]=snapshot\n')
            result = run('serve', code=1)
            assert b'daemon mode requires' in result.stderr
            assert not address.exists() and not (fixture / 'provider.log').exists()
            config.write_text(refusal)
            process, pid = launch(True)
            stop()
            assert process.wait(timeout=5) == 0
        config.write_text('')

        for foreground in (True, False):
            logs.write_text('')
            process, pid = launch(foreground)
            if not foreground:
                inventory = subprocess.run([shutil.which('lsof') or '/usr/sbin/lsof', '-a', '-p', str(pid), '-Ffn'],
                                           capture_output=True, check=True).stdout.decode()
                for fd in (0, 1, 2):
                    assert f'f{fd}\nn/dev/null\n' in inventory, inventory
                assert str(address) in inventory, inventory
                assert '/dev/ttys' not in inventory, inventory
                descriptors = {}
                current = ''
                for line in inventory.splitlines():
                    if line.startswith('f'):
                        current = line[1:]
                    elif current.isdigit() and line.startswith('n'):
                        descriptors[current] = line[1:]
                print('daemon descriptor inventory:', ', '.join(
                    f'{fd}={Path(name).name}' for fd, name in descriptors.items()))
            result = run('probe', 'worker-exit', 'private-request-text', code=7, cwd=fixture)
            assert result.stdout == f'out:{fixture}:worker-exit private-request-text\n'.encode(), result.stdout
            assert result.stderr == b'ordinary stderr\n', result.stderr
            assert owner() == pid
            run('serve', code=69)
            assert raw(b'private-malformed-text\n') == b''
            run('status')
            if foreground:
                assert not logs.read_text()
            else:
                wait_for(lambda: logs.read_text().count('\n') == 1)
                assert logs.read_text() == '-t dls -p user.err -- dls: protocol error: malformed request dropped\n'
            stop()
            if foreground:
                output, error = process.communicate(timeout=5)
                assert b'malformed request dropped' in error, error
            # Immediate restart exercises cleanup-before-ack without sleeps.
            for _ in range(3):
                launch(foreground)
                stop()

        # Preserve verbatim relative socket configuration and launch cwd.
        absolute_address = address
        address = fixture / 'relative/broker.socket'
        env['DLS_SOCKET'] = 'relative/broker.socket'
        launch()
        run('probe', 'relative-socket', code=7)
        stop()
        address = absolute_address
        env['DLS_SOCKET'] = str(address)

        # An unlink failure cannot acknowledge a successful stop. No subsequent
        # tail or exit hook retries cleanup after the ownership sentinel clears.
        real_rm = shutil.which('rm')
        (tools / 'rm').write_text('#!/bin/zsh -f\n[[ $* != *broker.socket* ]] || exit 1\nexec ' + shlex.quote(real_rm) + ' "$@"\n')
        (tools / 'rm').chmod(0o700)
        logs.write_text('')
        launch()
        run('stop', code=74)
        assert address.exists()
        assert logs.read_text() == '-t dls -p user.err -- dls: unable to release server socket\n'
        (tools / 'rm').unlink()
        launch()
        stop()

        # Owner exits reach the hook. Worker exit above, ordinary stop, and the
        # launcher's exit do not. A dead listener reports once, never hot-loops.
        for action, message in (
            ('owner-exit', 'dls: server exited unexpectedly'),
            ('owner-abend', 'dls: server exited unexpectedly'),
            ('select-fault', 'dls: listener selection failed'),
            ('select-warning', 'dls: listener selection failed'),
        ):
            logs.write_text('')
            launch()
            run('probe', action, code=7 if action.startswith('select-') else 70)
            try:
                wait_for(lambda: not address.exists())
            except AssertionError:
                raise AssertionError((action, logs.read_text())) from None
            wait_for(lambda: bool(logs.read_text()))
            assert logs.read_text() == f'-t dls -p user.err -- {message}\n', (action, logs.read_text())

        # HUP/TERM are orderly; SIGKILL leaves a grounded stale socket.
        for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGKILL):
            logs.write_text('')
            _, pid = launch()
            os.kill(pid, sig)
            if sig == signal.SIGKILL:
                wait_for(lambda: subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                         capture_output=True).stdout.strip() in (b'', b'Z'))
                assert address.exists()
                # A select capture already in flight may retain the listener
                # briefly. Establish a refused connection before calling the
                # pathname stale, just as startup does.
                def refused():
                    with socket.socket(socket.AF_UNIX) as connection:
                        return connection.connect_ex(str(address)) == errno.ECONNREFUSED
                wait_for(refused)
            else:
                wait_for(lambda: not address.exists())
            assert not logs.read_text()
            launch()
            stop()

        # A launcher in a real terminal exits; the owner has no terminal and
        # remains usable after the final master descriptor is closed.
        child, terminal = pty.fork()
        if child == 0:
            os.execvpe(command[0], [*command, 'serve'], env)
        captured = b''
        until = time.monotonic() + 10
        while time.monotonic() < until:
            ready, _, _ = select.select([terminal], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(terminal, 8192)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                captured += chunk
        _, result = os.waitpid(child, 0)
        os.close(terminal)
        assert result == 0 and b'dls: serving on ' in captured, captured
        pid = owner()
        assert os.getsid(pid) == pid
        run('probe', 'after-terminal-close', code=7)
        stop()

        # Private source faults exercise the real launcher/parser and separate
        # stop exchange. Every failure must suppress the readiness summary.
        ping = "    (ping)\n        _dls_reply"
        for injected in (
            "print -rn -u $conn -- 'exit '; return",
            "print -r -u $conn -- 'bogus'; return",
            "print -r -u $conn -- $'exit 0\\nextra'; return",
            "print -r -u $conn -- 'exit 1'; return",
            "return",
            "exit 24",
        ):
            source.write_text(original.replace(ping, f'    (ping)\n        {injected}\n        _dls_reply', 1))
            result = run('serve', code=1)
            assert b'dls: serving on' not in result.stdout
            assert not address.exists(), (injected, result.stderr)
        # A valid response may arrive one byte at a time.
        source.write_text(original.replace(ping, "    (ping)\n        for byte in e x i t ' ' 0 $'\\n'; do print -rn -u $conn -- $byte; sleep 0.02; done; return\n        _dls_reply", 1))
        launch()
        stop()

        # Interrupt both before accept and halfway through a response. There is
        # no production readiness deadline; this fixture releases the child.
        for before_accept in (True, False):
            for name in ('paused', 'release'):
                (fixture / name).unlink(missing_ok=True)
            hold = ': > $DLS_TEST_FIXTURE/paused; while [[ ! -e $DLS_TEST_FIXTURE/release ]]; do sleep 0.02; done'
            if before_accept:
                modified = original.replace('        _dls_daemon=1', '        _dls_daemon=1\n        ' + hold, 1)
            else:
                modified = original.replace(ping, "    (ping)\n        print -rn -u $conn -- 'exit '; " + hold + "; return\n        _dls_reply", 1)
            source.write_text(modified)
            process = subprocess.Popen([*command, 'serve'], env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            launches.append(process)
            wait_for(lambda: (fixture / 'paused').exists())
            os.kill(process.pid, signal.SIGINT)
            time.sleep(1.2)
            assert process.poll() is None, (before_accept, process.returncode, process.communicate(timeout=1))
            (fixture / 'release').touch()
            output, error = process.communicate(timeout=8)
            assert process.returncode == 1 and b'dls: serving on' not in output, (output, error)
            assert not address.exists()
        source.write_text(original)
        print('daemon: PASS')
    finally:
        (fixture / 'release').touch()
        source.write_text(original)
        if address.exists():
            try:
                subprocess.run([*command, 'stop'], env=env, capture_output=True, timeout=7)
            except subprocess.TimeoutExpired:
                pass
        for pid in owners:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in launches:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        files = fixture / 'files'
        if files.exists():
            files.chmod(0o700)
PY
