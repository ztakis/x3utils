# Plan: retry timer (v1.2.1 or later)

Status: **IMPLEMENTED for v1.2.1** on 2026-07-28 (planned and built the same
day; the planning history below is kept because it records what was ruled out
and why). Maintainer-run hardware results on Windows / mode A are in
`docs/DEVLOG.md` under 2026-07-28. The hold test and audio remain proposals.

## Purpose: what this is for

The single most common real-world failure in x3utils is a lost SWD / C45 contact.
That is not a new finding — the tool's own failure screen already says so:

> OpenOCD: adapter init failed
> Most failures are a lost SWD / C45 contact — re-seat it, keep it steady, then
> press Retry.

What is new is seeing the context the message is read in. Field photos taken
2026-07-28 show the real usage: the scooter on the ground, the dash cracked open
on the stem, jumper wires draped over the handlebar under gravity with nothing
securing them, and the laptop out of reach at an angle in poor light while the
operator has one hand on a probe.

In that setting the current recovery loop is:

1. lose contact, operation fails
2. let go of the probe
3. go to the laptop
4. click **Retry**
5. come back and re-seat the wires

Steps 2–4 are the problem. The operator cannot hold the contact and reach the
keyboard at the same time, and every failure costs a round trip.

> **The feature exists so that a failed connect can be recovered without letting
> go of the probe.**

That is the whole justification. A retry that still needs a click solves nothing
for the person in that photo.

## Scope

### v1.2.1: the third hand

Decided 2026-07-28. v1.2.1 ships the smallest thing that removes the round trip:
**press the Retry the app already shows, automatically, ~3 s after the failure
lands.** Nothing more — no new loop primitive, no new mode, no new action.

The mental model is a third hand at the laptop doing exactly what the operator
would have done, while both of theirs stay on the probe.

Shape:

- a settings line, default ~3 s (below)
- reuses `retry()`, the same entry point the button calls
- armed from the one place the red screen is set (below)
- covers every connect failure except RDP and Power-race (below)
- arms only on the connect-failure class (see the guard below)
- the Retry button becomes the countdown; **Dismiss** stays live (below)
- gives up after 10 attempts and hands back to the manual button

A settings line:

```
Retry interval:   -  3  +        (0 = disabled)
```

Same plumbing as the existing countdown setting — a session value plus a
persisted startup default, clamped. Each OpenOCD attempt costs roughly a second,
so the 2–5 s range is where this should feel responsive while a wire is being
worked; 3 s is the shipping default and the field can move it.

`0 = disabled` preserves today's behavior exactly, and stays reachable for anyone
who wants the manual prompt.

**The loop is bounded — it gives up after 10 attempts.** Auto-retry is not
unbounded hammering: if the contact has not caught by then the loop stops on its
own and lands on the normal failure screen with the manual **Retry** back. The
reason is the operator this feature exists for — the one case where the loop runs
unwatched is the one where they walked away, and OpenOCD should not be
relaunching by itself indefinitely on an unattended machine.

**Attempts, not elapsed seconds.** A retry re-runs the action, so an attempt is
not a fixed-cost probe — its duration varies by mode and by the pre-connect
countdown setting. A time bound would therefore yield a random number of attempts
(many in a fast-failing mode, few in a guided one): same setting, different
behavior, and nothing on screen to show how much budget is left. A count is
consistent across modes and is already the number being displayed. At roughly
4–6 s per attempt, 10 is about a minute — already a long time to hold a probe
against a contact that is not taking.

### Controls while it runs

The Retry button **becomes** the countdown, and stops being a button:

```
Retrying in 3…  (4 of 10)
```

- the primary button is **inert** while auto-retry is armed — it is a status
  readout, not a control. The operator's hands are on the probe; the only reason
  to reach the laptop is to stop.
- **Dismiss is the live control** and the way out. It already renders exactly
  when `!failureNeedsInput` (`main.dart`), which is the same case auto-retry arms
  in, so no new button and no new condition.
