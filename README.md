# `dls`

<!-- Secret broker: runs commands where the secrets already are, so the values never reach your terminal, your transcript, or your clipboard -->

A secret is a string, and a string cannot be made uncopyable. `dls` starts by conceding that, because everything it does only makes sense once you have.

A bearer token has to be plaintext to work. `ssh-agent` gets away with holding a key because the protocol was designed to accept a signature instead of a string; HTTP was not, and `curl` cannot send an `Authorization` header made of good intentions. Nor is there any defence here against someone already running as you. If an intruder holds your uid, they can read your process memory, and no amount of ceremony between them and a variable changes that. `dls` is not a permission boundary and you should not describe it as one.

What is left after those concessions is still worth having, and it is not what a secrets manager usually claims.

## The leak is the copy-paste

The credential that escapes your organisation rarely escapes through an attacker. It escapes because somebody pasted it.

Working with an assistant produces a firehose of text — pages of it, all day. That text does not sit still the way a file in your home directory sits still. It goes into Slack to show a colleague, into a ticket, into a DM, into a screenshot. Nobody pastes a credential on purpose. It rides out inside a wall of output that nobody rereads before hitting send, and that is how a token ends up in the history somebody's lawyer reads two years later.

The same applies without an assistant in the room. A `.env` file quietly conscripts every developer who holds one into being a small, untrained, unaudited secrets-management system, responsible for rotation they will never do and cleanup nobody can verify. The organisation's real perimeter becomes the union of everyone's dotfiles, shell histories, and notebook checkpoints.

So the threat `dls` is built against is enthusiasm and volume, not malice. It exists to cut the number of times a plaintext credential crosses a terminal from many to nearly none.

## Compare it against the honest alternative

The alternative to `dls` is not an absence of secret handling. It is `op read`, inline, twenty times in an afternoon — and that is worth looking at squarely, because it is what following best practice actually produces.

The reference goes on a command line. The value comes back into a shell variable. Then it goes into `curl -H "Authorization: Bearer $TOKEN"`, where it lands in the process table for anyone watching. Reach for `op run` instead and now there is a template file, a cache, a masking flag somebody will disable, and a debugging session about why the variable is not set. Every one of those steps prints something. Every one of them lands in the scrollback. The secret is handled correctly perhaps half the time, and it is in the firehose every time.

## How it works

`dls` inverts the delivery problem. The secret does not travel to the client;
the operation comes to the secret.

A server runs outside the sandbox holding secrets in memory, fetched from
1Password on first use and cached. A client names a command over a Unix domain
socket, and the server runs that command where the cache already lives,
streaming output back through fifos the client created. The socket carries the
request and completion record, never secret content or command output.

Raw bytes pass directly from `op` into a base64 encoder, and the cache retains
only that single-line representation. Every content read from the cache goes
through one decoder. It produces either the value placed in the request's
`secret` map or the bytes written to a request file; the request interface does
not expose the encoded representation.

Configuration declares how each secret is delivered. A value stays in memory
and reaches the one external process that needs it through an assignment
prefix, never through `argv`. A file is materialized at mode 0600 inside a
fresh request directory below a non-enumerable mode-0300 root; the external
process receives that path, and the request removes the file when it finishes.
In both cases the ordinary transcript contains the operation — for example,
`dls gh pr list` — rather than a secret-fetching ceremony.

Output is filtered on the way back, line by line, against the decoded value
secrets admitted to that request. An exact occurrence of a mask at least four
characters long becomes `<concealed by dls>`. File contents are not masks:
exact substitution cannot protect structured material that a program may parse
or reformat.

## Why Zsh

Against a real adversary, Zsh would be an indefensible choice. There is no secure string type, no locked pages, no way to zero memory, and `typeset -p` will hand the entire shell state to anyone who asks. If you are defending against someone reading your process memory, none of this tool is the right shape and you should stop reading.

Against enthusiasm, Zsh is the right choice, for two reasons.

