# TimeZigs

TimeZigs is a Renoise tool that adds fast and customizable creation of patterns and phrases in multiple time signatures.

It provides a 4×4 preset grid plus a `CUSTOM` mode, live readouts for `Lines` / `LPB` / `Beat Duration`, basic presets, and quick-create keybindings for instant pattern/phrase generation.

Based on Esa Ruoho’s Paketti [Slab O Patterns](https://github.com/esaruoho/paketti/blob/master/PakettiSlabOPatterns.lua).

<img width="499" height="555" alt="image" src="https://github.com/user-attachments/assets/2f361277-45be-4f8f-bbfc-699589ee520a" />

## Download

Grab the latest alpha version at https://github.com/untilde/timezigs/releases/tag/Alpha

Since it's still a very experimental tool, feel free to open Issues or send Pull Requests.

## Features

- Creates patterns or instrument phrases for any time signature without changing your Lines-Per-Beat (LPB) setting.
- Automatically writes `ZLxx` (LPB) on the first line of generated patterns and phrases.
- 4 preset slots for custom time signatures.
- Shows current Time Signature, `Lines`, `LPB`, and `Beat Duration` (lines per beat). Updates on LPB change.
- Optional `Fill notes` (experimental) mode places note markers per beat using the `Delay` column for fractional timing.
- Optional section naming: append current time signature and `LPB` to the section name.
- Safe/Integer Line mode (Allow only integer beat durations): highlights non-integer presets and blocks creation unless the bar length is a whole number of lines. Disable to allow approximation (more accurate at higher `LPB`).

## Usage

Open via `Main Menu → Tools → TimeZigs`.

Available keybinds (set in Renoise preferences):
- `Pattern Editor: TimeZigs: Toggle`
- `Global: TimeZigs: Toggle`
- `Create Patterns – Presets 01–16` (16 = Currently set Custom Time Signature)
- `Create Patterns – Custom Preset Slots 01–04`
- `Create Phrases – Presets 01–16`
- `Create Phrases – Custom Preset Slots 01–04`

### Custom Time Signatures
- Use `+` / `-` to adjust `Numerator (n)` and `Denominator (d)`.
- Right panel has four slots:
  - Click a slot to load its `n/d` into Custom.
  - Click the disk icon to save the current Custom `n/d` into that slot.


https://github.com/user-attachments/assets/a6f39099-db27-4428-b825-eca30329ac29


## Understanding Time Signatures and LPB

To use TimeZigs effectively, it helps to separate two ideas:

- Time signature (music theory):
  - `n` (numerator) = how many beats are in one bar.
  - `d` (denominator) = which note value counts as one beat: `2` = half, `4` = quarter, `8` = eighth, `16` = sixteenth, `32` = thirty-second.
  - Examples: `3/4` = three quarter‑note beats per bar; `6/8` = six eighth‑note beats per bar.

- LPB (Lines‑Per‑Beat):
  - The resolution of the tracker grid — how many lines represent one beat.
  - Changing `LPB` changes grid density for the pattern editor.

TimeZigs decouples these concepts: pick any `n/d`, and the tool computes how many lines each beat and bar should span at the current `LPB`, then creates patterns/phrases accordingly and writes `ZLxx` so the `LPB` travels with the content.

### What about time signatures that result in float pattern sizes?

### Examples

Example 1: `4/4` at `8 LPB`

```
Lines per beat = (8 * 4) / 4 = 8
Lines per bar  = 4 * 8 = 32
```

Example 2: `5/8` at `8 LPB`

```
Lines per beat = (8 * 4) / 8 = 4
Lines per bar  = 5 * 4 = 20
```

In the two examples above, everything lines up cleanly. Perfect integer grid, no fractional rounding.

But, wait...
What if:

Example 3: `8/6` at `8 LPB`

```
Lines per beat = (8 * 4) / 6 = 5.333...
Lines per bar  = 8 * 5.333... = 42.666...
```

Now we have a fractional bar length: `42.666...` lines. Renoise patterns can only have whole-number line counts, because each line is a discrete grid row.

If the result isn’t a whole number of lines (e.g., some odd denominators at low `LPB`), Safe/Integer Line mode (default ON) will highlight and block creation. Disable it in Settings to allow approximation and generate patterns/phrases with rounded line counts (higher `LPB` improves accuracy). In Example 3, the pattern would round to `43` lines.

In Safe/Integer Line mode, the tool detects float beat durations and refuses to create such patterns, highlighting the “non-integer” time signatures. That’s because `42.66` lines/bar doesn’t fit cleanly on the grid — the last beat would land partway through a line.

If you want to avoid these float pattern durations, keep Safe mode enabled.

If Safe Mode is off, the tool rounds to the nearest integer:

```
42.666... → 43 lines/bar
```

That makes the time signature approximate. However, the beats are slightly stretched (each now ≈ `5.375` lines instead of `5.333`), which creates a slow drift over many bars — small, but perceptible in mathematically tight material.

The higher the `LPB`, the smaller the rounding error per beat. For instance, at `LPB = 64`, the same `8/6` bar becomes:

```
Lines per beat = (64 * 4) / 6 = 42.666...
Lines per bar  = 8 * 42.666... = 341.333... (rounded to 341)
```

Now the error per beat is negligible (≈ `0.008` lines per beat), effectively inaudible and visually consistent.

See Technical notes below for exact formulas and the To Do for future improvements.


## Settings (collapsible)
- Sync Denominator and LPB (default OFF): when enabled, changing the `Denominator (d)` sets `LPB` accordingly and creation uses the synced `LPB` (writes `ZLxx` with that value). Prevents fractional beat lengths; disable to keep `LPB` and `d` independent.
- Global Custom Denominator: when enabled, the preset grid uses your custom denominator.
- Custom Section Name.
- Append Time Signature and LPB to Section Name.
- Fill notes (experimental): inserts one note per beat across the created bar; uses `Delay` for fractional placement.
- Safe/Integer Line mode — Allow only integer beat durations (default ON):
  - Subtly marks non-integer presets in the grid.
  - Blocks Create Patterns/Phrase when the bar length is not an integer number of lines at the current `LPB`.
  - Disable to allow approximation; higher `LPB` improves accuracy.

## Technical notes

Formulas:

```
BeatDuration(lines) = (LPB * 4) / d
LinesPerBar         = round(n * (4 / d) * LPB)
```

Constraints and validation:
- A beat must be at least `1` line long. If `(LPB * 4) / d < 1`, the tool warns and aborts.
- Higher denominators (e.g., `d = 24`, `32`) generally require higher `LPB` to avoid sub-line beats.
- When Safe Mode is disabled, some combinations round to the nearest whole line due to the discrete grid.
- Denominator range: `2–32`.
- Numerator range: `1–32`.
- Pattern creation writes `ZLxx` on Master to carry `LPB` with the pattern; Phrase creation sets `phrase.lpb` and mirrors `ZL` for parity.

## To Do

- Enhance delay column calculation and fill marker placement. Example:
  - `d = 13` at `LPB = 4` → `~1.23` lines/beat
  - Delay offsets ≈ `00`, `3B`, `76`, `B1`, …
  - Pattern “slides” over time, since it doesn’t divide the grid evenly

- Change fill options: give different resolutions based on current time signature (half, double, etc).
- Show next delay value for current beat length and create a keybind to automatically insert it (for example, if you have a float line count, read the previous and current line in the editor and print the next needed delay column value to stay on grid).

-- Custom metronome: instrument with different sound options.

- Metronome sequencer: use the canvas to sequence metronome patterns or derive them from current timesig. Store sequences in JSON (e.g., `o` = strong beat, `x` = weak, `-` = silence; append delay info if needed).
- Refactor the UI code for clarity.
- Refactor fill function based on the metronome settings.
- Adapt the Paketti keyhandlers to make the UI fully controllable from keyboard.

## Credits

Based on Esa Ruoho's work in Paketti [Slab O Patterns](https://github.com/esaruoho/paketti/blob/master/PakettiSlabOPatterns.lua).
