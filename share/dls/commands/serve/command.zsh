# The dls server: a Unix domain socket accept loop that runs commands in
# background process trees and streams their output through client
# provided fifos.
#
# The socket is the control plane. A request is one line of ${(q)}
# quoted words:
#
#     <kind> <name> <cwd> <out-fifo> <err-fifo> <args...>
#
# where kind is `execute` or `control`. The response is the exit status,
# written to the connection as `exit <code>` when the command finishes.
# The connection fd is inherited by the command's process tree, so the
# client's end of the socket reaches end of file exactly when the tree
# is done — the kernel is the completion signal. A crashed server or
# wrapper reads as end of file without an exit record, which the client
# reports as a protocol error instead of hanging.
#
# Output never crosses the socket. The command's standard out and standard
# error stream through the fifos, masked line by line against every
# cached secret value. The server touches both fifos exactly once per
# request, error paths included, so client readers always terminate.

zmodload zsh/net/socket
zmodload zsh/datetime
zmodload zsh/system

function :help:serve {
    help=$(<${functions_source[:help:serve]:A:h}/help.md)
}

function :args:serve {
    eval "$(args -C -bx h,help -- "$@")"
}

# INVARIANT No hot reload. Every line of command code is loaded here,
# once, at startup, and its checksum recorded for `dls status` to report
# drift. A command written or edited after the server starts is inert until
# a human restarts the server; the restart is the approval gate through
# which agent authored code gains access to secrets. Do not add
# convenience reloading; it deletes the security property.
function _dls_load_sources {
    typeset -gA _dls_checksums=()
    typeset key src
    for key in ${(k)zshctl}; do
        [[ $key = :execute:* ]] || continue
        src=$zshctl[$key]
        [[ ${src[1]} = / ]] || continue
        source $src || abend 'fatal: unable to source `%s`' $src
        # This is the line that makes the no-reload invariant above real.
        # Having sourced the command file once, we overwrite its zshctl entry
        # (the source path) with ':', a no-op, so zshctl's delegate never
        # lazily re-sources it on a later call. Drop this and every `dls gh`
        # re-reads the file from disk, and agent-edited command code goes live
        # without a restart — the approval gate, gone.
        zshctl[$key]=':'
        _dls_checksums[$src]="$(cksum < $src)"
    done
    # The function libraries beside the command trees are code too.
    typeset -aU roots=( ${(@)${(k)_dls_checksums}%%/commands/*} )
    typeset file
    for file in ${^roots}/functions/*(N.); do
        _dls_checksums[$file]="$(cksum < $file)"
    done
}

# The loaded commands, for `dls status` and the startup banner. Read the
# expansion inside out: (@k)functions is every defined function name;
# (M)...:#:dls:* keeps only the ones matching :dls:* — with the M flag
# the :# operator keeps matches instead of removing them, which is the bit that
# reads backwards; #:dls: strips the prefix from each; (o) sorts. Net:
# every :dls:<name>, reduced to <name>, in order.
function _dls_commands {
    reply=( ${(o)${${(M)${(@k)functions}:#:dls:*}#:dls:}} )
}

# Line oriented masking filter. Replaces every cached secret value and
# its base64 form with a marker. Best effort by design: an exact or
# base64 occurrence is caught, a laundered one is not. Masks shorter
# than four characters are skipped; masking a tiny string would shred
# the output.
function _dls_mask {
    typeset _dls_line _dls_value
    # The read/print split keeps the stream byte-faithful: a masked stream must
    # match what the command wrote except for the concealed secrets, newlines and
    # all. `read` returns nonzero on a final line with no trailing newline, and
    # that sets _dls_eof; that last line is emitted with print -rn so we never
    # invent a newline the command did not write, while every earlier line gets its
    # newline back with print -r. A clean EOF — read failed and the line is
    # empty — emits nothing, so no spurious blank line is appended.
    integer _dls_eof=0
    while (( ! _dls_eof )); do
        IFS= read -r _dls_line || _dls_eof=1
        (( _dls_eof )) && [[ -z $_dls_line ]] && break
        for _dls_value in "${(@)_dls_masks}"; do
            (( ${#_dls_value} >= 4 )) || continue
            _dls_line=${_dls_line//$_dls_value/<concealed by dls>}
        done
        if (( _dls_eof )); then
            print -rn -- $_dls_line
        else
            print -r -- $_dls_line
        fi
    done
    return 0
}

# Answer a request without running a command: write the texts to the fifos
# and the exit record to the connection. Backgrounded so a client that
# died before opening its fifos wedges a disposable subshell, never the
# server.
function _dls_reply {
    integer conn=$1 code=$4
    typeset out=$2 err=$3 outtext=$5 errtext=$6
    (
        exec {_dls_listen}>&- 2>/dev/null
        [[ -p $out ]] && print -rn -- $outtext > $out
        [[ -p $err ]] && print -rn -- $errtext > $err
        print -r -u $conn -- "exit $code" 2>/dev/null
    ) &!
}

# Run a command in a background process tree and return to the accept loop
# immediately. Both streams mask through plain pipeline stages — no
# coprocs, whose children hold copies of their own pipes and must be
# coaxed into seeing end of file. The fd swap: inside the inner group
# the command's standard error becomes the inner pipe to the err masker,
# and its standard out becomes fd 3, which the outer pipeline carries to
# the out masker. no_multios is load bearing: with multios on, the
# second redirection of standard out would tee into both pipes instead
# of replacing.
#
# The command runs in its own subshell so that an exit or abend in command
# code cannot skip the exit record, which its group prints to the
# inherited connection. The client may see the record before the fifos
# drain; it keeps reading until the connection reaches end of file,
# which the kernel delivers when the last fork here exits — maskers
# included.
function _dls_run_execute {
    integer conn=$1
    typeset name=$2 cwd=$3 out=$4 err=$5
    shift 5
    (
        setopt no_multios
        exec {_dls_listen}>&- < /dev/null
        # The connection arrives on a low fd that the pipeline's fd 3
        # swap can collide with; dup it to a shell allocated fd, ten or
        # above, where no literal redirection can reach it.
        integer report
        exec {report}>&$conn {conn}>&-
        [[ -n $cwd && -d $cwd ]] && builtin cd -q -- $cwd
        {
            {
                ( ":dls:${name}" "$@" )
                print -r -u $report -- "exit $?" 2>/dev/null
            } 2>&1 1>&3 | _dls_mask > $err
        } 3>&1 | _dls_mask > $out
    ) &!
}

function _dls_handle_execute {
    integer conn=$1
    typeset name=$2 cwd=$3 out=$4 err=$5
    shift 5
    if (( ! ${+functions[:dls:${name}]} )); then
        _dls_reply $conn "$out" "$err" 66 '' \
            "dls: no such command ${(qqq)name}: new command code requires a server restart"$'\n'
        return
    fi
    # Declarative denial, checked before any secret is touched. The
    # pattern in dls[<name>:deny] is matched against the first non
    # flag argument. Best effort: `gh -R owner/repo auth` slips by; the
    # threat is accident, not adversary.
    # ${name} is braced in every subscript in this file: a bare $name
    # followed by a colon invites zsh's history-style modifiers — $name:s
    # is the substitute modifier and silently mangles the key, while
    # $name:d happens not to parse as one. Rely on neither.
    typeset deny=${dls[${name}:deny]:-} arg
    if [[ -n $deny ]]; then
        for arg in "$@"; do
            [[ $arg = -* ]] && continue
            if [[ $arg = ${~deny} ]]; then
                _dls_reply $conn "$out" "$err" 77 '' \
                    "dls: denied: \`$name $arg\` is blocked by dls[${name}:deny]"$'\n'
                return
            fi
            break
        done
    fi
    # Resolve the secret here in the parent: a cache write in the
    # background wrapper would die with it and cost a biometric
    # authorization on every call. Resolution serializes fingerprint
    # prompts as a side effect, which is what a prompt deserves.
    typeset dls_verb_secret='' REPLY=''
    if [[ -n ${dls[${name}:secret]:-} ]]; then
        if ! dls_secret dls_verb_secret ${dls[${name}:secret]}; then
            _dls_reply $conn "$out" "$err" 69 '' \
                "${REPLY:-dls: unable to resolve secret}"$'\n'
            return
        fi
    fi
    _dls_run_execute $conn "$name" "$cwd" "$out" "$err" "$@"
}

function _dls_control_fetch {
    integer conn=$1
    typeset out=$2 err=$3
    shift 3
    if (( ! $# )); then
        _dls_reply $conn "$out" "$err" 64 '' \
            $'dls: missing argument: fetch requires at least one secret reference\n'
        return
    fi
    typeset REPLY reference outtext='' errtext=''
    integer failures=0 attempted=0
    {
        for reference in "$@"; do
            if ! dls_ref $reference; then
                errtext+="dls: invalid secret reference: $reference"$'\n'
                (( failures++ ))
                continue
            fi
            reference=$REPLY
            if (( ${+_dls_cache[$reference]} )); then
                outtext+="cached: $reference"$'\n'
                continue
            fi
            (( attempted++ ))
            if dls_fetch $reference; then
                outtext+="fetched: $reference"$'\n'
            else
                errtext+="$REPLY"$'\n'
                (( failures++ ))
            fi
        done
    } always {
        # One authorization covered the whole batch; close the session.
        if (( attempted )); then
            dls_signout
        fi
    }
    _dls_reply $conn "$out" "$err" $(( failures != 0 )) "$outtext" "$errtext"
}

function _dls_control_clear {
    integer conn=$1
    typeset out=$2 err=$3
    shift 3
    typeset REPLY reference errtext=''
    integer cleared=0 failures=0
    if (( $# )); then
        for reference in "$@"; do
            if ! dls_ref $reference; then
                errtext+="dls: invalid secret reference: $reference"$'\n'
                (( failures++ ))
                continue
            fi
            reference=$REPLY
            if (( ${+_dls_cache[$reference]} )); then
                unset "_dls_cache[$reference]" "_dls_cache_b64[$reference]"
                (( cleared++ ))
            fi
        done
    else
        cleared=${#_dls_cache}
        _dls_cache=()
        _dls_cache_b64=()
    fi
    _dls_masks=( "${(@v)_dls_cache}" "${(@v)_dls_cache_b64}" )
    _dls_reply $conn "$out" "$err" $(( failures != 0 )) \
        "dls: cleared $cleared; ${#_dls_cache} cached"$'\n' "$errtext"
}

function _dls_status_report {
    typeset text ts file
    typeset -a changed=() missing=() reply
    for file in ${(ok)_dls_checksums}; do
        if [[ ! -f $file ]]; then
            missing+=( $file )
        elif [[ "$(cksum < $file)" != $_dls_checksums[$file] ]]; then
            changed+=( $file )
        fi
    done
    _dls_commands
    strftime -s ts '%Y-%m-%dT%H:%M:%S' $_dls_started
    text="dls server"$'\n'
    text+="  socket: $_dls_socket_path"$'\n'
    text+="  pid: $sysparams[pid]"$'\n'
    text+="  started: $ts"$'\n'
    text+="  commands: ${${(j:, :)reply}:-(none)}"$'\n'
    text+="  cached: ${${(j:, :)${(ok)_dls_cache}}:-(none)}"$'\n'
    text+="  sources: ${#_dls_checksums} files loaded"$'\n'
    for file in "${(@)changed}"; do
        text+="  changed since load: $file"$'\n'
    done
    for file in "${(@)missing}"; do
        text+="  missing since load: $file"$'\n'
    done
    REPLY=$text
}

function _dls_handle_control {
    integer conn=$1
    typeset op=$2 out=$3 err=$4
    shift 4
    case $op in
    (ping)
        _dls_reply $conn "$out" "$err" 0 $'pong\n' ''
        ;;
    (status)
        typeset REPLY
        _dls_status_report
        _dls_reply $conn "$out" "$err" 0 $REPLY ''
        ;;
    (fetch)
        _dls_control_fetch $conn "$out" "$err" "$@"
        ;;
    (clear)
        _dls_control_clear $conn "$out" "$err" "$@"
        ;;
    (stop)
        _dls_running=0
        _dls_reply $conn "$out" "$err" 0 $'dls: server stopping\n' ''
        ;;
    (*)
        _dls_reply $conn "$out" "$err" 64 '' \
            "dls: protocol error: unknown control operation ${(qqq)op}"$'\n'
        ;;
    esac
}

function _dls_handle {
    integer conn=$1
    typeset line
    read -r -t 5 -u $conn line || return 0
    typeset -a request=( "${(@Q)${(z)line}}" )
    if (( ${#request} < 5 )); then
        print -r -u 2 -- 'dls: protocol error: malformed request dropped'
        return 0
    fi
    typeset kind=$request[1] name=$request[2] cwd=$request[3]
    typeset out=$request[4] err=$request[5]
    typeset -a args=( "${(@)request[6,-1]}" )
    case $kind in
    (execute)
        _dls_handle_execute $conn "$name" "$cwd" "$out" "$err" "${(@)args}"
        ;;
    (control)
        _dls_handle_control $conn "$name" "$out" "$err" "${(@)args}"
        ;;
    (*)
        _dls_reply $conn "$out" "$err" 64 '' \
            $'dls: protocol error: unknown request kind\n'
        ;;
    esac
}

function :execute:serve {
    (( ! $# )) || abend -c 64 'fatal: invalid argument: `dls serve` takes no arguments'

    # SAFETY The cache is the point of this server; keep it off disk.
    limit coredumpsize 0 2>/dev/null ||
        print -r -u 2 -- 'dls: warning: unable to disable core dumps'
    umask 077

    _dls_load_sources

    # Belt and suspenders for the no-reload invariant: force the
    # function libraries we depend on to resolve now, not lazily from
    # disk on first use after an agent may have edited them.
    typeset name
    for name in pocket slurp tactac warn dls_ref dls_fetch dls_signout dls_secret; do
        autoload -zU +X $name 2>/dev/null
    done

    typeset -gA _dls_cache=() _dls_cache_b64=()
    typeset -ga _dls_masks=()
    typeset -gi _dls_running=1 _dls_started=$EPOCHSECONDS _dls_listen=-1

    typeset REPLY reply
    dls_socket
    typeset -g _dls_socket_path=$REPLY

    mkdir -p ${_dls_socket_path:h} ||
        abend 'fatal: unable to create %s' ${_dls_socket_path:h}
    chmod 700 ${_dls_socket_path:h}

    [[ -e $_dls_socket_path && ! -S $_dls_socket_path ]] &&
        abend 'fatal: not a socket: %s' $_dls_socket_path
    if [[ -S $_dls_socket_path ]]; then
        if zsocket $_dls_socket_path 2>/dev/null; then
            exec {REPLY}>&-
            abend -c 69 'fatal: already running: another dls server owns %s' $_dls_socket_path
        fi
        # Stale socket from an unclean exit; nobody is listening.
        rm -f $_dls_socket_path
    fi

    zsocket -l $_dls_socket_path ||
        abend 'fatal: unable to listen on %s' $_dls_socket_path
    _dls_listen=$REPLY

    # A dead client must not take the server with it.
    trap '' PIPE
    trap '_dls_running=0' INT TERM

    _dls_commands
    print -r -- "dls: serving on $_dls_socket_path"
    print -r -- "dls: commands: ${${(j:, :)reply}:-(none)}"
    print -r -- "dls: sources: ${#_dls_checksums} files loaded; code edits require a restart"

    integer conn
    while (( _dls_running )); do
        zsocket -a $_dls_listen || continue
        conn=$REPLY
        {
            _dls_handle $conn
        } always {
            exec {conn}>&- 2>/dev/null
        }
    done

    exec {_dls_listen}>&- 2>/dev/null
    rm -f $_dls_socket_path
    print -r -- 'dls: stopped'
}
