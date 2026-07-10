function :help:fetch {
    help=$(<${functions_source[:help:fetch]:A:h}/help.md)
}

function :args:fetch {
    eval "$(args -UC -bx h,help -- "$@")"
}

function :execute:fetch {
    dls_call ctl fetch "$@"
}
