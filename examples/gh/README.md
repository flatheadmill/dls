# `gh` example

This optional extension shows how a DLS operation can place one brokered token in the environment of one external process. It is not installed with DLS, and it is usually unnecessary: GitHub CLI already supports its own persistent authentication, so use `gh` directly when that is sufficient.

The example is deliberately broad because it demonstrates the complications that appear when a credential is handed to a large, extensible CLI. It isolates GitHub CLI's configuration and extension roots, disables prompts, and refuses the `auth`, `alias`, and `extension` command families. A new DLS operation should normally be narrower than this one.

To install the example deliberately:

```console
$ dls extend link /path/to/dls/examples/gh
```

Then configure the token reference before reviewing and restarting the server:

```zsh
dls_secrets[gh:token]=Personal/Example/github/token
```
