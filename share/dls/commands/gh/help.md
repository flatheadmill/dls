# desc -- run gh with the github token brokered
Run GitHub's `gh` CLI on the dls server with its brokered token.
# arg -- <gh-arguments>...
# opt help
Display help for `dls gh`.
# man
## DESCRIPTION
`dls gh` forwards its arguments verbatim to a `gh` invocation on the dls
server, run in this working directory so repository aware commands resolve
the right remote. The token is resolved from the reference in
`dls_secrets[gh:token]`, fetched from 1Password on first use and cached. The
command places that value in the environment of the `gh` invocation.

GitHub CLI runs with `GH_CONFIG_DIR` and `XDG_DATA_HOME` pointed at private
directories in the broker's state directory rather than at the operator's
configuration and data. GitHub CLI registers configured aliases and installed
extensions as top-level commands; isolating both roots means an operator's
`gh peek` shell alias or `gh-peek` extension is not present in the brokered
invocation. The directories are stable across requests and mode 0700.

The refusal list covers `auth`, `alias`, and `extension`. With `GITHUB_TOKEN`
set, `gh auth token` prints the credential. Extensions are third party
executables that inherit the token, and shell aliases can run arbitrary
commands with the same environment; either can move the value somewhere the
output masker never sees. Refusing their management families also prevents a
brokered invocation from populating the private state roots. The command
identifies these families after leading repository options, prints the reason
for refusal, and exits 77.

This composition closes GitHub CLI's configured alias and extension doors; the
refusal list alone would not. It is not an allow-list for everything the CLI
may do. Core commands can start Git, SSH, a browser, or another helper, and
child processes inherit the invocation environment. GitHub CLI does not open a
pager when dls gives it a pipe instead of a terminal, and
`GH_PROMPT_DISABLED=1` forecloses interactive prompt and editor paths, but
explicit subprocess operations remain outside the output masker's reach. A
broad passthrough is therefore the widest useful shape for a dls command, not a
pattern that makes every upstream operation safe. A narrow command should
expose only the operation it needs — for example, allow only the `pr` family —
and reject everything else.

## OPTIONS
> options
