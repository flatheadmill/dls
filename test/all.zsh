#!/usr/bin/env zsh

# Run every suite in this directory and fail if any of them does.
#
# The suites are discovered rather than listed, and that is the point of the
# file. A hardcoded list reproduces one level up the gap this runner exists to
# close: a suite that nobody remembers to run is a suite that is not running,
# and a list you have to remember to edit is the same problem wearing a
# different hat. Drop a `*.zsh` in this directory and it is in the run.
#
# Each suite is self-contained — its own disposable HOME, its own socket, its
# own fake `op` that fails closed — so they neither collide nor depend on order.
# They are run in sorted order anyway, because a run whose output shifts between
# invocations is harder to read than one that does not.
#
# A passing suite is reported in one line. A failing suite gets its whole output,
# because at that point the assertions are the report.

emulate -L zsh

typeset here=${ZSH_ARGZERO:A:h}
typeset -a suites=( ${(o)here}/*.zsh(N.) )
suites=( ${suites:#${ZSH_ARGZERO:A}} )

if (( ! ${#suites} )); then
    print -r -u 2 -- 'all: no suites found'
    exit 1
fi

integer failed=0
typeset -a failures=()
typeset suite name output

for suite in "${(@)suites}"; do
    name=${${suite:t}%.zsh}
    output=$(ZSHCTL=${ZSHCTL:-} zsh $suite 2>&1)
    if (( $? )); then
        print -r -- "FAIL: $name"
        print -r -- "$output"
        print -r --
        failures+=( $name )
        (( failed++ ))
    else
        # `A` is doing the work here, not `f`. Splitting alone yields a scalar
        # when a suite emits a single line, and `[-1]` then subscripts the
        # string — reporting its last character as the summary. `A` forces an
        # array expression whether or not the split produced more than one
        # element, so the subscript always means what it looks like.
        print -r -- "ok: $name (${${(@Af)output}[-1]:-no output})"
    fi
done

if (( failed )); then
    print -r -- "all: ${failed} of ${#suites} suites failed: ${(j:, :)failures}"
    exit 1
fi
print -r -- "all: ${#suites} suites passed"
