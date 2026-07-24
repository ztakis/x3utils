# Plan: Make zip3 input policy (v1.2.1 or later)

Status: **PARKED — gated on v1.2.0 field feedback about zip3.**

Nothing here is scheduled. The offline analysis below is done and the findings
are durable, but no code change should land until real v1.2.0 users have
exercised Make zip3 and reported what they actually hit. Two candidate features
are specified so the work can start cold when the feedback justifies it.

Recorded 2026-07-25.

## Why this is parked

Make zip3 shipped in v1.2.0 with a deliberately narrow input contract. Widening
it is speculative until we know which wall people meet first. The whole point of
holding is that the feedback picks the feature, not the analysis.

## What v1.2.0 does today

`Make zip3` accepts a **full 128 KB backup dump only**:

1. `selectFirmwareBin` routes the action down the full-image path, so
   `Firmware.validate(requireSize: true)` demands exactly 131072 bytes.
2. `buildZip3FromDump` applies the SHU key gate at `0x1420` (default key or
   blank passes; anything else is treated as OEM and refused).
3. `Zp.payloadFromDump` recovers the exact slot-0 payload from the device's own
   `ZP` length record, and **fails closed** when no trustworthy record exists.

Banner enforcement is intentionally off at pick time for this action; `detect()`
only preselects the dropdowns and the operator's choice is what gets packed.

Consequence: a dump with no valid `ZP` record — a cleared dump, a rescue image,
or a capture taken after an ST-Link slot-0 write — cannot be packaged at all.

## Feedback to collect from v1.2.0

Before choosing between the candidates below, find out:

- How often does Make zip3 refuse a dump for a missing/invalid `ZP` record, and
  what were those dumps (cleared, rescue, post-ST-Link, or something new)?
- Does anyone actually want to package a **dump** they can't currently use, or
  do they mostly already have a sliced `.bin` in hand and just want it zipped
  without the CLI?
- Does the SHU key gate reject anything people expected to work, beyond the
  known older-repo-firmware exception?
- Any report of a package built by Make zip3 that the BLE app refused, and what
  the app said.

The last one matters most: everything downstream assumes the BLE loader accepts
what we build, and we have no negative evidence either way.

## Established findings (offline, no hardware)

Measured over the local full-dump corpus (40 images, 26 with a `ZP` record) and
the local firmware mirror (29 bins with a readable banner). Corpus locations are
private and deliberately not recorded here.

### Slot-0 region ends

| | region | max payload |
|---|---|---|
| VCU | `0x08001000..0x0800FFFC` | **61436** |
| MCU | `0x08001000..0x0800F7FC` | **59388** |

The quoted end address is the final 4-byte word, so `payload + 4` fills the
region exactly (`61436 + 4 = 0xF000`, `59388 + 4 = 0xE800`).

Confirmations:

- No dump length and no mirror bin length violates the `≡ 4 (mod 8)` invariant
  or exceeds either ceiling.
- The largest shipped VCU image is **exactly 61436 bytes**, filling slot 0 to
  the byte. The ceiling is a designed boundary, not an inferred one.
- `0xF800..0x10000` is all `0xFF` on every MCU dump, independently confirming
  the MCU region end.
- On dumps written to erased flash, the written footprint past the payload is
  **exactly 4 bytes**. Other dumps show `4 + 8k` (12/36/76) as fill periods
  stack on top.

Not resolved offline: whether the "12-byte trailer" families are really 4 bytes
plus one fill period. No corpus dump comes within 124 bytes of a ceiling, so
nothing exercises the tight case. This concerns the trailer's **size only** —
its identity remains closed and is not to be re-investigated.

### Code impact

`Firmware.slot0MaxBytes` is `0x10000` (65536), carrying a `TODO: confirm spec`.
That is too loose by 4100 bytes for VCU and 6148 for MCU: an oversized slot bin
currently passes `validateSlot` and would be written over the slot-1 boundary.
The fix is a per-type maximum with 61436 as the unknown-type fallback (the
bannerless Flash Only path cannot know the type). `Zp._payloadLenAt` uses the
same constant as its upper guard.

This tightening is small, self-contained, and **not** gated on the feedback
above. It can land on its own whenever convenient.

### ZP-less fallbacks, scored against ZP ground truth

Two ways to slice without a `ZP` record, scored on the 26 dumps that have one:

