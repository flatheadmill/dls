# desc
Forget an application grant locally.
# arg -- < application > < arguments... >
# opt help
Display help for `dls forget`.
# man
## DESCRIPTION
Runs the installed application's local removal command. Forgetting local state
does not itself revoke a grant at its provider.

DLS supplies this shared parent command. Extensions mount only the application
children they implement. Installing a child makes that command available to
callers; unsupported children remain absent. The parent only delegates and
performs no token handling or server control.
## OPTIONS
> options
## COMMANDS
> commands
