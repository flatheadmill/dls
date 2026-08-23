# `dls`

`dls` lets an automated coding agent run a human-approved operation that needs secrets without giving those secrets to the agent.

The agent invokes a command such as:

```console
$ dls project-list
```

A server outside the agent's sandbox fetches the configured secrets from 1Password, runs the approved command, and returns its output. The client sends the operation name and arguments, not a request for a credential.

## For the agent

Treat `dls` as a command namespace, not as a secrets API.

- Run `dls status` to see the operations loaded by the current server. If no server is running, ask the human to start it.
- Run an existing `dls <operation> ...` command as you would any other CLI.
- Do not run `op read`, inspect the DLS configuration, ask for a secret value, or reproduce the command's credential setup yourself.
- If the operation you need does not exist, tell the human what operation you need. Name the external program, the action, the working directory, and the documented credential interface. Do not ask for the credential itself.
- Do not edit a DLS command and expect the running server to use it. New code remains inert until a human reviews it and restarts the server.
- Do not retry an unexpected 1Password authorization prompt in a loop. Stop and let the human decide whether to authorize it.

A useful request is concrete:

> I need an approved operation that runs `terraform plan` in this module. Terraform expects its provider credential as a file named by an environment variable.

That is enough. The human decides which reference to configure, which environment variable to set, and which arguments the operation permits.

`dls --help` shows commands installed on disk; `dls status` shows what the running server actually loaded. Starting or restarting the server is the approval step, not agent housekeeping.

## The division of responsibility

The human owns the server, configuration, and approval of command code. The agent names an approved operation and consumes its ordinary output.

```text
 agent                         dls server                    external program

 dls project-list  --socket--> resolve declared secrets
                               build request-local map  -->  TOKEN=... tool
 stdout/stderr      <--fifo--- exact-value maskers      <--  stdout/stderr
 exit status        <-socket-- completion record
```

The socket is the control plane. Secret values and command output do not cross it. Output returns through two client-created FIFOs. The server-side command code explicitly places the selected values or file paths needed by the external program into that process's environment.

The useful security boundary is the approved operation. A command called `project-list` can be read and judged. A command that accepts an executable and an arbitrary environment is merely a secret injector and defeats the reason to use DLS.

## Requirements

DLS currently installs from source. It requires:

