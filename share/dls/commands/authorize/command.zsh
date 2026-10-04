function :help:authorize {
    help=$(<${functions_source[:help:authorize]:A:h}/help.md)
}

function :args:authorize {
    eval "$(args -UC -bx h,help -- "$@")"
}

function :execute:authorize {
    delegate "$@"
}
