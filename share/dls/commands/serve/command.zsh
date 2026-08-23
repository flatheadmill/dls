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
# error stream through the fifos, masked line by line against the decoded
# values admitted to that request. The server touches both fifos exactly once
# per request, error paths included, so client readers always terminate.

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

# Close the library half of the restart gate. zshctl registers files in every
# extension `functions` directory as autoload stubs, and extension directories
# lead fpath. Left alone, the parent retains those unresolved stubs while each
# forked request reads the current file from disk. A command file can also
# replace a framework helper with a direct function definition, which +X will
# preserve rather than overwrite.
#
# Reclaim the reserved library names first: remove any stub or direct
# definition, register the exact install-tree file with -R so fpath cannot
# redirect it, resolve it now, and assert the origin. Every function shipped in
# dls's own library is reserved, along with the zshctl library functions used by
# the server path. Then resolve every remaining stub — extension helpers — so
# the body admitted at startup is the body requests keep using.
#
# What the reclaim is for, since a reader will otherwise assume the wrong
# threat. It is not defending framework names against approved code: a command
# file runs arbitrary top level code in this parent when it is sourced, so
# approved code is trusted, entirely, and the help says as much. The reclaim
# beats fpath precedence for the accident. An extension that innocently ships a
# `functions/pocket` would otherwise win stub resolution, because extension
# directories lead fpath — a name collision rather than an attack, which is
# exactly the shape of trouble this project expects. The reclaim makes a
# collision lose to the framework loudly instead of winning silently.
#
# This closes names registered before the gate. Approved code can still add an
# fpath directory and register or source more code at runtime; zshctl's `block`
# helper does exactly that for its block.d functions. That is execution already
# authorized by the loaded body, not something a generic autoload sweep can
# prevent.
function _dls_bind_functions {
    typeset _dls_own_dir=${functions_source[:execute:serve]:A:h:h:h}/functions
    typeset _dls_zshctl_dir=${functions_source[delegate]:A:h:h}/share/zshctl/functions
    typeset -A _dls_reserved=()
    typeset _dls_file _dls_name

    [[ -d $_dls_own_dir ]] ||
        abend 'fatal: unable to find dls function library at %s' $_dls_own_dir
    [[ -d $_dls_zshctl_dir ]] ||
        abend 'fatal: unable to find zshctl function library at %s' $_dls_zshctl_dir

    for _dls_file in $_dls_own_dir/*(N.); do
        _dls_reserved[${_dls_file:t}]=$_dls_file
    done
    # Direct server dependencies plus the transitive helpers they call.
    for _dls_name in abend heredoc pocket slurp tactac warn; do
        _dls_reserved[$_dls_name]=$_dls_zshctl_dir/$_dls_name
    done

    for _dls_name in ${(ok)_dls_reserved}; do
        _dls_file=$_dls_reserved[$_dls_name]
        [[ -f $_dls_file ]] ||
            abend 'fatal: reserved function %s is missing from %s' \
                $_dls_name $_dls_file
        if (( ${+functions[$_dls_name]} )); then
            unfunction $_dls_name ||
                abend 'fatal: unable to reclaim reserved function %s' $_dls_name
        fi
        autoload -zUR $_dls_file ||
            abend 'fatal: unable to pin reserved function %s to %s' \
                $_dls_name $_dls_file
        autoload -zU +X $_dls_name ||
            abend 'fatal: unable to load reserved function %s from %s' \
                $_dls_name $_dls_file
        [[ ${functions_source[$_dls_name]:A} = ${_dls_file:A} ]] ||
            abend 'fatal: reserved function %s loaded from %s instead of %s' \
                $_dls_name ${functions_source[$_dls_name]:-unknown} $_dls_file
    done

    # +X loads without executing. Do not hide its diagnostics: on a parse or
    # lookup failure zsh leaves the name as a stub, and startup must fail rather
    # than silently restoring per-request disk reads.
    autoload -zU +X -m '*'

    # A surviving stub is not evidence that a load failed, it is the whole
    # invariant: a stub body is the only mechanism by which a request can read a
    # function from disk, so if none remain, none can. That is why the aggregate
    # exit status of the sweep above is not the oracle — it reports nonzero here
    # even when every name resolved — while this postcondition is exact.
    #
    # Match the flag prefix rather than one literal. zshctl registers with -zU,
    # giving `builtin autoload -XU`, but a bare `autoload name` gives `builtin
    # autoload -X` with no U, and an exact comparison walks straight past it.
    # Insurance rather than a live bug, and it costs nothing to be right for
    # every registration flavour.
    typeset -a _dls_stubs=() _dls_stub_files=()
    typeset -a _dls_found
    for _dls_name in ${(ok)functions}; do
        [[ ${functions[$_dls_name]} = 'builtin autoload -X'* ]] || continue
        _dls_stubs+=( $_dls_name )
        # Name the file, not just the function. The operator who hits this is
        # usually mid-edit on a helper and would otherwise walk fpath by hand.
        _dls_found=( ${^fpath}/$_dls_name(N.) )
        _dls_stub_files+=( ${_dls_found[1]:-$_dls_name (not found on fpath)} )
    done
    if (( ${#_dls_stubs} )); then
        abend 'fatal: unable to bind all function libraries at startup; unresolved: %s' \
            "${(j:, :)_dls_stub_files}"
    fi
    return 0
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
                    # `$secret` is this command's admitted view, and
                    # `$request_dir` is its private scratch. The global caches
                    # belong to the server, not command code; sibling masker
                    # forks retain their copies of the mask list.
                    unset _dls_cache _dls_masks
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
    integer _dls_failed=0

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
            (( ${+_dls_cache[${_dls_reference}]} )) && continue
            _dls_account=${_dls_reference%%/*}
            _dls_attempted_accounts+=( $_dls_account )
            if ! dls_fetch "$_dls_reference"; then
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
    typeset REPLY reference account outtext='' errtext=''
    typeset -aU attempted_accounts=()
    integer failures=0
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
            account=${reference%%/*}
            attempted_accounts+=( $account )
            if dls_fetch $reference; then
                outtext+="fetched: $reference"$'\n'
            else
                errtext+="$REPLY"$'\n'
                (( failures++ ))
            fi
        done
    } always {
        # Each account contacted by the batch closes once.
        for account in "${(@)attempted_accounts}"; do
            dls_signout $account
        done
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
                unset "_dls_cache[$reference]"
                (( cleared++ ))
            fi
        done
    else
        cleared=${#_dls_cache}
        _dls_cache=()
    fi
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
    typeset _dls_entry _dls_command _dls_key _dls_table
    for _dls_table in dls_secrets dls_files; do
        for _dls_entry in ${(ok)${(P)_dls_table}}; do
            if [[ $_dls_entry != *:* ]]; then
                abend 'fatal: invalid %s key %s: expected <command>:<secret-key>' \
                    $_dls_table ${(qqq)_dls_entry}
            fi
            _dls_command=${_dls_entry%:*}
            _dls_key=${_dls_entry##*:}
            if [[ -z $_dls_command || -z $_dls_key ]]; then
                abend 'fatal: invalid %s key %s: command and secret key must be nonempty' \
                    $_dls_table ${(qqq)_dls_entry}
            fi
            # One key cannot be both shapes. Both tables assign to the same
            # `$secret` entry, so whichever ran second would silently win.
            if [[ $_dls_table = dls_files ]] && (( ${+dls_secrets[$_dls_entry]} )); then
                abend 'fatal: %s is declared in both dls_secrets and dls_files' \
                    ${(qqq)_dls_entry}
            fi
        done
    done

    _dls_bind_functions

    typeset -gA _dls_cache=()
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

    # The files root, where each request gets a private directory and file
    # secrets materialize. Mode 0300 is the whole of the file-side mechanism:
    # enumerating a directory needs the read bit at `opendir`, while opening a
    # known name inside it needs only the execute bit. So a recursive sweep
    # stops at the door and a program handed an absolute path notices nothing.
    #
    # Anything already here is garbage by definition. Only one server can own
    # this socket, and the check above has already refused to start if another
    # one does, so nothing under this root belongs to a living request. Wiping
    # it is therefore the entire lifecycle at this end — no sweeper, no
    # liveness test, no pid to reason about.
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