- Zsh and [`zshctl`](https://github.com/flatheadmill/zshctl), with `zshctl` on `PATH`;
- the [1Password CLI](https://developer.1password.com/docs/cli/) as `op`;
- `base64`, `cksum`, and the ordinary Unix file utilities; and
- a local Unix-domain socket shared by the trusted server and its clients.

Clone DLS and link its executable somewhere on `PATH`:

```console
$ mkdir -p ~/.local/src ~/.local/bin
$ git clone https://github.com/flatheadmill/dls.git ~/.local/src/dls
$ ln -s ~/.local/src/dls/bin/dls ~/.local/bin/dls
$ dls --help
```

The symlink is intentional: `zshctl` resolves it to find DLS's adjacent `share/dls` command and function trees.

## Add an operation

DLS commands are `zshctl` extensions. An extension may be written by an agent, but a human must read it before restarting the server.

This is a complete extension containing one deliberately narrow operation:

```text
my-dls-commands/
├── dls.extension.zsh
└── commands/
    └── project-list/
        └── command.zsh
```

`dls.extension.zsh` chooses the local link name:

```zsh
extend[link_as]=local
```

`commands/project-list/command.zsh` contains a client half and a server half:

```zsh
function :help:project-list {
    heredoc -v help <<'    HELP'
        # desc -- list projects from the example service
        # opt help
        Display help for `dls project-list`.
    HELP
}

function :args:project-list {
    eval "$(args -C -bx h,help -- "$@")"
}

# CLIENT: send this named operation and its arguments to the server.
function :execute:project-list {
    dls_execute "$@"
}

# SERVER: validate the operation before placing a secret in any environment.
function :dls:project-list {
    if (( $# )); then
        print -r -u 2 -- 'dls project-list takes no arguments'
        return 64
    fi
    if (( ! ${+secret[token]} )); then
        print -r -u 2 -- 'dls project-list has no configured token'
        return 78
    fi
    EXAMPLE_TOKEN=$secret[token] command examplectl projects list
}
```

The command is intentionally not `dls examplectl ...`. It exposes one action, accepts no arbitrary arguments, and gives the token to one process through an assignment prefix. The non-exported `secret` map does not otherwise follow children.

Link the extension:

```console
$ dls extend link ~/src/my-dls-commands
```

This creates a symlink below `~/.local/share/dls/extensions`. Linking or editing an extension does not change a running server.

## Configure delivery

Configuration lives in `~/.config/dls/config.zsh`. Create it with private permissions and declare the secret admitted to each operation:

```console
$ mkdir -p -m 700 ~/.config/dls
$ touch ~/.config/dls/config.zsh
$ chmod 600 ~/.config/dls/config.zsh
```

```zsh
dls_secrets[project-list:token]=Personal/example/token
```

The key is `<operation>:<map-key>`. The value is a DLS reference written as `vault/item/field`. A leading `op://` copied from 1Password is accepted, but it is not part of the DLS reference language. A section remains another path component: `vault/item/section/field`.

`dls_secrets` admits a decoded scalar to the command's request-local `secret` map. Use it for a token or password that the external program accepts in an environment variable.

`dls_files` admits an absolute path instead:

```zsh
dls_files[project-list:credentials]=Personal/example/key.pem
```

The server decodes the bytes directly into a mode-0600 request file. Its path preserves `vault/item/field` beneath a private request directory, and the file is removed when the operation finishes. Command code passes the returned path to the external program:

```zsh
EXAMPLE_CREDENTIALS=$secret[credentials] command examplectl projects list
```

The configuration key chooses the name in `$secret`; it does not choose the filename. A value containing a newline or null byte is refused. Declare such material as a file instead.

## Review and start

Review the command source and configuration, then start the server in a trusted terminal outside the agent's sandbox:

```console
$ dls serve
dls: serving on /home/example/.local/state/dls/dls.socket
dls: commands: gh, project-list
```

The default socket is `$XDG_RUNTIME_DIR/dls.socket` when that variable is set, otherwise `~/.local/state/dls/dls.socket`. `DLS_SOCKET` overrides it for one invocation, and `dls[socket]` in the configuration provides a persistent override. The server and client must resolve the same path.

All registered command and helper bodies are resolved before the socket binds. Changing a source file afterward does not change that process. To approve new code, stop the server, read the diff, and start it again.

Code already approved at startup is trusted. If its reviewed behavior explicitly sources another file at runtime, DLS does not try to prevent that.

The first cold operation may ask the human to authorize 1Password. Subsequent uses of the same reference are served from the in-memory cache. DLS signs out of the 1Password CLI session after each cold batch so a later fetch is another deliberate authorization.

Commands run with standard input connected to `/dev/null`. Design them to be non-interactive. They run in the client's current working directory when that directory is available to the server.

## Operate the server

```console
$ dls status
$ dls fetch Personal/example/token
$ dls clear Personal/example/token
$ dls stop
```

`dls status` reports the running server's socket, process, start time, loaded operation names, cached references, and source drift. It never reports cached values. It is not operation help; each operation should implement a useful `--help` contract on its client half.

`dls fetch` warms one or more references in a single authorization. Fetching is otherwise lazy. `dls clear` evicts named references, or the entire cache when called without arguments. Rotation does not require a restart: rotate the credential, update 1Password, and clear that reference. `dls stop` removes the socket and lets already-running operations finish.

## What DLS guarantees

For a command that a human has approved and started:

- the server fetches values with `op read` and retains one canonical base64 representation in process memory;
- a request receives only the values and file paths declared for its operation;
- server cache parameters are removed before command code runs;
- a value reaches an external process only when command code explicitly places it in that process's environment;
- a value does not cross the control socket, appear in `argv`, or rest on disk;
- DLS materializes a file secret only at its request path and removes it with the request;
- stdout and stderr are masked against exact occurrences of that request's admitted values when they are at least four characters long; and
- command and helper edits remain inert until the server is restarted.

## What DLS does not guarantee

DLS is not a sandbox around approved code. The server operator, another process running as the same user, or an approved command can read or disclose secrets. The human review is therefore substantive: approval grants the command access to every secret declared for it.

The output filter is exact and line-oriented. It does not conceal transformed values, file contents, or output sent somewhere other than stdout or stderr. A command that prints a credential, copies it elsewhere, or hands its environment to an extensible child has violated its own operation contract.

Request files belong to the foreground operation. A detached process that has released DLS's output streams may outlive the request, but its request files do not. Long-running services should remain attached and run in the foreground.

The bundled `gh` command is a broad compatibility example, not the model for a new operation. It isolates GitHub CLI aliases and extensions and refuses the `auth`, `alias`, and `extension` families, but it still passes a token to a large program with its own subprocess surface. Prefer a command that names and validates one useful action.

## Tests

The test suite uses disposable homes and a fake `op`; it cannot spend a real authorization:

```console
$ zsh test/all.zsh
ok: files (files: PASS)
ok: gate (gate: PASS)
ok: multiple-secrets (multiple-secrets: PASS)
ok: smoke (smoke: PASS)
all: 4 suites passed
```
