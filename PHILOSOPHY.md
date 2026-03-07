# Philosophy

## Origin

aid started as a personal Neovim config. It grew because a specific problem needed
solving: the gap between the raw power of nvim/tmux/opencode and the friction required
to actually use them productively from day one.

VS Code with Copilot works out of the box. The terminal equivalents — Neovim, tmux,
opencode — are individually more capable, more composable, more efficient in token
usage, and far easier to extend (custom commands, `AGENTS.md`, tool definitions). But
they demand weeks of configuration before they match what VS Code gives in five
minutes. Most people never get there.

aid exists to close that gap.

## What aid is

**A smooth on-ramp.** aid absorbs the friction at the seams between tools so users
get the power without the configuration hell. Three persistent panes — file browser,
editor, AI assistant — that work together on first launch, survive reboots and SSH
drops, and stay coherent across git operations.

**An orchestrator, not a distribution.** LazyVim configures an editor. aid builds a
workspace around one. The distinction matters: aid's job is not to be the best Neovim
config, it is to make Neovim, tmux, and opencode feel like a single product.

**A `curl | bash` that actually works.** The install must produce a fully working IDE
on a fresh machine with no post-install configuration required. If a user has to edit
a file before the session is useful, that is a bug.

## The seam rule

Aid's scope is defined by a single question:

> Does this reduce friction at a seam between tools?

A seam is anywhere two tools meet and the meeting is rough: config files that conflict,
env vars that leak, plugins that don't know about each other, a workflow that requires
five manual steps. Smoothing seams is aid's job.

If a feature reduces friction at a seam, it belongs. If it adds capability unrelated
to a seam — a new editor feature, a personal workflow preference, a nice-to-have — it
does not belong, no matter how small.

This means aid will sometimes absorb bugs that technically belong to upstream tools.
That is intentional. The target user should not need to know or care that
`GIT_DIR` leaks across lazygit calls or that `vim.fn.match()` rejects glob patterns.
Aid owns the consequences of the architectural choices it makes.

## The target user

Someone coming from VS Code and GitHub Copilot. Reasonably technical. Not a terminal
native. Has heard that Neovim is faster, that tmux is powerful, that opencode is
better than Copilot — but bounced off the configuration overhead.

This profile is the concrete filter for feature decisions. When evaluating something
new, the question is: **does this unblock that specific person from getting value in
their first session?** If the answer is no, or "only for someone already comfortable
in the terminal", it is out of scope.

## What keeps it from bloating

Not a line count cap. Not a plugin count limit. Those are proxies.

The actual constraint is staying focused on seams. Seams are finite — there are only
so many places where nvim, tmux, and opencode meet. Once those seams are smooth, the
project is done. New features that don't address a seam are scope creep regardless of
their size.

The practical warning signs:

- **Duplicating what a plugin already owns.** If nvim-tree handles file filtering,
  aid's job is to feed it the right patterns — not to reimplement filtering.
- **Personal config bleeding in.** Anything a user would reasonably want to change
  for their own workflow belongs in user-land, not in aid's base config.
- **Fixing seams that aid didn't create.** If a rough edge exists regardless of
  whether aid is installed, it is an upstream bug to report, not an aid feature to
  ship.

## On layers and orchestrators

The deeper insight aid demonstrates is that layers and orchestrators are underrated.
Opencode makes LLMs more useful by giving them structure, context, and composable
tools. Aid does the same for the terminal environment: it makes individually powerful
tools accessible by handling their coordination.

The value is not in the components — nvim, tmux, and opencode exist without aid. The
value is in the layer that makes them coherent. That layer should be as thin as
possible while still doing its job.
