# The gh command. The client half forwards argv verbatim; the server half
# gives GitHub's CLI only its configured token.

function :help:gh {
    help=$(<${functions_source[:help:gh]:A:h}/help.md)
}

# Passthrough: every argument belongs to gh.
function :args:gh {
    eval "$(args -- -- "$@")"
}

function :execute:gh {
    dls_execute "$@"
}

# The op reference for the token. Override it in ~/.config/dls/config.zsh.
: ${dls_secrets[gh:token]:=op://Private/github/token}

# SERVER Runs as the forked first stage of the masking pipeline inside a
# background wrapper: contained, in the client's working directory, with
# standard input on /dev/null. The framework resolved the non-exported
# $secret map in the serve loop before we were spawned.
#
# SAFETY Assignment prefixes scope the token to the gh process
# environment only; it never appears in the server environment, on a
# command line, or in a file.
function :dls:gh {
    # Find the subcommand after the common repository options. This is best
    # effort argument parsing; exact-value masking remains the wall behind it.
    integer i=1
    while (( i <= $# )); do
        case $argv[$i] in
        (-R|--repo)
            (( i += 2 ))
            ;;
        (--repo=*)
            (( i++ ))
            ;;
        (-*)
            (( i++ ))
            ;;
        (*)
            break
            ;;
        esac
    done
    if [[ ${argv[$i]:-} = auth ]]; then
        print -r -u 2 -- 'dls: gh auth is blocked because it can reveal the brokered token'
        return 77
    fi
    GITHUB_TOKEN=$secret[token] \
    GH_TOKEN=$secret[token] \
    GH_PROMPT_DISABLED=1 \
    GIT_TERMINAL_PROMPT=0 \
        gh "$@"
}
