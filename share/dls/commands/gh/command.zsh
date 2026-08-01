# The gh command. The client half forwards argv verbatim; the server half
# gives GitHub's CLI only its configured token.
#
# GitHub CLI discovers user aliases in its configuration root and extensions
# in its XDG data root, then registers each one as a top-level command. The
# server points both roots at stable private directories beside its socket so
# operator-installed code is not admitted merely because `gh` can find it.
# Refusing the management families below keeps brokered calls from populating
# those directories through the ordinary gh interface.

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
: ${dls_secrets[gh:token]:=Private/github/token}

# SERVER Runs as the forked first stage of the masking pipeline inside a
# background wrapper: contained, in the client's working directory, with
# standard input on /dev/null. The framework resolved the non-exported
# $secret map in the serve loop before we were spawned.
#
# SAFETY Assignment prefixes scope the token to the gh invocation rather
# than the server environment; it never appears on a command line or in a
# file.
function :dls:gh {
    # Find the subcommand after the common repository options. This is best
    # effort argument parsing over a deliberately incomplete refusal list.
    # Masking remains the backstop when a known command such as auth writes the
    # token to output. It cannot contain alias or extension code that inherits
    # the environment and sends the value somewhere other than output. A
    # narrower dls command can invert this case: name allowed families and
    # refuse the default instead of tracking known risks in an evolving CLI.
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
    case ${argv[$i]:-} in
    (auth)
        print -r -u 2 -- 'dls: gh auth is blocked because it can reveal the brokered token'
        return 77
        ;;
    (alias|extension)
        print -r -u 2 -- \
            "dls: gh $argv[$i] is blocked because it can hand the brokered token to other code"
        return 77
        ;;
    esac

    # These roots persist for the server rather than becoming per-request
    # temporary state. Their parent is the private state directory that owns
    # the socket; creation happens before the token enters any environment.
    typeset _dls_gh_state=${_dls_socket_path:h}/gh
    if ! command mkdir -p \
            $_dls_gh_state/config $_dls_gh_state/data ||
        ! command chmod 700 \
            $_dls_gh_state $_dls_gh_state/config $_dls_gh_state/data
    then
        print -r -u 2 -- "dls: unable to prepare private gh state in $_dls_gh_state"
        return 73
    fi

    GITHUB_TOKEN=$secret[token] \
    GH_TOKEN=$secret[token] \
    GH_CONFIG_DIR=$_dls_gh_state/config \
    XDG_DATA_HOME=$_dls_gh_state/data \
    GH_PROMPT_DISABLED=1 \
    GIT_TERMINAL_PROMPT=0 \
        gh "$@"
}
