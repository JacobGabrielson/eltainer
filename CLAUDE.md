# CLAUDE.md — Working notes for Claude in this repo

## Scratch files: use `./tmp/`, not `/tmp/`

This repo has a `tmp/` dir at the top level (gitignored).  Put all
throwaway files — probe scripts, captured output, ad-hoc test elisp,
intermediate artifacts — under `./tmp/` (i.e. `tmp/` relative to the
repo root), not under the system `/tmp/`.

If `tmp/` is missing, just `mkdir -p tmp` and proceed.  The whole
directory is gitignored, so anything you drop in there stays local.

Reasons:
- Scratch files are easy to find again next session.
- Settled into one place, they don't pollute the user's `/tmp` or
  collide with system temp files.
- The user can grep / inspect them without searching the filesystem.

## Avoid gratuitous `cd <dir> && <cmd>` commands

The user runs Claude in a permission-prompted setup where any
`cd path && something` invocation triggers a separate approval from the
plain `something` form.  Don't tack a `cd` onto a command unless you
actually need a different working directory.

In particular:
- `git` operates on the current working tree by default — never
  prepend `cd /path/to/repo && git …`; just run `git …`.
- For commands that *do* need to run somewhere else, prefer the
  command's own working-directory flag (`make -C dir`, `kubectl
  --kubeconfig path`, `git -C dir`, etc.) over `cd dir && …`.
- Use absolute paths when you need to point at a file outside the
  current directory.

If you genuinely need a different `pwd` for a subshell, that's fine —
just don't reach for `cd` reflexively when an in-place form would do.
