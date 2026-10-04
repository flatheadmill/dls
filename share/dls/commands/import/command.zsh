function :help:import {
    help=$(<${functions_source[:help:import]:A:h}/help.md)
}

function :args:import {
    eval "$(args -UC -bx h,help -- "$@")"
}

function :execute:import {
    delegate "$@"
}
