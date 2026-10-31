# The dls server: a Unix domain socket accept loop that runs commands in
# background process trees and streams their output through client
# provided fifos.
#
# The socket is the control plane. A request is one line of ${(q)}
# quoted words:
#
#     execute       <name> <cwd> <out-fifo> <err-fifo> <args...>
#     execute-stdin <name> <cwd> <out-fifo> <err-fifo> <in-fifo> <args...>
#     control       <name> <cwd> <out-fifo> <err-fifo> <args...>
#     token-put     -      <cwd> <out-fifo> <err-fifo> <in-fifo>
#
# The response is the exit status, written to the connection as `exit <code>`
# when the request finishes.
# The background wrapper and maskers retain the connection fd, but the
# command tree does not. The client's end reaches end of file when that
# shell island is done and both output streams have drained. A detached
# descendant may outlive the request once it has released every output
# endpoint. A crashed server or wrapper reads as end of file without an
# exit record, which the client reports as a protocol error instead of
# hanging.
#
# Output never crosses the socket. The command's standard out and standard
# error stream through the fifos, masked line by line against the decoded
# values admitted to that request. An execute-stdin request adds a fifo flowing
# from the client to command fd 0; token-put uses the same client-created input
# shape for one opaque record. Ordinary requests use /dev/null. The server
# touches both output fifos exactly once per request, error paths included, so
# client readers always terminate.

zmodload zsh/net/socket
zmodload zsh/datetime
zmodload zsh/system
zmodload zsh/zselect
zmodload zsh/stat

function :help:serve {
    help=$(<${functions_source[:help:serve]:A:h}/help.md)
}

function :args:serve {
    eval "$(args -C -b ,foreground -bx h,help -- "$@")"
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

# Line oriented masking filter. Replaces exact occurrences of this request's
# admitted value secrets with a marker. Best effort by design: a transformed
# occurrence is not the value we were handed and is not caught. Masks shorter
# than four characters are skipped; masking a tiny string would shred the
# output.
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
        (( _dls_listen < 0 )) || { exec {_dls_listen}>&- } 2>/dev/null
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
    typeset name=$2 cwd=$3 out=$4 err=$5 in=$6
    shift 6
    (
        setopt no_multios
        if [[ $in = - ]]; then
            exec {_dls_listen}>&- < /dev/null
        else
            exec {_dls_listen}>&- < $in
        fi
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
                    # `$secret` is this command's admitted view, and
                    # `$request_dir` is its private scratch. The global caches
                    # belong to the server, not command code; sibling masker
                    # forks retain their copies of the mask list.
                    unset _dls_cache _dls_masks _dls_tokens _dls_token_states
                    typeset request_dir=$_dls_request
                    ":dls:${name}" "$@"
                )
                print -r -u $report -- "exit $?" 2>/dev/null
                # The request owned this directory and the request is over.
                # Removing by the remembered name rather than by enumeration is
                # what lets the files root stay unlistable.
                rm -rf $_dls_request
            } 2>&1 1>&3 3>&- | _dls_mask > $err
        } 3>&1 | _dls_mask > $out
    ) &!
}

