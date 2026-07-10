# The gh verb. The client half forwards argv verbatim; the server half
# runs GitHub's CLI with the token injected into its process environment
# only.

function :help:gh {
    help=$(<${functions_source[:help:gh]:A:h}/help.md)
}

# Passthrough: every argument belongs to gh.
function :args:gh {
    eval "$(args -- -- "$@")"
}

function :execute:gh {
    dls_call verb gh "$@"
}

# The op reference for the token and the denied subcommand family.
# Override either in ~/.config/dls/config.zsh. DENY `gh auth`: with
# GITHUB_TOKEN set, `gh auth token` and `gh auth status --show-token`
# print the credential — the one thing this broker exists to keep out of
# transcripts.
: ${dls[verb:gh:secret]:=op://Private/github/token}
: ${dls[verb:gh:deny]:=auth}

# SERVER Runs as the forked first stage of the masking pipeline inside a
# background wrapper: contained, in the client's working directory, with
# standard input on /dev/null. The framework resolved $dls_verb_secret
# in the serve loop before we were spawned.
#
# SAFETY Assignment prefixes scope the token to the gh process
# environment only; it never appears in the server environment, on a
# command line, or in a file.
function dls:verb:gh {
    GITHUB_TOKEN=$dls_verb_secret \
    GH_TOKEN=$dls_verb_secret \
    GH_PROMPT_DISABLED=1 \
    GIT_TERMINAL_PROMPT=0 \
        gh "$@"
}
