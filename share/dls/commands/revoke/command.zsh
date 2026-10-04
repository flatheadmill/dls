function :help:revoke {
    help=$(<${functions_source[:help:revoke]:A:h}/help.md)
}

function :args:revoke {
    eval "$(args -UC -bx h,help -- "$@")"
}

function :execute:revoke {
    delegate "$@"
}