- **ceiling** — take the whole usable region (61436 / 59388).
- **backscan** — last non-`0xFF` byte in the region, minus 4, requiring the
  result to be `≡ 4 (mod 8)`.

```
backscan EXACT   : 3
backscan OVER    : 8   by 8-72 bytes
backscan UNDER   : 0   <-- never truncates live firmware
backscan REFUSED : 15  (mod-8 guard fired)
```

Zero undercuts. Where backscan overshoots it pads by 8-72 bytes, against the
ceiling slice's 120-3968. The mod-8 guard fires on 58% of cases and fails
closed.

This does **not** revive backward-scanning as an exactness claim — the earlier
dead-end verdict stands, because nothing inside a dump distinguishes the exact
hits from the overshoots. Backscan is a *tighter pad*, never a trim.

On the 14 genuinely ZP-less dumps: 5 get a tight backscan, 9 refuse (their junk
fill runs to the region end) and would fall through to the ceiling slice. All 14
pass a vector-table sanity check.

## Candidate A — accept user-sliced bins (recommended first)

Let an operator hand Make zip3 a slot-0 `.bin` directly instead of a full dump.
There is standing demand for this as an alternative to the CLI.

A correctly sliced bin is **exact**, so this sidesteps the padding question
entirely. Validation is strong:

- `length % 8 == 4` — the single best check. Every mirror bin passes; seven of
  every eight wrong cuts fail immediately.
- length within the floor and the per-type ceiling.
- not 131072 (reject a full image) — already in `validateSlot`.
- banner at `0x400` agrees with the declared type/model — `DeviceSpec.verifyBanner`
  already does this.
- vector-table sanity at offset 0.
- SHU key check. Needs a small change: `CompatPatch.offset` is hardcoded to the
  dump-absolute `0x1420`, so a slot bin needs `0x420` — add a base parameter or
  a slot-relative variant.

Plumbing largely exists (`PackV3.makeZipV3`, `packBinToZip`). This is a
validator plus a UI path.

## Candidate B — ZP-less dumps via a slicing ladder

Only if the feedback shows real demand. Rules:

- **R1** — the banner at `0x1400` picks the ceiling, not the dropdown. The
  region end is a physical fact and a wrong Type selection slices at the wrong
  boundary. No readable banner, or banner disagrees with the dropdown: refuse.
- **R2** — keep the existing gates: 128 KB exact, SHU key at `0x1420`.
- **R3** — vector-table sanity at `0x1000` (SP in RAM, reset vector inside slot
  0). `ZP` was the trust anchor; without it, prove slot 0 holds firmware.
- **R4** — mod-8 guard on any derived length; refuse otherwise.
- **R5** — ladder, and label the tier. `ZP` is exact; backscan is padded;
  ceiling is heavily padded. Never present a padded result as exact, and record
  which tier produced the package.
- **R6** — explicit operator opt-in. Tiers 2 and 3 carry junk into the payload,
  and BLE acceptance of a padded payload is unproven.

Two properties to state plainly in the UI if this ships:

- The padding is stale bytes of the previous firmware image. No identity data
  (that lives at `0x1F000`), but a redistributed package carries them along.
- Flashing a padded image makes `ZP` record the padded length permanently, so
  that device's later extractions return the blob rather than the true payload.
  Capped at the ceiling, not unbounded.

## Recommended order

1. Tighten `slot0MaxBytes` to per-type maxima. Independent of the feedback.
2. Collect v1.2.0 zip3 feedback.
3. Candidate A, if the feedback confirms the demand. Exact, strongly
   validatable, no unproven assumption about the BLE loader.
4. Use A as the testbed vehicle for the padding question: slice a known-good
   image deliberately long, pack it, BLE-flash it with an ST-Link backup
   underneath. If the device accepts it, B is derisked; if not, B never ships.
5. Candidate B only after that.

## Open question requiring hardware

Does the BLE loader accept a junk-padded payload? Structurally legal is not the
same as accepted — the same necessary-not-sufficient shape as the SHU key gate.
Step 4 above is the cheapest way to find out.

## Reproducing the analysis

The surveys were one-off scratchpad scripts and are **not** in the repo:
`slot0_tail_survey.dart`, `slot0_ceiling_check.dart`, `backscan_vs_zp.dart`,
`zpless_targets.dart`. They read the private corpus read-only. If this work
proceeds, promote them into `x3utils_flutter/tool/` with the corpus root as an
argument so the numbers can be regenerated on any machine.
