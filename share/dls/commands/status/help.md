# desc -- report the dls server state
# opt help
Display help for `dls status`.
# man
## DESCRIPTION
`dls status` reports the server's socket, pid, start time, selected source, loaded commands, the
references of cached secrets — never their values — and any source files that
have changed on disk since the server loaded them. A changed file is the
signal that a restart is wanted: read the diff, then restart.

In snapshot mode it also reports the pinned recipient and says that the cached
references were loaded at startup. It describes this process, without inspecting
or decrypting a snapshot that may have been replaced since startup. A successful
sync does not change the running server's values.

The token count describes opaque records held by this running parent, including
successful puts during its lifetime. Status does not print those records or
inspect a replacement token bundle on disk.
## OPTIONS
> options