# Resolve every secret configured for a command before its detached process
# tree starts. Reference validation is a separate first pass so bad command
# configuration cannot spend a biometric authorization. `$secret` belongs to
# dls throughout this dynamic-scope path; framework helpers must keep their
# locals prefixed so they cannot shadow the caller's map.
#
# Shape is declared, not discovered. `dls_secrets` names a value and
# `dls_files` names a file, and both arrive in the same `$secret` map so a
# command body reads one thing and writes the same assignment prefix either
# way. The cache holds one encoded representation and forms no opinion about
# delivery shape: two commands may want the same vault entry in different
# shapes, and any type the cache carried would be wrong for one of them. The
# judgment therefore happens here, filling this command's map, which is the
# only place we know what this command asked for.
#
# `$_dls_request` is this request's private directory, created by the caller.
# dls_file preserves each file reference beneath it and returns that path; the
# configuration key names only the entry in `$secret`.
function _dls_resolve_secrets {
    typeset _dls_name=$1 _dls_entry _dls_command _dls_key _dls_reference
    typeset _dls_account
    typeset _dls_failure=''
    typeset -A _dls_references=() _dls_shapes=() _dls_materialized=()
    typeset -aU _dls_attempted_accounts=()
    integer _dls_failed=0 _dls_fetch_status=0

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
        _dls_shapes[${_dls_key}]=value
    done
    for _dls_entry in ${(ok)dls_files}; do
        _dls_command=${_dls_entry%:*}
        _dls_key=${_dls_entry##*:}
        [[ $_dls_command = "$_dls_name" ]] || continue
        _dls_reference=${dls_files[${_dls_entry}]}
        if ! dls_ref "$_dls_reference"; then
            REPLY="dls: invalid secret reference in dls_files[${_dls_entry}]: $_dls_reference"
            return 69
        fi
        _dls_references[${_dls_key}]=$REPLY
        _dls_shapes[${_dls_key}]=file
    done

    # All references are now known good. Fetch every cold value through its
    # named account, then sign out each account contacted by the batch once.
    # Warm-only calls never sign out. Do not expose a partial map if any fetch
    # fails.
    {
        for _dls_key in ${(ok)_dls_references}; do
            _dls_reference=${_dls_references[${_dls_key}]}
            if _dls_cache_require "$_dls_reference"; then
                continue
            else
                _dls_fetch_status=$?
                typeset _dls_table=dls_secrets
                [[ ${_dls_shapes[${_dls_key}]} = file ]] && _dls_table=dls_files
                _dls_failure="dls: unable to resolve secret reference $_dls_reference for ${_dls_table}[${_dls_name}:${_dls_key}]: ${${REPLY:-unknown error}#dls: }"
                _dls_failed=1
                break
            fi
        done
    } always {
        for _dls_account in "${(@)_dls_attempted_accounts}"; do
            dls_signout $_dls_account
        done
    }
    if (( _dls_failed )); then
        (( _dls_fetch_status != 70 )) || abend 'fatal: %s' "$_dls_failure"
        REPLY=$_dls_failure
        return 69
    fi

    # Decode through the cache's one content exit, fill the map, and assemble
    # this request's masks while we are here. The mask list is exactly this
    # command's own values, longest first.
    #
    # Own values only, because concealing a value a command was never given
    # turns the filter into an oracle: print a guess, watch it come back
    # concealed, and you have learned something about a secret you never held.
    #
    # Longest first, because masks are applied in order with a plain
    # substitution: a shorter value that is a prefix of a longer one consumes
    # its head and streams the tail in the clear. A rotated token cached beside
    # its predecessor is the mundane way into that, not an exotic one.
    typeset -a _dls_keyed=()
    typeset _dls_value
    for _dls_key in ${(ok)_dls_references}; do
        _dls_reference=${_dls_references[${_dls_key}]}
        if [[ ${_dls_shapes[${_dls_key}]} = file ]]; then
            dls_file $_dls_reference
            secret[${_dls_key}]=$REPLY
            continue
        fi
        dls_decode value $_dls_reference
        _dls_value=$REPLY
        # A newline survives an environment variable perfectly well. We refuse
        # it anyway: it is the tell that this was meant to be a file, and a path
        # in an environment dump is a path into a directory nothing can
        # enumerate. A null byte is refused for a different reason — nothing
        # carries one through `execve`, so the child would receive a truncated
        # credential and fail somewhere far from here.
        if [[ $_dls_value = *$'\n'* ]]; then
            REPLY="dls: newline in dls_secrets[${_dls_name}:${_dls_key}]: declare it in dls_files"
            return 69
        fi
        if [[ $_dls_value = *$'\x00'* ]]; then
            REPLY="dls: null byte in dls_secrets[${_dls_name}:${_dls_key}]: declare it in dls_files"
            return 69
        fi
        secret[${_dls_key}]=$_dls_value
        _dls_keyed+=( "${#_dls_value}:$_dls_value" )
    done
    _dls_masks=( "${(@)${(@On)_dls_keyed}#*:}" )
    return 0
}

function _dls_handle_execute {
    integer conn=$1
    typeset name=$2 cwd=$3 out=$4 err=$5 in=$6
    shift 6
    if [[ $in != - && ! -p $in ]]; then
        _dls_reply $conn "$out" "$err" 64 '' \
            $'dls: protocol error: invalid input fifo\n'
        return
    fi
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
    #
    # The request directory is created before resolution because that is where
    # file secrets materialize, and removed here on every failure that returns
    # before the wrapper starts. The wrapper owns it from launch onward and
    # unlinks it after the exit record; until then nothing else knows the name,
    # so the parent has to be the one to clean up.
    typeset _dls_request
    _dls_request=$(mktemp -d $_dls_files/$$.XXXXXX) || {
        _dls_reply $conn "$out" "$err" 73 '' \
            "dls: unable to create a request directory under $_dls_files"$'\n'
        return
    }
    typeset -A secret=()
    typeset REPLY=''
    if ! _dls_resolve_secrets "$name"; then
        rm -rf $_dls_request
        _dls_reply $conn "$out" "$err" 69 '' \
            "${REPLY:-dls: unable to resolve secrets}"$'\n'
        return
    fi
    if ! _dls_admit "$name" "$@"; then
        rm -rf $_dls_request
        _dls_reply $conn "$out" "$err" 69 '' \
            $'dls: request admission failed; verify extension state and token storage\n'
        return
    fi
    _dls_run_execute $conn "$name" "$cwd" "$out" "$err" "$in" "$@"
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
    text+="  source: $_dls_source"$'\n'
    if [[ $_dls_source = snapshot ]]; then
        text+="  recipient: $_dls_recipient"$'\n'
        text+="  snapshot: cached references loaded at startup"$'\n'
    fi
    text+="  commands: ${${(j:, :)reply}:-(none)}"$'\n'
    text+="  cached: ${${(j:, :)${(ok)_dls_cache}}:-(none)}"$'\n'
    text+="  tokens: ${#_dls_tokens} records"$'\n'
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
    (stop)
        if _dls_release; then
            _dls_reply $conn "$out" "$err" 0 $'dls: server stopped\n' ''
        else
            _dls_reply $conn "$out" "$err" 74 '' $'dls: unable to release server socket\n'
        fi
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
        _dls_fault 'dls: protocol error: malformed request dropped'
        return 0
    fi
    typeset kind=$request[1] name=$request[2] cwd=$request[3]
    typeset out=$request[4] err=$request[5]
    typeset -a args=( "${(@)request[6,-1]}" )
    case $kind in
    (execute)
        _dls_handle_execute $conn "$name" "$cwd" "$out" "$err" - "${(@)args}"
        ;;
    (execute-stdin)
        if (( ${#request} < 6 )); then
            _dls_reply $conn "$out" "$err" 64 '' \
                $'dls: protocol error: missing input fifo\n'
            return
        fi
        typeset in=$request[6]
        args=( "${(@)request[7,-1]}" )
        _dls_handle_execute $conn "$name" "$cwd" "$out" "$err" "$in" "${(@)args}"
        ;;
    (control)
        _dls_handle_control $conn "$name" "$out" "$err" "${(@)args}"
        ;;
    (token-put)
        if [[ $name != - ]] || (( ${#args} != 1 )); then
            _dls_reply $conn "$out" "$err" 64 '' \
                $'dls: protocol error: token-put requires one input FIFO\n'
            return
        fi
        typeset REPLY
        integer code
        _dls_token_accept "$args[1]"
        code=$?
        if (( code )); then
            _dls_reply $conn "$out" "$err" $code '' "dls: $REPLY"$'\n'
        else
            # Acknowledgement follows atomic publication and the parent map
            # update. A caller lost after commit does not roll the record back.
            _dls_reply $conn "$out" "$err" 0 $'dls: token record stored\n' ''
        fi
        ;;
    (*)
        _dls_reply $conn "$out" "$err" 64 '' \
            $'dls: protocol error: unknown request kind\n'
        ;;
    esac
}

# Only fixed framework messages reach this function. Never forward a provider,
# extension, request, path, or shell diagnostic to the system log.
function _dls_fault {
    if (( _dls_daemon )); then
        "$_dls_logger" -t dls -p user.err -- "$1" </dev/null >/dev/null 2>&1 || :
    else
        print -r -u 2 -- "$1"
    fi
}

# Unlink while still listening, then release the descriptor. The sentinel keeps
# any later cleanup from unlinking a replacement owner's pathname. Even a failed
# unlink closes admission, but never earns a successful stop acknowledgement.
function _dls_release {
    (( sysparams[pid] == _dls_owner && _dls_listen >= 0 )) || return 0
    _dls_running=0
    integer failed=0
    command rm -f -- "$_dls_socket_path" 2>/dev/null || failed=1
    { exec {_dls_listen}>&- } 2>/dev/null
    _dls_listen=-1
    # A nested explicit exit can unwind a zshexit hook after its first helper
    # returns in Zsh 5.9. Finish ownership changes before calling the logger.
    if [[ ${1:-} = unexpected ]]; then
        _dls_fault 'dls: server exited unexpectedly'
    elif (( failed )); then
        _dls_fault 'dls: unable to release server socket'
    fi
    return $failed
}

function _dls_owner_exit {
    # Explicit exit in a detached subshell can invoke zshexit hooks too.
    (( sysparams[pid] == _dls_owner && _dls_listen >= 0 )) || return 0
    _dls_release unexpected
}

function _dls_summary {
    typeset -a reply
    _dls_commands
    print -r -- "dls: serving on $_dls_socket_path"
    print -r -- "dls: commands: ${${(j:, :)reply}:-(none)}"
    print -r -- "dls: sources: ${#_dls_checksums} files loaded; code edits require a restart"
}

# A timeout and a select error both return 1. zselect.c emits a warning only
# for errors; its warning machinery can overwrite ERRNO. Capture that warning
# privately instead of guessing an errno or retry count. The short-lived shell
# inherits the listener; it finishes before the owner can release ownership.
function _dls_select {
    # Check before opening the capture pipe: it could reuse a closed listener's
    # number and make select watch the wrong descriptor. Some select platforms
    # also ignore a closed descriptor above the process's highest open fd.
    typeset -A descriptor
    zstat -H descriptor -f "$1" 2>/dev/null || return 2
    (( (descriptor[mode] & 8#170000) == 8#140000 )) || return 2
    typeset diagnostic
    if diagnostic=$(zselect -r -t 100 "$1" 2>&1); then
        return 0
    fi
    [[ -z $diagnostic ]] && return 1
    return 2
}

# The launcher owns this bounded parser, not the ordinary FIFO client. Read at
# most eight bytes: one successful exit record and an EOF check. Partial reads
# are normal.
# One-second polls only observe interruption, never impose a readiness deadline.
# Cancellation uses a separate connection and finishes even after interruption.
function _dls_start_control {
    typeset operation=$1 byte response='' expected=$'exit 0\n'
    integer interruptible=$2 fd code
    typeset -a request=( control "$operation" "$PWD" /dev/null /dev/null )
    while ! zsocket "$_dls_socket_path" 2>/dev/null; do
        # zsocket listens with backlog 1. On macOS a queued, abandoned ping can
        # make the separate stop connection refuse until the child accepts it.
        # Keep cancellation pending while the pathname exists; an owner that
        # never accepts (or dies without cleanup) needs manual recovery.
        (( ! interruptible )) && [[ -S $_dls_socket_path ]] || return 1
        sleep 1
    done
    fd=$REPLY
    {
        print -r -u $fd -- "${(j: :)${(@q)request}}" 2>/dev/null || return 1
        while (( ${#response} <= ${#expected} )); do
            (( ! interruptible || _dls_running )) || return 1
            sysread -i $fd -s 1 -t 1 byte 2>/dev/null
            code=$?
            (( code == 4 )) && continue
            if (( code == 5 )); then
                [[ $response = "$expected" ]] &&
                    (( ! interruptible || _dls_running ))
                return $?
            fi
            (( code == 0 )) || return 1
            response+=$byte
            [[ $expected = "$response"* ]] || return 1
        done
        return 1
    } always {
        { exec {fd}>&- } 2>/dev/null
    }
}

function :execute:serve {
    (( ! $# )) || abend -c 64 'fatal: invalid argument: `dls serve` takes no arguments'

    # SAFETY The cache is the point of this server; keep it off disk.
    limit coredumpsize 0 2>/dev/null ||
        print -r -u 2 -- 'dls: warning: unable to disable core dumps'
    umask 077

    typeset -gi _dls_daemon=0
    typeset -g _dls_logger=''
    if (( ! o_foreground )); then
        zmodload zsh/clone || abend 'fatal: daemon mode requires zsh/clone'
        _dls_logger=$(whence -p logger)
        [[ $_dls_logger = /* && -x $_dls_logger ]] ||
            abend 'fatal: daemon mode requires logger'
    fi

    _dls_prepare

    typeset -g _dls_source=${dls[source]:-op} _dls_recipient=''
    typeset -gA _dls_cache=()
    typeset -gA _dls_tokens=()
    typeset -gA _dls_token_states=()
    typeset -gi _dls_tokens_dirty=0
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
        # A full accept queue can refuse connections too, including while the
        # owner waits for a human or finishes synchronous admission. Refusal
        # cannot establish staleness, so leave recovery to the operator.
        abend -c 69 'fatal: cannot connect to existing socket %s; server may be busy or socket may be orphaned; verify no server owns it before removing it' \
            "$_dls_socket_path"
    fi

    if [[ $_dls_source = snapshot ]]; then
        _dls_snapshot_config || abend 'fatal: %s' "$REPLY"
        typeset _dls_snapshot_path=$reply[1]
        _dls_recipient=$reply[2]
        _dls_inventory || abend 'fatal: %s' "$REPLY"
        typeset -a _dls_inventory=( "${(@)reply}" )
        _dls_snapshot_load "$_dls_snapshot_path" "$_dls_recipient" ||
            abend 'fatal: %s' "$REPLY"
    fi

    _dls_tokens_config || abend 'fatal: %s' "$REPLY"
    typeset -g _dls_tokens_path=$reply[1] _dls_tokens_pin=$reply[2]
    _dls_tokens_load "$_dls_tokens_path" "$_dls_tokens_pin" ||
        abend 'fatal: %s' "$REPLY"

    # The files root, where each request gets a private directory and file
    # secrets materialize. Mode 0300 is the whole of the file-side mechanism:
    # enumerating a directory needs the read bit at `opendir`, while opening a
    # known name inside it needs only the execute bit. So a recursive sweep
    # stops at the door and a program handed an absolute path notices nothing.
    #
    # Anything already here is garbage by definition. Only one server can own
    # this socket, and the check above refuses a second live owner. Command
    # trees admitted by a stopped owner may still run, but a new start cleans
    # their old scratch too; request files do not survive a broker restart.
    # There is no sweeper or attempt to track those independent command trees.
    #
    # The wipe raises the mode first because removing the contents means
    # enumerating them, which is the one thing the mode forbids. That is the
    # only moment the door is open, it is in the server's own hands, and it
    # closes before the socket binds. Per-request cleanup needs no such thing,
    # because it removes a directory whose name it remembers.
    typeset -g _dls_files=${_dls_socket_path:h}/files
    mkdir -p $_dls_files ||
        abend 'fatal: unable to create %s' $_dls_files
    chmod 700 $_dls_files ||
        abend 'fatal: unable to open %s for cleaning' $_dls_files
    rm -rf $_dls_files/*(N) $_dls_files/.*(N^-/) ||
        abend 'fatal: unable to clean %s' $_dls_files
    chmod 0300 $_dls_files ||
        abend 'fatal: unable to secure %s' $_dls_files

    zsocket -l $_dls_socket_path ||
        abend 'fatal: unable to listen on %s' $_dls_socket_path
    _dls_listen=$REPLY

    typeset -gi _dls_owner=$sysparams[pid]
    typeset -ga zshexit_functions
    zshexit_functions+=( _dls_owner_exit )

    # Signals request shutdown; they must not release the path while a token
    # update or admission hook is still publishing its synchronous work.
    trap '' PIPE
    trap '_dls_running=0' INT TERM HUP

    if (( ! o_foreground )); then
        if ! clone /dev/null; then
            _dls_release
            return 1
        fi
        if (( $! )); then
            # clone is not a job we can wait for. Give up the listener copy,
            # then prove readiness and cancellation through the socket itself.
            exec {_dls_listen}>&-
            _dls_listen=-1
            if _dls_start_control ping 1; then
                _dls_summary
                return 0
            fi
            print -r -u 2 -- 'dls: startup did not complete; stopping server'
            _dls_start_control stop 0 ||
                print -r -u 2 -- 'dls: unable to confirm startup cancellation'
            return 1
        fi
        _dls_owner=$sysparams[pid]
        _dls_daemon=1
    else
        _dls_summary
    fi

    integer conn selected failed=0
    while (( _dls_running )); do
        _dls_select $_dls_listen
        selected=$?
        (( _dls_running )) || break
        (( selected == 1 )) && continue
        if (( selected != 0 )); then
            _dls_fault 'dls: listener selection failed'
            failed=1
            break
        fi
        if ! zsocket -a $_dls_listen 2>/dev/null; then
            _dls_fault 'dls: unable to accept connection'
            failed=1
            break
        fi
        conn=$REPLY
        {
            _dls_handle $conn
        } always {
            { exec {conn}>&- } 2>/dev/null
        }
    done

    _dls_release || failed=1
    (( _dls_daemon || failed )) || print -r -- 'dls: stopped'
    return $failed
}
