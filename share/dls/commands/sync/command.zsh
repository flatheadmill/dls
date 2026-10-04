function :help:sync {
    help=$(<${functions_source[:help:sync]:A:h}/help.md)
}

function :args:sync {
    eval "$(args -C -bx h,help -- "$@")"
}

function :execute:sync {
    (( ! ${_dls_forward_stdin:-0} )) ||
        abend -c 64 'fatal: `--stdin` requires a DLS operation'
    limit coredumpsize 0 2>/dev/null ||
        print -r -u 2 -- 'dls: warning: unable to disable core dumps'
    umask 077
    _dls_prepare

    typeset REPLY _dls_ref _dls_account _dls_path _dls_pin
    typeset -a reply _dls_inventory _dls_attempted_accounts=()
    typeset -A _dls_declared=() _dls_selected=() _dls_cache=()
    typeset -aU _dls_attempted_accounts
    _dls_inventory || abend 'fatal: %s' "$REPLY"
    _dls_inventory=( "${(@)reply}" )
    for _dls_ref in "${(@)_dls_inventory}"; do
        _dls_declared[$_dls_ref]=1
    done
    for _dls_ref in "$@"; do
        dls_ref "$_dls_ref" && (( ${+_dls_declared[$REPLY]} )) ||
            abend -c 64 'fatal: not a declared reference: %s' "${(qqq)_dls_ref}"
        _dls_selected[$REPLY]=1
    done
    (( $# )) || _dls_selected=( "${(@kv)_dls_declared}" )
    _dls_snapshot_config || abend 'fatal: %s' "$REPLY"
    _dls_path=$reply[1]
    _dls_pin=$reply[2]

    # Uncaught signals skip Zsh's always lists. Record cancellation instead,
    # then leave through the account and ciphertext cleanup already in place.
    # Keep the first signal's status; helpers see this local through scope.
    integer _dls_cancelled=0
    setopt localtraps
    trap '(( _dls_cancelled )) || _dls_cancelled=130' INT
    trap '(( _dls_cancelled )) || _dls_cancelled=143' TERM
    if (( $# )); then
        if ! _dls_snapshot_load "$_dls_path" "$_dls_pin"; then
            (( ! _dls_cancelled )) || return $_dls_cancelled
            abend 'fatal: focused sync needs a valid snapshot; %s; use full `dls sync`' "$REPLY"
        fi
    fi

    integer _dls_failed=0 _dls_read_index=0
    integer _dls_read_total=${#_dls_selected}
    {
        for _dls_ref in "${(@ok)_dls_selected}"; do
            (( ! _dls_cancelled )) || break
            (( _dls_read_index++ ))
            builtin print -r -u 2 -- \
                "dls: reading ${_dls_read_index}/${_dls_read_total} ${(q)_dls_ref}"
            (( ! _dls_cancelled )) || break
            _dls_attempted_accounts+=( "${_dls_ref%%/*}" )
            if ! dls_fetch "$_dls_ref"; then
                (( _dls_cancelled )) || print -r -u 2 -- "$REPLY"
                _dls_failed=1
                break
            fi
        done
    } always {
        for _dls_account in "${(@)_dls_attempted_accounts}"; do
            dls_signout "$_dls_account"
        done
    }
    (( ! _dls_cancelled )) || return $_dls_cancelled
    (( ! _dls_failed )) || return 1
    if ! _dls_snapshot_store "$_dls_path" "$_dls_pin" "${#_dls_inventory}"; then
        (( ! _dls_cancelled )) || return $_dls_cancelled
        abend 'fatal: %s' "$REPLY"
    fi
    (( ! _dls_cancelled )) || return $_dls_cancelled
    print -r -- "dls: wrote complete snapshot: $_dls_path"
    print -r -- 'dls: a running server keeps its loaded values until stopped and started again'
}

function :complete:sync {
    [[ $zshctl[args:state] = arguments ]] || return
    _dls_prepare
    typeset REPLY _dls_ref
    typeset -a reply
    _dls_inventory || { completion error '%s' "$REPLY"; return }
    for _dls_ref in "${(@)reply}"; do
        completion -- "$_dls_ref"
    done
}
