# For Claude

The rules of this repository are in `AGENTS.md`, loaded here in full:

@AGENTS.md

## Where you are running

If `~/.claude/CLAUDE.md` exists, you are on the maintainer's computer: work as his rules say.

If it does not, you are a cloud thread. None of his tools, guards, test databases or auditors
exist here. Do only what your project's instructions allow in the cloud. If you have no such
instructions, change no file: read, then report what you found and that the change needs a
thread on his computer. Never merge, deploy, release or mark a pull request ready from the
cloud.

## Audit

A change to anything but Markdown gets one audit by another vendor's model before it goes
live. Until that audit has run, the pull request stays a draft with `Audit pending` at the top
of its description. Once it has finished, the description carries, alone on a line,
`Audit: done by <auditor>, <rounds and outcome>`. Never write that line for an audit that did
not run and finish.

GitHub refuses to merge a pull request whose newest commit has no audit stamp. Once the audit
has finished and its fixes are pushed, the session that ran it, on the maintainer's computer,
runs `~/.claude/bin/audit-stamp --by "<model>" --outcome "<rounds and what came of them>"` in
the pull request's checkout; that marks the newest commit and writes the `Audit: done by` line.
For Markdown only, run `audit-stamp --prose`; `audit-stamp --waived` only when the maintainer
said to skip the audit for that task. A commit pushed after the stamp needs a new one. The tool
exists only on his machines: a cloud thread cannot stamp.
