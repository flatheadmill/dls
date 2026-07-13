function :help:clear {
    help=$(<${functions_source[:help:clear]:A:h}/help.md)
}

function :args:clear {
    eval "$(args -C -bx h,help -- "$@")"
}

function :execute:clear {
    dls_control "$@"
}
