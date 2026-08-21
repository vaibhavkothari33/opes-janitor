# opes-janitor demo recording
#
# Regenerate the README GIF with:
#     vhs demo/demo.tape
#
# Install VHS first:  winget install charmbracelet.vhs
# Docs:               https://github.com/charmbracelet/vhs
#
# RECORD THIS IN A VM OR ON A THROWAWAY PROFILE.
# Every frame shows real filesystem paths, which means a real username.
# See RECORDING.md for the full checklist before you hit record.

Output demo.gif

Set Shell         "powershell"
Set FontSize      15
Set Width         1400
Set Height        1000
Set Padding       24
Set Theme         "Catppuccin Mocha"
Set TypingSpeed   55ms
Set WindowBar     Colorful
Set BorderRadius  8

# --- setup, not recorded ------------------------------------------------
Hide
Type "cd $env:USERPROFILE\opes-janitor"
Enter
Type "Clear-Host"
Enter
Sleep 500ms
Show

# --- 1. the problem -----------------------------------------------------
Type "# Windows dev machine. Disk is nearly full."
Sleep 800ms
Enter
Sleep 400ms

Type "Get-PSDrive C | Select-Object Used,Free"
Enter
Sleep 3s

Type "Clear-Host"
Enter
Sleep 300ms

# --- 2. dry run ---------------------------------------------------------
Type "# Dry run is the default. This deletes nothing."
Sleep 800ms
Enter
Sleep 400ms

Type ".\janitor.ps1 -Level deep"
Enter
# Measuring large cache trees is the slow part. Tune this to your machine -
# it should end a beat after the summary line renders.
Sleep 25s

Type "Clear-Host"
Enter
Sleep 300ms

# --- 3. the safety guard ------------------------------------------------
Type "# Deletion is allowlist-only. 18 assertions prove it."
Sleep 800ms
Enter
Sleep 400ms

Type ".\test-guard.ps1"
Enter
Sleep 8s

Type "Clear-Host"
Enter
Sleep 300ms

# --- 4. apply -----------------------------------------------------------
Type "# Now actually clean."
Sleep 800ms
Enter
Sleep 400ms

Type ".\janitor.ps1 -Apply -Level deep -NoToast"
Enter
Sleep 30s

Sleep 4s
