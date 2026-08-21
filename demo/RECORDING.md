# Recording the demo GIF

`demo.tape` is a [VHS](https://github.com/charmbracelet/vhs) script. It produces
`demo.gif`, which the README embeds. The tape is committed so the recording is
reproducible — when output changes, re-run it instead of re-recording by hand.

```powershell
winget install charmbracelet.vhs
vhs demo/demo.tape
```

## Record in a VM. Not on your machine.

Every frame shows real filesystem paths, and on Windows a filesystem path
contains the profile name:

```
discovered  npm-cache   C:\Users\Vaibhav Kothari\AppData\Local\npm-cache
```

A GIF is worse than a log file for this. It renders at the top of the README,
and you cannot `git rm --cached` a frame — re-recording is the only fix. Use a
Windows VM, a fresh local account, or a container.

Name the throwaway account something neutral (`dev`, `user`) so the paths read
as generic rather than redacted.

## Make the numbers real

A demo recorded on an already-clean machine reads `Would reclaim: 3.66 GB` and
undersells the tool. The point is the state it was built for — a disk at 5.5%
free with 30 GB of dead cache.

Before recording, seed the VM so the caches are genuinely large:

```powershell
# a few real installs, not synthetic files - the sizes should be honest
npm install -g typescript eslint prettier
git clone https://github.com/microsoft/vscode.git; cd vscode; npm install; cd ..
pip install torch pandas numpy scipy
go install golang.org/x/tools/gopls@latest
docker pull node:20; docker pull python:3.12; docker pull postgres:16
npx puppeteer browsers install chrome
```

Then confirm it looks worth showing:

```powershell
.\janitor.ps1 -Level deep
```

If the total is under ~10 GB, seed more before recording.

## Tuning the tape

The `Sleep` values assume commands finish in a certain time. Measuring large
cache trees is the slow part and scales with file count, not size — a VM with
smaller caches finishes faster than the 25s the tape allows.

Run each command manually first, time it, and adjust. Each `Sleep` should end a
beat after the last line renders. Too short truncates the output mid-frame; too
long makes the GIF drag.

## Keep it small

GitHub renders README images inline, so file size matters. Aim under 5 MB.

- Shorten `Sleep` values before lowering resolution — dead air is the usual
  bulk.
- `Set Width` / `Set Height` can drop to 1200x800 without hurting legibility.
- If it is still too large, `gifsicle -O3 --lossy=80 demo.gif -o demo.gif`.

## Publishing

1. Confirm no real username appears in any frame. Scrub through it.
2. Commit `demo.gif` alongside the tape.
3. Uncomment the embed block in `README.md` under **What it looks like**.
4. Leave the static text block in place below it. It stays readable when images
   are blocked, works in terminal markdown viewers, and is indexable by search.