- Enter fires the primary on the fail stage today (`_onEnter`). While auto-retry
  runs it should do nothing, matching the existing rule that running stages
  ignore Enter.

### Where it hooks: the red screen

Rather than wiring a timer per action, arm it **wherever the red screen
appears**. That is one place: `_set()` in `lib/app_controller.dart` is the single
funnel every failure goes through, and `StageState.fail` is what paints the hero
red (`AppColors.danger`). One `if` at the moment the state turns fail — arm if
eligible — and one cancel on every other transition (`_set` to anything else,
`_goIdle`, `cancel`, and a real `retry()` press) covers the whole surface without
touching a single action's code path.

Two details that make this work:

- `_setInputFailure` sets `_failureNeedsInput` **before** calling `_set`, so the
  eligibility check can read the flag from inside `_set` and correctly refuse to
  auto-retry a policy failure. Preserve that order.
- **Power-race has no such screen by construction, so the hook cannot misfire
  there.** `runRace` only returns on success or on `kill()` — a failed connect in
  mode D never lands on the fail state, it just becomes attempt N+1. The mode
  exclusion below is belt and braces on top of that, not the only thing holding.

### What it covers

An earlier draft narrowed v1.2.1 to the four standard actions and modes A/B.
**That narrowing was a budget decision, not a correctness one, and the red-screen
hook removes the budget argument.** The predicate that actually matters — "this
run never got past connect" — is action- and mode-agnostic, so covering more
costs nothing, while carving actions out means writing an allowlist that would
not otherwise need to exist. Under this design the exclusions *are* the extra
work. So v1.2.1 covers everything that fails at connect, minus two exclusions:

| | |
|---|---|
| `check`, `dump`, `flash_compat`, `flash_backup` | in |
| `flash_only`, `flash_slot0` | in — a failed connect writes nothing, exactly as for the two flash actions above, so the escape hatches carry no extra risk here |
| modes A, B **and C** | in |
| `make_zip3` | moot — offline packer, never connects; its failures are input failures the gate already refuses |
| `rdp_check`, `rdp_rescue` | **excluded** — different mechanism, needs its own pass |
| mode D · Power-race | **excluded** — its own respawn loop, and it cannot reach the screen anyway |

**The RDP path needs its own pass.** Those two actions reach the fail screen
through a different mechanism — a live process waiting on stdin (see Traps) —
and the hook site is shared, so the eligibility check has to exclude them
explicitly rather than by accident.

The one place "just press the button" is not literally right: `retry()` also
serves failures that are **not** a lost contact. On a validation or policy
failure it returns to setup, and on a "flash wrote data, but verification was not
confirmed" failure it re-runs the write. A third hand would do neither
unattended. So the timer still needs an eligibility gate even though the action
it performs is unchanged — it arms only when the run never got past connect.

**Beyond that gate, nothing about the run is special-cased.** An automatic press
does exactly what a manual press does: same `retry()`, same code path, including
replaying the pre-connect countdown in modes A and B. That countdown already
replays on a manual Retry today, so it is not a cost this feature introduces, and
skipping or shortening it for automatic presses would make the third hand behave
differently from the hand it stands in for. It does what the user would do,
period.

Everything below stays on the plan and is **not** v1.2.1.

### Later: hold test

Not a separate subsystem — the **same loop with a different exit condition**.

| | repeat while | stops on | reports |
|---|---|---|---|
| retry | attempt failed | first success | success/failure |
| hold test | attempt count < N | count exhausted | pass rate, e.g. `8/10` |

Rationale: a contact good enough to pass one probe is not necessarily good enough
to survive a 128 KB read. Pass/fail says nothing about stability; a pass rate
does. This is the decision the operator is actually making before committing to a
dump — right now it is made blind, and the answer arrives as a dump that died
partway.

Implementation note: the repeated variant should use a bare `init` / `exit`
rather than `reset halt`. Resetting the board once a second for ten seconds is a
poor way to prove that a wire is steady.

