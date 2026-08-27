# desc -- report the dls server state
# opt help
Display help for `dls status`.
# man
## DESCRIPTION
`dls status` reports the server's socket, pid, start time, loaded commands, the
references of cached secrets — never their values — and any source files that
have changed on disk since the server loaded them. A changed file is the
signal that a restart is wanted: read the diff, then restart.
## OPTIONS
> options
