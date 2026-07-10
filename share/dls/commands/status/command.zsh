function :help:status {
    help=$(<${functions_source[:help:status]:A:h}/help.md)
}

function :args:status {
    eval "$(args -C -bx h,help -- "$@")"
}

function :execute:status {
    dls_call ctl status "$@"
}
