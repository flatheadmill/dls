# desc -- warm the secret cache
# arg -- <reference>...
# opt help
Display help for `dls fetch`.
# man
## DESCRIPTION
`dls fetch` resolves each reference with `op read` and caches the value in
server memory. Each account needed by the batch is authorized independently
and signed out once when the batch completes.

DLS spells a reference `account/vault/item/field`. The first component selects
the 1Password account; the remaining path becomes `op://vault/item/field` at
the `op` boundary. The field may itself contain a section,
`account/vault/item/section/field`.

Fetching is otherwise lazy: the first command that needs a secret triggers a
fetch and its authorization prompt. Warming the cache after a server restart
moves the prompt to a moment you chose.
## OPTIONS
> options
