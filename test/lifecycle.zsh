#!/usr/bin/env zsh

# Shared parents compose independently installed application children.
emulate -L zsh
typeset root=${ZSH_ARGZERO:A:h:h}
typeset runner=${ZSHCTL:-$(command -v zshctl)}
[[ -n $runner ]] || exit 1

python3 - "$root" "$runner" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root, runner = sys.argv[1:]
parents = ('authorize', 'import', 'forget', 'revoke')
with tempfile.TemporaryDirectory(prefix='dls.lifecycle.') as temporary:
    fixture = Path(temporary)
    home, tools = fixture / 'home', fixture / 'bin'
    (home / '.config/dls').mkdir(parents=True, mode=0o700)
    tools.mkdir()
    marker = fixture / 'children.log'
    effects = fixture / 'effects.log'
    env = dict(os.environ, HOME=str(home), PATH=f'{tools}:{os.environ["PATH"]}',
               DLS_SOCKET=str(fixture / 'absent.socket'), DLS_MOUNT_ROOT=root,
               DLS_CHILD_MARKER=str(marker), DLS_EFFECT_MARKER=str(effects),
               CODEX_VERSION='fixture', CLAUDECODE='fixture')
    # Even with encrypted-source configuration, these foreground mounts have
    # no reason to consult a provider, key, or running server.
    (home / '.config/dls/config.zsh').write_text('dls[source]=snapshot\n')
    for name in ('op', 'gpg', 'security', 'curl'):
        tool = tools / name
        tool.write_text('#!/bin/zsh -f\nprint -r -- called >> $DLS_EFFECT_MARKER\nexit 99\n')
        tool.chmod(0o700)
    command = [runner, str(Path(root) / 'bin/dls')]

    def run(*args, success=True):
        result = subprocess.run([*command, *args], env=env, capture_output=True, timeout=10)
        assert (result.returncode == 0) == success, (args, result.returncode, result.stdout, result.stderr)
        return result

    # Bare parents show help without installing an application. They neither
    # perform a default operation nor invent application children.
    for parent in parents:
        run(parent, '--help')
        assert run(parent).stdout
        run(parent, 'absent', success=False)
    assert not marker.exists() and not effects.exists()

    extensions = home / '.local/share/dls/extensions'
    mounts = {'alpha': ('authorize', 'import'), 'beta': ('authorize', 'forget', 'revoke')}
    for application, supported in mounts.items():
        extension = extensions / application
        for parent in supported:
            directory = extension / 'commands' / parent / application
            directory.mkdir(parents=True)
            (directory / 'command.zsh').write_text('''
function :help:PARENT:APPLICATION { help='# desc -- APPLICATION fixture action' }
function :args:PARENT:APPLICATION { eval "$(args -- -- "$@")" }
function :execute:PARENT:APPLICATION {
    [[ ${functions_source[:execute:PARENT]:A} = $DLS_MOUNT_ROOT/share/dls/commands/PARENT/command.zsh ]] || return 91
    print -r -- PARENT:APPLICATION >> $DLS_CHILD_MARKER
    print -r -- PARENT:APPLICATION
    builtin printf '<%s>\\n' "$@"
}
'''.replace('PARENT', parent).replace('APPLICATION', application))

    # Both applications appear under their shared parent without either
    # extension supplying or replacing that parent. Help does not run a child.
    for parent in parents:
        help_text = run(parent, '--help').stdout.decode()
        for application, supported in mounts.items():
            if parent in supported:
                assert application in help_text, (parent, application, help_text)
            else:
                assert application not in help_text
    assert not marker.exists()

    for parent in parents:
        for application, supported in mounts.items():
            if parent in supported:
                result = run(parent, application, 'a b', '', '--flag')
                expected = f'{parent}:{application}\n<a b>\n<>\n<--flag>\n'.encode()
                assert result.stdout == expected and not result.stderr
            else:
                before = marker.read_bytes() if marker.exists() else b''
                run(parent, application, success=False)
                assert (marker.read_bytes() if marker.exists() else b'') == before
    assert len(marker.read_text().splitlines()) == 5

    # Removing one independently installed application leaves the core mount
    # and the other application's child intact.
    shutil.rmtree(extensions / 'alpha')
    text = run('authorize', '--help').stdout.decode()
    assert 'alpha' not in text and 'beta' in text
    run('authorize', 'alpha', success=False)
    run('authorize', 'beta', 'remaining')
    run('import', '--help')
    run('import', 'alpha', success=False)
    assert not effects.exists() and not (fixture / 'absent.socket').exists()
    print('lifecycle: PASS')
PY
