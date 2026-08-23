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

Secrets are fetched from 1Password with `op read` on first use, encoded
directly into canonical single-line base64, and cached in server memory. Every
content read from the cache passes through one decoder before becoming a value
or a request file; the request interface does not expose the encoded
representation. Cold secrets are fetched through their named accounts, then
each account contacted by the batch is signed out and left cold again. Because
fetches are rare, each authorization prompt stays a deliberate event: an
unexpected prompt is an alarm, not an inconvenience.

All command and library code registered at startup is loaded before the socket
binds. New or edited code is inert until a human restarts the server; the
restart is the approval gate through which agent authored code gains access to
secrets. A missing helper or one with a syntax error aborts startup rather than
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

Stopping the server leaves command process trees already in flight to finish.
A newly started server cleans the shared files root before listening, so an old
in-flight command cannot rely on a request-scoped file path surviving an
immediate stop and restart.
## OPTIONS
> options
