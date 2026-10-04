function :help:forget {
    help=$(<${functions_source[:help:forget]:A:h}/help.md)
}

function :args:forget {
    eval "$(args -UC -bx h,help -- "$@")"
}

function :execute:forget {
    delegate "$@"
}