## Deferred, not rejected

**Audio feedback** — distinct tones for connected / failed / complete. Agreed
valuable, and arguably worth more than any visual change in the field, where the
screen may be unreadable or out of reach entirely. Deferred because it is new
ground for this project and a real amount of work.

Cheap-path check before budgeting it: determine whether Flutter's
`SystemSound.play()` actually works on Windows, Linux and macOS desktop. If it
does, success/fail tones are close to free. If it does not, it needs a package
plus per-OS assets, and it waits behind the retry timer.

## Settled for v1.2.1

- **Interval** — a settings line, shipping default ~3 s, `0 = disabled`.
- **Coverage** — every connect failure, in modes A/B/C and in Standard *and*
  Advanced actions. Excluded: `rdp_check`, `rdp_rescue`, and mode D Power-race.
- **Where it lives** — a timer in `lib/app_controller.dart` firing the existing
  `retry()`, armed from the one place the red screen is set. No new loop
  primitive: pressing the button is the whole mechanism.
- **Bounded** — 10 attempts, counted not timed, then back to the manual button.
- **Controls** — the Retry button becomes an inert `Retrying in 3… (4 of 10)`
  readout; **Dismiss** stays live and is the way out.
- **No special-casing** — an automatic press runs exactly what a manual press
  runs, pre-connect countdown included.

## Open questions

- Whether the attempt cap stays a constant or ever becomes a second settings
  line. A constant for v1.2.1; the field can say whether 10 was right.
- Which *failures* are retry-eligible — now the **only** real gate, since the
  action and mode filters have been reduced to two exclusions. The hazard is not
  the failed connect (that writes nothing;
  `guided_rescue` shutdown-errors before any write runs, though confirm rather
  than assume); it is a failure *after* a successful connect. "Flash wrote data,
  but verification was not confirmed" and "a complete dump was not confirmed"
  both currently offer a plain **Retry**, so a naive timer would re-run a write
  that already went out, unattended, every 3 s. Eligibility has to key off "never
  got past connect", not off the button label.
- Whether `dump` re-running on a timer can leave a partial backup file behind,
  or whether `ConfirmedFileWriter` already makes that a non-issue.
- Whether the hold test is its own action or a mode of Check connection.

## Traps

- **The two-layer retry is deliberate — do not "fix" it.** There is an inner
  retry inside the OpenOCD target configs (examine and halt loops) and an outer
  loop in the CLI scripts. The outer deliberately does not fire on the inner.
  Collapsing them is an easy and expensive mistake.
- **Mode B parking on the guided Continue is known and accepted.** An automatic
  Retry in C45 · Clone lands back on `Hold C45 → GND` and waits for the human
  "I'm holding — continue" press, so it cannot save the round trip there. A
  mode-B exclusion was considered and rejected: the Auto-retry setting already
  turns it off for anyone who does not want it. Do not add the exclusion, and
  do not auto-press Continue — that press asserts a physical fact no timer can
  know.
- **If auto-retry ever widens to the RDP actions, that path is not a re-run.**
  `rdp_check` and `rescue_unlock` print a prompt and wait on stdin; there
  `retry()` restarts nothing, it writes a newline to the live process. It is
  arguably the *cheapest* path to automate rather than one to avoid —
  `sendContinue()` already returns false once the process has moved on, which is
  the guard a timer would need — but it is a different mechanism wearing the same
  button, and v1.2.1 leaves it manual.
- The CLI release trees (`x3utils_win/`, `x3utils_linux/`, `x3utils_mac/`)
  already carry shell retry loops. They are prior art to learn from, not files to
  change as part of this work.
- If this ships, keep the version sync: `VERSION`, `pubspec.yaml`, `kAppVersion`
  and `installer.iss`.

## Done means

`flutter analyze` clean, the focused tests passing, and `git diff --check` clean.
No packaged build or hardware result is claimed unless the maintainer ran it.
