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
# The background wrapper and maskers retain the connection fd, but the
# command tree does not. The client's end reaches end of file when that
# shell island is done and both output streams have drained. A detached
# descendant may outlive the request once it has released every output
# endpoint. A crashed server or wrapper reads as end of file without an
# exit record, which the client reports as a protocol error instead of
# hanging.
#
# Output never crosses the socket. The command's standard out and standard
# error stream through the fifos, masked line by line against every
# cached secret value. The server touches both fifos exactly once per
# request, error paths included, so client readers always terminate.

zmodload zsh/net/socket
zmodload zsh/datetime
zmodload zsh/system
zmodload zsh/zselect

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

# Rebuild the output masks after any cache change. Values are ordered longest
# first because masking a prefix destroys the longer exact match and exposes
# its tail. The numeric length prefix gives (On) something to sort; #*: removes
# only that first prefix, so colons in the value survive untouched.
function _dls_rebuild_masks {
    typeset -a _dls_keyed=()
    typeset _dls_value
    for _dls_value in "${(@v)_dls_cache}" "${(@v)_dls_cache_b64}"; do
        _dls_keyed+=( "${#_dls_value}:$_dls_value" )
    done
    _dls_masks=( "${(@)${(@On)_dls_keyed}#*:}" )
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
# the out masker. Once fd 3 is copied back onto standard out, the inner
# group closes that temporary duplicate before running command code.
# no_multios is load bearing: with multios on, the second redirection of
# standard out would tee into both pipes instead of replacing.
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
                # `report` is a membership badge: zsh {var} fds are not
                # close-on-exec, so an exec'd or daemonizing command would
                # inherit the completion wire and could wedge the client on an
                # EOF that never comes. The command subshell never writes
                # report — only this enclosing group prints the exit record —
                # so withhold it from the command tree. The close is inside the
                # subshell because the trailing `( ... ) {report}>&-` form
                # parse-errors — {varid} redirection does not work around
                # subshells. A per-command `{report}>&-` also parses, but the
                # exec form closes the whole subshell as plain intent, not a
                # scoped redirection that reads like an accident.
                #
                # Fd 3 is different: it is temporary pipeline scaffolding, a
                # duplicate of standard out that command code must not inherit.
                # The inner group's `1>&3 3>&-` consumes it at the plumbing
                # boundary after restoring standard out. Fds 1 and 2 remain
                # output badges, so a daemon that keeps either open still hangs,
                # correctly: it is still attached to one of our streams.
                (
                    exec {report}>&-
                    # `$secret` is this command's admitted view. The global
                    # caches belong to the server, not command code; sibling
                    # masker forks retain their copies of the mask list.
                    unset _dls_cache _dls_cache_b64 _dls_masks
                    ":dls:${name}" "$@"
                )
                print -r -u $report -- "exit $?" 2>/dev/null
            } 2>&1 1>&3 3>&- | _dls_mask > $err
        } 3>&1 | _dls_mask > $out
    ) &!
}

