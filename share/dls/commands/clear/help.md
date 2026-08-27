# desc -- evict cached secrets
# arg -- [<reference>...]
# opt help
Display help for `dls clear`.
# man
## DESCRIPTION
`dls clear` evicts the named secrets from the server cache, or every cached
secret when invoked without arguments. The next use fetches fresh from
1Password.

Rotation is: rotate at the issuer, update the vault item, `dls clear` the
reference. Values never require a server restart; only code does.
## OPTIONS
> options
