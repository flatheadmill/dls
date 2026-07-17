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
command places that value in the `gh` process environment only.

The `auth` subcommand family is denied: with `GITHUB_TOKEN` set,
`gh auth token` prints the credential, which is the one thing this broker
exists to keep out of transcripts. The command identifies the subcommand after
leading options, prints the reason for refusal, and exits 77.

## OPTIONS
> options
