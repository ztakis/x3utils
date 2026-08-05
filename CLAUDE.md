# x3utils — working instructions

Local and gitignored. Nothing here is published.

## Read first

`AGENTS.md` and `docs/DEVLOG.md` are the handoff surface. Read both before
touching code — they outrank anything remembered about the state of the repo,
and they are written for whoever picks the work up next.

## How to work here

- **Inform and ask before starting.** Explain the finding itself — what it is,
  where, why it matters, what the fix would be — then stop and wait. Finding a
  defect is not authorisation to fix it, and that goes double for problems I
  found on my own rather than was asked about.
- **Discussion by default.** Propose, then ask before editing. Do not start
  writing code because a question implied some.
- **An aside is not a request.** Thinking out loud, a wish, or "I need to figure
  out X" is not authorisation to design X. Offer one line and stop. This is
  scope discipline, not silence — depth is right when asked for, wrong when
  volunteered.
- **Write summaries, not transcripts.** The decision, the surprise, the verdict
  — not the method or a step-by-step. Applies to commit messages, reports and
  any doc.
- **This is embedded work and I cannot verify it.** Chip state, SWD behaviour,
  what the firmware did after a reset — the only witness is a board I cannot
  see. Where a fact IS checkable (the repo, an SDK's source, a git diff), check
  it instead of reasoning about it. Where it is not, name the ONE input that
  discriminates and ask, rather than offering a mechanism.
- **One isolated test per issue.** A run that changes two things answers
  nothing. Synthetic bins exist so guards and refusals can be exercised without
  a scooter.
- **He builds and runs.** Never launch the GUI unasked, never kill his window.
- **Cable contact is the #1 failure.** Before any clever explanation of a
  hardware symptom, it is probably the wire.
- **ST-Link work is best effort.** A cable knocked mid-flow means the user
  restarts, and that is the accepted ceiling. Make failures legible — name the
  step that failed, not the one that noticed — and keep restart cheap. Do not
  build session recovery.

## Never

- **Never patch or neuter firmware validation.** Finding and defeating the
  firmware's own checks is permanently out of scope. Refuse AOB-scanner style
  proposals; do not reopen it.
- **Never put private data in tracked files.** This is a public repo: no local
  paths, no dump hashes, no per-unit serials in anything committed. Privacy is
  structural — gitignored paths, never per-commit exclusions.
- **Never commit the web/webstlink workstream notes.** That work stays out of
  DEVLOG, AGENTS.md, README and the wiki.

## Committing

He commits through GitHub Desktop, so the useful output is paste-ready commit
text: a subject line and a short body, not a changelog. No `Co-Authored-By`
trailer — transparency is handled by a repo-level AI disclosure instead.

Before committing anything under `x3utils_linux/`, reset `TARGET` in `config.sh`
back to Mode B.
