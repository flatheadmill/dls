# desc -- run the dls secret broker
Run the `dls` server in the foreground.
# opt help
Display help for `dls serve`.
# man
## DESCRIPTION
`dls serve` listens on a Unix domain socket and brokers secrets to clients
that are not allowed to read them. Clients invoke commands; the server runs each
command in a background process tree with its configured secrets available to
loaded command code as a non-exported associative array. Command code explicitly
places selected values or paths in the environment of the external command that
needs them. Output streams through client-provided fifos. Secret content never
crosses the socket or appears on a command line.

Configuration declares each secret's delivery shape. A `dls_secrets` entry is
a value held in memory. A `dls_files` entry is materialized at mode 0600 inside
a fresh request directory below a mode-0300, non-enumerable files root; command
code receives its path in the same associative array. A DLS reference is
`account/vault/item/field`: the first component selects the 1Password account,
and the complete reference is preserved beneath the request directory. The
configuration key names only the map entry. The request directory is removed
when the command finishes. A value containing a newline or null byte is refused
rather than silently changing shape.

With `dls[source]=snapshot`, startup announces one OpenPGP decrypt using the
full actual encryption key fingerprint in `dls[recipient]`. GnuPG handles the
PIN and the token enforces its configured touch policy. The complete document
must pass key, integrity, encoding, and exact declaration-inventory checks
before the cache is populated and the socket binds. The default artifact is
`~/.local/state/dls/snapshot.gpg`, overridden by `dls[snapshot]`. There is no live
fallback, partial readiness, or per-command decrypt.

Without enrollment, `dls[source]` defaults to `op`. Live mode fetches cold
references from 1Password, encodes them directly into canonical single-line
base64, and signs out each account contacted by that batch. Artifact presence
never selects the source. Both sources fill the same canonical cache; every
content exit passes through the existing decoder into a value or request file.
Delivery shape remains a request concern.

The snapshot parent holds the complete declared inventory for its lifetime.
`dls sync` changes ciphertext, and this process never rereads it. Stop and start
the foreground server to load replenished values. Live-mode rotation likewise
uses a new server start; `fetch` and `clear` are no longer controls.

All command and library code registered at startup is loaded before the socket
binds. New or edited code is inert until a human restarts the server; the
restart approves code for that server lifetime. Synchronization is a separate
reviewed start for the installed code it loads. A PIN, touch, or provider prompt
does not replace source review. A missing helper or one with a syntax error aborts startup rather than
remaining a deferred failure on first use: that refusal is the gate working.
`dls status` reports drift in the source set recorded at startup.

The gate covers functions registered when the server starts. Code already
admitted by the gate can explicitly register or source additional functions at
runtime; that action is part of the approved code's behavior and is not a hot
reload performed by dls.

Command output is masked line by line against the decoded value secrets
admitted to that request. Exact masks shorter than four characters are skipped.
File contents, transformed values, and output written anywhere other than
stdout or stderr are outside that filter.

Commands receive `/dev/null` as standard input unless the client invokes
`dls --stdin`. In that form the client's standard input is forwarded as a byte
stream. It is not a pseudo-terminal: terminal modes, screen control, and window
size are not brokered.

Stopping the server leaves command process trees already in flight to finish.
A newly started server cleans the shared files root before listening, so an old
in-flight command cannot rely on a request-scoped file path surviving an
immediate stop and restart.
## OPTIONS
> options
