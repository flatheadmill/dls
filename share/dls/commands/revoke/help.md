# desc
Revoke an application grant at its provider.
# arg -- < application > < arguments... >
# opt help
Display help for `dls revoke`.
# man
## DESCRIPTION
Runs the installed application's revocation command. Provider revocation and
local removal are separate acts.

DLS supplies this shared parent command. Extensions mount only the application
children they implement. Installing a child makes that command available to
callers; unsupported children remain absent. The parent only delegates and
performs no token handling or server control.
## OPTIONS
> options
## COMMANDS
> commands
