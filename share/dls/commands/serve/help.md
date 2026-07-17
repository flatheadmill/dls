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
places selected values in the environment of the external command that needs
them. Output streams through client provided fifos. Secret values never cross
the socket, appear on a command line, or rest in a file.

Secrets are fetched from 1Password with `op read` on first use and cached in
server memory. All cold secrets for one command are fetched under one biometric
authorization, then the `op` session is signed out and left cold again. Because
fetches are rare, each authorization prompt stays a deliberate event: an
unexpected prompt is an alarm, not an inconvenience.

All command and library code is loaded once, at startup. New or edited command code
is inert until a human restarts the server; the restart is the approval gate
through which agent authored code gains access to secrets. `dls status`
reports files that have changed on disk since load.

Command output is masked line by line against every cached secret value and its
base64 form, best effort.
## OPTIONS
> options
