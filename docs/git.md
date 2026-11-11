# Git in Strata

Strata shows a repository's status in the pane, Magit-style: sections of changed files, their diffs a Tab away, and
single keys that stage, unstage, commit, branch, fetch, push, stash and rebase exactly what's selected. It is
fork-only; the design is in `docs/superpowers/specs/2026-11-10-git-workbench-design.md`.

## Opening it

⌃⌘G (View ▸ Show Git Status, the branch button in the toolbar, or "Git" in the command palette) shows the status of the repository the pane's folder
is in. The other pane stays a file browser. ⌃⌘G again, `q` or Escape goes back to the files; Return on a file goes
back and selects it. Moving to a folder outside the repository closes the status; moving within it keeps it.

While the status shows, the pane's file commands (Move to Trash, Rename, Paste and the rest) are off, and the file
selection under it is cleared, so nothing can act on files you can't see. Copy Path, Copy Relative Path, Copy Name
and Reload stay on.

## Keys

| Key | What it does |
| --- | --- |
| `s` / `u` | Stage / unstage the selection: files, a section, a hunk, or lines of one hunk |
| `S` / `U` | Stage everything / unstage everything |
| `k` | Discard the selection: unstaged changes go back to the staged version, untracked files go to the Trash |
| Tab | Show or hide the selected files' changes (on a section: all its files) |
| Shift-Tab | Show or hide every file's changes |
| `c` | Commit: `c` commit, `a` amend, `e` extend (staged changes into the last commit), `w` reword |
| `d` | Diff: `u` unstaged, `s` staged, `w` everything not committed |
| `l` | Log: `l` the current branch, `a` all branches |
| `b` | Branch: `b` switch, `c` new and switch, `n` new, `m` rename the current one, `k` delete |
| `f` / `F` / `P` | Fetch (`f` the branch's remote, `a` all) / pull (`F` fast-forward only, `r` rebase) / push (`P`, `f` force with a lease) |
| `z` | Stash: `z` everything with new files, `w` tracked files only, `a` apply, `p` pop, `k` drop |
| `r` | Rebase: `i` interactively from a commit; during a rebase `r` continue, `s` skip, `a` abort |
| `g` | Reload |
| `n` `p`, arrows | Move (`j` and `k` don't move here, since `k` discards; they do in the log and diff) |
| Return | Show the file in the pane |
| `?` | All keys |
| `q`, Escape | Back (from a diff or log to the status, from the status to the files) |

After `s`, `u` or `k` the selection moves on to the file now in its place, so pressing `s` again stages the next one.
A line under the list names the main keys, and the last command's result shows above it with a checkmark, or a
warning sign when it failed. Right-clicking a row offers the same commands: stage, unstage, discard, show its
changes, show it in the pane, commit. Menus that open from a key (`c`, `d`, `l` and the rest) open beside the
selected row.

A file's changes show as hunks and lines. Selecting a hunk and pressing `s` stages only that hunk; selecting some of
its lines stages only those (a removed line left out stays, an added line left out isn't added). `u` and `k` work the
same way. New, deleted and binary files change as a whole.

## Diffs and history

`d` opens a whole diff over the status: every file's hunks, added and removed lines tinted, Tab folds the selected files, Shift-Tab all of them. The
log (`l`) shows each commit's lane in the graph, where branches fork and merge, the branches and tags at it, its
author and date; a merge's dot is hollow, so it reads apart without relying on color. Return shows a commit's
message and changes; with two commits selected, `d` shows what changed between them. In the log, `x` resets the
branch to the selected commit (soft, mixed, or hard after a confirmation) and `r` opens the rebase plan from it.
The log and the diff each name their keys on a line under them.

## Git History panel

⌥⌘G (View ▸ Show Git History, or the clock button in the toolbar) opens a panel between the files and the
Inspector. It follows the active pane's repository: its name, branch and changes, then its history with the graph,
each commit's subject on a line of its own and its branches, id, date and author under it.
Clicking a commit shows that commit's files in the pane, at the folder the pane shows, or the nearest one that
existed then; `n` `p`, `j` `k` and the arrow keys move as in the log, and the pane follows once they rest. The panel
says which commit is shown, and Working Files brings the pane back to the repository's own files at the same place.
Moving within a commit's files keeps showing that commit. With two panes the panel takes the other pane's place, as
wide as it was, and hiding the panel opens that pane again at its folder. Return (or a double-click) shows the commit's changes in
the pane, where they have room, and `d` with two commits selected what changed between them; `q` brings the files
back.

A commit's files are a read-only copy Strata makes in its caches with a temporary index of its own: the repository's
index, working files and branch never change, and its hooks and filters don't run (a git-lfs file shows as its
pointer). Nothing in it can be renamed, trashed, moved or added to, as with an archive opened as a folder; the status
bar says "Commit abc1234, read only". Its files carry the commit's date, the one the log shows. Strata keeps the eight most recently shown commits of each repository.

## Taking things back

Discard, reset, stash, dropping a stash and a finished rebase each register Edit ▸ Undo (⌘Z). What they replaced is
kept in the repository under `refs/strata/undo/`, so git's garbage collection can't take it, and the refs go once
undone. Undo checks first that nothing changed since: a file edited after a discard, a commit made after a reset or
a rebase, a newer stash on top. If anything did, it changes nothing and says why. Untracked files go through Strata's
own Move to Trash, with its Undo and History.

## Branches, pull and push

Switching branches never overwrites local changes (git's own refusal is kept), a branch with commits nowhere else is
deleted only after a second, explicit choice, pull only fast-forwards unless you ask it to rebase, and push never
forces except with a lease on what you last fetched.

## Interactive rebase

The plan lists the commits oldest first. `p` pick, `r` reword (asks for the message), `e` edit (stops after it),
`s` squash, `f` fixup and `d` drop set the selected commit's action; ⌥↑ and ⌥↓ or dragging reorder; Return starts and
`q` cancels. A dropped commit is struck through. Strata writes git's todo itself and no editor opens; the plan must
name exactly the commits git would rebase, so none is ever left out silently. When git stops (an edit or a
conflict), the status shows it: change or resolve the files, stage them, then `r` `r` continues, `r` `s` skips and
`r` `a` puts the branch back as it was.

## Trust

A repository can make git run programs: hooks, filter drivers such as git-lfs, a file monitor. Strata reads every
repository with all of these switched off, so browsing a downloaded repository runs nothing from it. Changing a
repository needs them on, or a git-lfs file would be committed as raw bytes and your pre-commit checks would be
skipped. So the first command that would change a repository asks first, listing what would run; until you agree,
the repository is read only (the header shows a lock and a Trust… button). Trust is remembered by the folder's
identity as well as its path: a different repository moved to the same place is asked about again. Settings ▸ Git
lists trusted repositories and revokes them.

Git never prompts and never opens an editor from Strata: commit messages come from Strata's own editor (⌘Return
commits, Escape cancels; the first line's length is shown against git's 50 and 72), and a command that would want a
terminal fails with git's message instead. Fetch, pull and push are the only commands that may reach the network,
using your own ssh agent and credential helpers.

## Terminal drawer

⌃⌘` (View ▸ Show Terminal, or the terminal button in the toolbar) opens a terminal under the panes, started in the active pane's folder with your login
shell; ⌃⌘` again hides it, and the same shell is there when it comes back. Shown again from another folder, a shell
waiting at its prompt goes to the active pane's folder (a `cd` it runs for you, after clearing anything typed at the
prompt); while a program runs in it, nothing is typed. Drag its top edge to resize it. Files
dropped on it are typed as quoted paths, and Go to Pane Folder types a `cd` to the active pane's folder; neither
presses Return, so nothing runs until you do (a name holding a control character isn't typed at all). Open in
Terminal (⌃⌘T) still opens Ghostty, iTerm, Warp or Terminal.

## Feedback and accessibility

In a repository the status bar under the files says where the branch is and what's changed, from the status
already read: "22 items · main ↑1 · 2 staged · 3 modified · 1 untracked · 10 GB free", or "main · No changes". It
follows the repository as it changes.

The three toolbar buttons show when they're on: the branch turns the accent color while the status shows, the clock
while the history panel shows, the terminal fills while the drawer is open, and each tooltip says what a click does. They're in the default toolbar and can be
removed or moved with Customize Toolbar.

The header names the repository and branch, how far it is from its upstream, any merge or rebase in progress and the
number of stashes, and shows a spinner while git runs. What each command did, or git's own error, shows under the
list and is announced to VoiceOver. Every row has a spoken label ("a.txt, modified, changes hidden", "Hunk 2, lines
30 to 36", "Added: …", a commit's id, subject, author, date and branches). Diff colors are the git status colors,
which keep their contrast in light and dark appearances; added and removed lines also carry their `+` and `-`, so
nothing depends on color alone. Everything is reachable by keyboard; the menus are buttons too.

## Performance

The status view does nothing until it's opened: the pane's own paths gain one comparison each. Git runs off the main
thread; the main thread only lays out rows. `scripts/benchmark-git.sh` measures the pane paths before and after (at
a base commit and at HEAD) and the status view on a 3,000-file repository against the git commands it runs; git
loads, writes and the main-thread apply are signposted for Instruments (Points of Interest, category `git`).
