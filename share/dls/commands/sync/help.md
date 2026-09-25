# desc -- synchronize the declared secrets into an encrypted snapshot
# arg -- [<reference>...]
# opt help
Display help for `dls sync`.
# man
## DESCRIPTION
Run in a trusted terminal after reviewing the installed configuration and
extension code. With no references, read the complete distinct declaration
inventory from 1Password. With exact declared references, decrypt the existing
complete snapshot and refresh only those values. Repeated references cost one
read. Shell completion offers the declared references without fetching values.

Full sync needs the configured public encryption key. Focused sync additionally
needs its private-key operation: on an enrolled Nitrokey, the PIN and touch.
A missing, invalid, or declaration-incompatible snapshot requires a full sync.
Each 1Password account contacted is signed out after the attempted batch.

Set `dls[recipient]` to the full fingerprint of the actual encryption key or
subkey. `dls[snapshot]` optionally overrides `~/.local/state/dls/snapshot.gpg`;
the parent must be a dedicated directory owned by you with mode 0700.
Only ciphertext is written, at mode 0600. Failed synchronization leaves the
previous snapshot in place. Successful synchronization atomically replaces it.

Sync approves one replenishment session and does not change a running server.
Stop and start that server to load the new values. Provider prompts and card
presence authorize access; they do not replace review of source changes.
## OPTIONS
> options