The first is that the job is keeping a string out of `argv`, off the disk, and out of a transcript, and Zsh does that perfectly well. The care is in the details rather than the language: a value goes to a process through a pipe from a builtin that does not fork, never through a here-string, which is a temporary file wearing a costume.

The second reason is the one that actually decides it. All command code is loaded once, at server startup, and a human restart is the approval gate through which new or edited code reaches secrets. That gate is only worth anything if a human can read the code before restarting. A Zsh command file is a page of text you can take in at a glance. Were this Rust, the review step would be a person staring at a diff of something they would have to build to run, and the gate would quietly become a rubber stamp.

The domain is shell besides. `dls` brokers for `gh` and `op` and `curl`. A version in another language shells out to the same binaries and buys a build step.

## Write the operation, not the escape hatch

A `dls` command should be an operation. `dls slack post-message` runs a page of code somebody read before restarting the server; the secret exists for a moment inside it. A command that hands a secret to whatever you point it at is an escape hatch, and the moment you write one, `dls` stops being a discipline and becomes a secret injector with extra steps.

The shipped `gh` command is the widest shape a command should take, not the template to copy. It is a passthrough to a large tool that does many things, which is exactly why it needs machinery a narrow command does not: a refusal list, and private configuration and data roots so that an alias or extension installed on your machine is not silently handed the brokered token. A `slack post-message` needs none of that, because it has no surface to abuse.

If your own program needs secrets, it should not need anything significant, and it should be running against fixtures in a container.

## What it promises

`dls` promises what its architecture can keep. A brokered value does not cross
the socket, does not appear on a command line, and does not rest on disk. A
brokered file is exposed only as a request-scoped path below the
non-enumerable files root. An exact occurrence of an admitted value in that
request's stdout or stderr is caught by the filter when the mask is at least
four characters long. A command cannot read another command's
secret out of the server's cache. Code that a human has not approved by
restarting the server does not run — though code that was approved is trusted
entirely, and may load more of its own once it is running.

It does not promise to outwit creative logging. A tool that splits a token on
hyphens before printing it, writes its environment to a debug file, or prints
a brokered file defeats the output wall — and that is a defect in the tool, to
be fixed or excised, not something this broker will chase. The filter catches
exact values; it is not a laundering detector.

The discipline is offered rather than enforced, the same way `chmod` is offered. Nothing stops you writing a command that gives everything away. `chmod` will let you `777` your home directory too, and it will not lecture you first.

## Getting started

Run the server in a window of its own:

```
dls serve
```

It creates its state directory at mode 700, binds a socket there, and prints what it loaded. Ctrl-C or `dls stop` from anywhere ends it.

Point a command at a vault entry in `~/.config/dls/config.zsh`:

```zsh
dls_secrets[gh:token]=Private/github/token
dls_files[gcloud:GOOGLE_APPLICATION_CREDENTIALS]=Private/gcloud/key
```

DLS spells a reference `vault/item/field`. A leading `op://` is accepted when
it arrives from 1Password's copy-reference interface, but it is not part of the
DLS language.

The configuration table declares the delivery shape. A `dls_secrets` entry is
a value in the command's non-exported `secret` map. A `dls_files` entry is a
path in that same map. The file preserves its `vault/item/field` reference
beneath the request directory; the configuration key names only the map entry.
A key may not be declared in both tables. A value containing a newline or null
byte is refused rather than silently changing shape; declare file-shaped
material in `dls_files`.

Then use it:

```
dls gh pr list
```

The first call fetches from 1Password, which is a deliberate event — an unexpected authorization prompt is an alarm, not an inconvenience. Later calls are served warm from memory.

`dls status` reports what the server holds, what it loaded, and drift in the
source set recorded at startup. Editing loaded command or helper code does
nothing until you restart, and that restart is the review.

File paths live only for their request. Stopping the server lets command
processes already in flight finish, but a newly started server cleans the
shared files root. An old in-flight command must therefore not expect its file
paths to survive an immediate stop and restart.

## Tests

```
zsh test/all.zsh
```

Every suite in `test/` is discovered and run. They build disposable homes and bring a fake `op` that fails closed, so a run can never spend a real authorization.
