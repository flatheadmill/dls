# desc -- stop the dls server
# opt help
Display help for `dls stop`.
# man
## DESCRIPTION
`dls stop` asks the server to exit. Success means its socket path has been
removed and its listener closed; a replacement can start immediately. Commands
already in flight are unaffected: their process trees, fifos and connections owe the serve loop nothing and
stream to completion. Cached secrets die with the process; the next server
starts cold.
## OPTIONS
> options
