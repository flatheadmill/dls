# desc -- warm the secret cache
# arg -- <reference>...
# opt help
Display help for `dls fetch`.
# man
## DESCRIPTION
`dls fetch` resolves each reference with `op read` and caches the value in
server memory. The whole batch rides a single 1Password authorization — one
touch — and the session is signed out when the batch completes.

A reference is `vault/item/field` or `op://vault/item/field`. The field
segment may itself contain a section, `vault/item/section/field`.

Fetching is otherwise lazy: the first verb that needs a secret triggers a
fetch and its authorization prompt. Warming the cache after a server restart
moves the prompt to a moment you chose.
## OPTIONS
> options