# Resolve every secret configured for a command before its detached process
# tree starts. Reference validation is a separate first pass so bad command
# configuration cannot spend a biometric authorization. `$secret` belongs to
# dls throughout this dynamic-scope path; framework helpers must keep their
# locals prefixed so they cannot shadow the caller's map.
function _dls_resolve_secrets {
    typeset _dls_name=$1 _dls_entry _dls_command _dls_key _dls_reference
    typeset _dls_failure=''
    typeset -A _dls_references=()
    integer _dls_attempted=0 _dls_failed=0

    # Parse on the rightmost colon: command names may themselves contain
    # colons, while secret keys may not.
    for _dls_entry in ${(ok)dls_secrets}; do
        _dls_command=${_dls_entry%:*}
        _dls_key=${_dls_entry##*:}
        [[ $_dls_command = "$_dls_name" ]] || continue
        _dls_reference=${dls_secrets[${_dls_entry}]}
        if ! dls_ref "$_dls_reference"; then
            REPLY="dls: invalid secret reference in dls_secrets[${_dls_entry}]: $_dls_reference"
            return 69
        fi
        _dls_references[${_dls_key}]=$REPLY
    done

    # All references are now known good. Fetch every cold value under one op
    # authorization, then close that session once; warm-only calls never sign
    # out. Do not expose a partial map if any fetch fails.
    {
        for _dls_key in ${(ok)_dls_references}; do
            _dls_reference=${_dls_references[${_dls_key}]}
            (( ${+_dls_cache[${_dls_reference}]} )) && continue
            (( _dls_attempted++ ))
            if ! dls_fetch "$_dls_reference"; then
                _dls_failure="dls: unable to resolve secret reference $_dls_reference for dls_secrets[${_dls_name}:${_dls_key}]: ${${REPLY:-unknown error}#dls: }"
                _dls_failed=1
                break
            fi
        done
    } always {
        (( _dls_attempted )) && dls_signout
    }
    if (( _dls_failed )); then
        REPLY=$_dls_failure
        return 69
    fi

    for _dls_key in ${(ok)_dls_references}; do
        _dls_reference=${_dls_references[${_dls_key}]}
        secret[${_dls_key}]="${_dls_cache[${_dls_reference}]}"
    done
    return 0
}

function _dls_handle_execute {
    integer conn=$1
    typeset name=$2 cwd=$3 out=$4 err=$5
    shift 5
    # ${name} is braced wherever a colon follows it: a bare $name invites
    # zsh's history-style modifiers — $name:s silently mangles the key.
    if (( ! ${+functions[:dls:${name}]} )); then
        _dls_reply $conn "$out" "$err" 66 '' \
            "dls: no such command ${(qqq)name}: new command code requires a server restart"$'\n'
        return
    fi
    # Resolve secrets here in the parent: a cache write in the
    # background wrapper would die with it and cost a biometric
    # authorization on every call. Resolution serializes fingerprint
    # prompts as a side effect, which is what a prompt deserves.
    typeset -A secret=()
    typeset REPLY=''
    if ! _dls_resolve_secrets "$name"; then
        _dls_reply $conn "$out" "$err" 69 '' \
            "${REPLY:-dls: unable to resolve secrets}"$'\n'
        return
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
    _dls_rebuild_masks
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

    # Configuration is admitted at the same restart gate as command code.
    # Reject a malformed secrets table before the server binds its socket;
    # surfacing this later as a command failure would blame the caller for an
    # operator configuration error.
    typeset _dls_entry _dls_command _dls_key
    for _dls_entry in ${(ok)dls_secrets}; do
        if [[ $_dls_entry != *:* ]]; then
            abend 'fatal: invalid dls_secrets key %s: expected <command>:<secret-key>' \
                ${(qqq)_dls_entry}
        fi
        _dls_command=${_dls_entry%:*}
        _dls_key=${_dls_entry##*:}
        if [[ -z $_dls_command || -z $_dls_key ]]; then
            abend 'fatal: invalid dls_secrets key %s: command and secret key must be nonempty' \
                ${(qqq)_dls_entry}
        fi
    done

    # Belt and suspenders for the no-reload invariant: force the
    # function libraries we depend on to resolve now, not lazily from
    # disk on first use after an agent may have edited them.
    typeset name
    for name in pocket slurp tactac warn dls_ref dls_fetch dls_signout; do
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
        # Do not park forever in accept: traps run while zsocket is blocked,
        # but the loop cannot observe the cleared run flag until accept
        # returns. A one-second readiness timeout bounds signal shutdown while
        # keeping an idle server asleep almost all of the time. Recheck after a
        # readable result as well, so a signal in that seam never enters an
        # accept the server has already been told to abandon.
        #
        # A readable listener cannot hand back a blocking accept here: a Unix
        # domain accept queue only shrinks by accept, so a client that connects
        # and closes before we get to it is still dequeued, and the request read
        # below finds its immediate end of file within its own five second
        # bound. The folklore about select promising a read that then blocks is
        # about reset handling on network stacks and does not reach this socket.
        #
        # Two parks remain by design and are not this loop's to fix. Secret
        # resolution runs in the parent, so a biometric prompt defers shutdown
        # for as long as `op` takes, deliberately. And a client that dies before
        # opening its fifos wedges a disowned reply subshell, which is off the
        # loop and disposable. Neither holds the accept.
        zselect -r -t 100 $_dls_listen || continue
        (( _dls_running )) || break
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
