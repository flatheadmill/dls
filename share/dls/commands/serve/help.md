# desc -- run the dls secret broker
Run the `dls` server in the foreground.
# opt help
Display help for `dls serve`.
# man
## DESCRIPTION
`dls serve` listens on a Unix domain socket and brokers secrets to clients
that are not allowed to read them. Clients invoke verbs; the server runs each
verb in a background process tree with the secret injected into the child
process environment only, streaming output back through client provided
fifos. Secret values never cross the socket, never appear on a command line,
and never rest in a file.

Secrets are fetched from 1Password with `op read` on first use and cached in
server memory. The `op` session is signed out immediately after each fetch,
so every fetch costs one biometric authorization and the session is cold
again. Because fetches are rare, each authorization prompt stays a deliberate
event: an unexpected prompt is an alarm, not an inconvenience.

All verb and library code is loaded once, at startup. New or edited verb code
is inert until a human restarts the server; the restart is the approval gate
through which agent authored code gains access to secrets. `dls status`
reports files that have changed on disk since load.

Verb output is masked line by line against every cached secret value and its
base64 form, best effort.
## OPTIONS
> options
