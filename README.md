# `dls`

`dls` lets an automated coding agent run a human-approved operation that needs secrets without giving those secrets to the agent.

The agent invokes a command such as:

```console
$ dls project-list
```

A server outside the agent's sandbox holds the configured secrets, runs the approved command, and returns its output. The preferred enrolled mode loads one encrypted snapshot at foreground startup after a Nitrokey-approved decrypt. A live 1Password source is also available. The client sends the operation name and arguments, not a request for a credential.

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

`dls --help` shows commands installed on disk; `dls status` shows what the running server actually loaded. Starting the server and synchronizing its snapshot are human approval steps, not agent housekeeping.

Treat that approval as the control, not the agent's perfect recollection of this rule. An agent may mistakenly try to start the server. Decline the unexpected start at the approval boundary; if it was allowed, stop the server and review the loaded command sources before starting it again. The useful response is to restore the boundary, not to replace it with a reprimand.

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
- the [1Password CLI](https://developer.1password.com/docs/cli/) as `op` for synchronization or live fetching;
- GnuPG as `gpg` for snapshot operation, with the public encryption key and its Nitrokey-backed private-key operation available in the ordinary GnuPG home;
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

DLS commands are `zshctl` extensions. An extension may be written by an agent, but a human must review its source and configuration before synchronizing or starting the server. Both operations load executable declarations.

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
dls_secrets[project-list:token]=Personal/Example/service/token
```

The key is `<operation>:<map-key>`. The value is a DLS reference written as `account/vault/item/field`. The first component selects a 1Password account; the remaining path becomes `op://vault/item/field` at the `op` boundary. Use an account shorthand configured in 1Password CLI. A section remains another path component: `account/vault/item/section/field`.

`dls_secrets` admits a decoded scalar to the command's request-local `secret` map. Use it for a token or password that the external program accepts in an environment variable.

`dls_files` admits an absolute path instead:

```zsh
dls_files[project-list:credentials]=Personal/Example/service/key.pem
```

The server decodes the bytes directly into a mode-0600 request file. Its path preserves `account/vault/item/field` beneath a private request directory, and the file is removed when the operation finishes. Command code passes the returned path to the external program:

```zsh
EXAMPLE_CREDENTIALS=$secret[credentials] command examplectl projects list
```

The configuration key chooses the name in `$secret`; it does not choose the filename. A value containing a newline or null byte is refused. Declare such material as a file instead.

## Enroll, synchronize, and start

Provision the encryption key using ordinary GnuPG and token tooling. DLS does not create keys, change the card, or manage PINs. Inspect the public key with `gpg --list-keys --with-subkey-fingerprint` and identify the full fingerprint of the actual encryption key or encryption subkey. Pin that fingerprint in `~/.config/dls/config.zsh`:

```zsh
dls[source]=snapshot
dls[recipient]='FULL_ENCRYPTION_SUBKEY_FINGERPRINT'
# Optional; this is the default.
dls[snapshot]=$HOME/.local/state/dls/snapshot.gpg
```

DLS uses the ordinary GnuPG home (`GNUPGHOME` when set). It encrypts to that exact key; a primary fingerprint does not let GnuPG choose a different subkey. The snapshot directory must be owned by you with mode 0700. DLS creates a missing directory with private permissions, but does not chmod an existing directory. Ciphertext is mode 0600. The snapshot location is independent of the socket and its runtime directory.

Review the installed configuration and extension code. In a trusted terminal, authorize the 1Password accounts involved and synchronize:

```console
$ dls sync
dls: wrote complete snapshot: /Users/example/.local/state/dls/snapshot.gpg
dls: a running server keeps its loaded values until stopped and started again
```

With no arguments, sync reads every distinct reference declared in either `dls_secrets` or `dls_files`. Each contacted account is signed out after the attempted batch. Full sync encrypts with the public key and needs no Nitrokey operation. A failed read, validation, encryption, or replacement leaves the previous ciphertext in place.

Start the reviewed server in the foreground, outside the agent's sandbox:

```console
$ dls serve
dls: decrypting synchronized secrets; touch the Nitrokey
dls: decryption complete
dls: serving on /Users/example/.local/state/dls/dls.socket
```

GnuPG obtains the PIN through pinentry and the token enforces touch when its decryption interaction flag is enabled. DLS does not ask for a PIN on its command line or in a message. One complete decrypt loads the existing canonical cache before the socket binds. A wrong key, failed integrity check, malformed snapshot, or missing or extra declared reference refuses startup. No partial server or live fallback is started. Ordinary operations then need neither 1Password nor the token. Value/file shape checks still occur when an operation is admitted.

Sync and serve approve separate secret-handling sessions. Sync reviews and loads installed code for one replenishment; serve reviews and pins code for one server lifetime. A provider prompt, PIN, or touch authorizes access and does not replace review of changed source. Neither operation changes an already-running server. Approved code remains trusted, including any explicit runtime sourcing in its reviewed behavior.

The default socket is `$XDG_RUNTIME_DIR/dls.socket` when that variable is set, otherwise `~/.local/state/dls/dls.socket`. `DLS_SOCKET` overrides it for one invocation, and `dls[socket]` provides a persistent override. Server and client must resolve the same socket.

An installation without `dls[source]` defaults to `op`. To select live fetching explicitly, set `dls[source]=op`. File presence never selects a source. In live mode the first cold operation may require authorization for each account it uses; subsequent requests reuse the cached entries. Each account contacted by a cold batch is signed out. This alternate source uses the same request admission and delivery path.

Commands receive `/dev/null` as standard input by default. `dls --stdin <command> ...` instead forwards the client's standard input as a byte stream; it does not provide a terminal, so programs that require terminal modes or screen control remain outside the interface. Commands run in the client's current working directory when that directory is available to the server.

## Replenish and operate

To refresh selected values, name exact declared references. A repeated reference costs one read; patterns and undeclared references are refused.

```console
$ dls sync Personal/Example/service/token
$ dls status
$ dls stop
$ dls serve
```

Focused sync decrypts the existing snapshot once, reads only the selected values from 1Password, and atomically writes one complete encrypted replacement. It saves provider reads and still requires the token to recover the entries it preserves. A missing, corrupt, unsupported, or declaration-incompatible old snapshot requires a full `dls sync`. Full synchronization is a batch of reads, not a transactional view of 1Password at a single instant.

Enable the existing Zsh completion integration to select declared references:

```zsh
autoload -Uz compinit
compinit
source <(dls completion zsh)
```

Completion loads installed executable declarations. DLS does not contact the provider, token, or server to complete a reference.

`dls status` reports the running process's socket, PID, startup time, selected source, loaded operation names, cached references, and source drift. In snapshot mode it also names the pinned recipient and says the references were loaded at startup. It never reports values or inspects a replacement snapshot to describe what this process holds. Source drift is a reminder to review before the next start. Each operation's client half provides its own `--help`.

Sync changes ciphertext; serve reads it once at startup; a running server keeps its loaded values. After synchronization, stop and start the foreground server to load the replacement. `fetch` and `clear` have been removed in both modes. Live-mode rotation also requires a new server start; ordinary live requests can still populate previously cold entries.

Stop ends the parent cache and admission of new requests while allowing existing operations to finish. A following start cleans the shared request-files root, so old operations cannot rely on their files surviving an immediate stop/start.

If a key is lost, reset, or replaced, provision another key outside DLS, review and change the pinned fingerprint, and run full sync. A new pin cannot load the old-key artifact or use it for focused sync. A failed sync preserves that old ciphertext; either finish replenishment under the new key or deliberately restore the old configuration. There is no private-key recovery or snapshot history to manage in DLS: 1Password remains the source of truth.

This is an attended workstation workflow. Background startup, daemonization, a restart command, and remote agent forwarding are outside this interface.

## What DLS guarantees

For a command that a human has approved and started:

- the server retains one canonical base64 cache, filled completely at snapshot startup or lazily from 1Password in live mode;
- a snapshot server holds the complete declared inventory for its lifetime, while each request retains its own narrow admission;
- a request receives only the values and file paths declared for its operation;
- server cache parameters are removed before command code runs;
- a value reaches an external process only when command code explicitly places it in that process's environment;
- a value does not cross the control socket, appear in external `argv`, or rest on disk as plaintext; snapshots contain only ciphertext and file delivery remains explicit;
- DLS materializes a file secret only at its request path and removes it with the request;
- stdout and stderr are masked against exact occurrences of that request's admitted values when they are at least four characters long; and
- command and helper edits remain inert until the server is restarted.

## What DLS does not guarantee

DLS is not a sandbox around approved code. The server operator, another process running as the same user, or an approved command can read or disclose secrets. The human review is therefore substantive: approval grants the command access to every secret declared for it.

The output filter is exact and line-oriented. It does not conceal transformed values, file contents, or output sent somewhere other than stdout or stderr. A command that prints a credential, copies it elsewhere, or hands its environment to an extensible child has violated its own operation contract.

Request files belong to the foreground operation. A detached process that has released DLS's output streams may outlive the request, but its request files do not. Long-running services should remain attached and run in the foreground.

## Example extension

The optional [`gh` example](examples/gh) is not installed with DLS. Most users should use GitHub CLI's own authentication and run `gh` directly. The example remains in the repository to show the additional care required when a broad, extensible CLI receives a brokered token; new operations should prefer the narrow `project-list` shape above.

## Tests

The test suite uses disposable homes, software OpenPGP keys, and a fake `op`; it cannot spend a real provider authorization or require a token. GnuPG and local Unix sockets must be available:

```console
$ zsh test/all.zsh
ok: files (files: PASS)
ok: gate (gate: PASS)
ok: multiple-secrets (multiple-secrets: PASS)
ok: smoke (smoke: PASS)
ok: snapshot (snapshot: PASS)
all: 5 suites passed
```
