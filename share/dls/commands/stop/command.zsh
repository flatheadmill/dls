function :help:stop {
    help=$(<${functions_source[:help:stop]:A:h}/help.md)
}

function :args:stop {
    eval "$(args -C -bx h,help -- "$@")"
}

function :execute:stop {
    dls_control "$@"
}
