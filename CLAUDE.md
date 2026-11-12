# Typeset: notes for coding agents

This file is the single source of instructions for AI coding agents working in this repository. `AGENTS.md` points
here; edit this file, not that one. Keep it current: when a change makes something below wrong (a command, a path,
a rule), fix this file in the same commit.

## What it is

A macOS app (SwiftUI + AppKit, Swift Package, no Xcode project) that lays out a tabloid student newspaper in
The Polytechnic's house style. `README.md` is the full user and design documentation. Read the section for whatever
you're changing before you change it, and update it in the same commit when behaviour changes.

## Build, run, test

```bash
./build.sh                      # release build → build/Typeset.app, signed ad hoc, opened
./build.sh --no-open            # build only
./build.sh --no-open --public   # without Resources/Private: the app as a fresh clone gets it
tools/make_dmg.sh [out.dmg]     # package build/Typeset.app as a disk image
GALLEY_DATA_DIR=<scratch dir> build/Typeset.app/Contents/MacOS/Typeset --selftest
```

- Always point `GALLEY_DATA_DIR` at a scratch folder for test runs and headless runs. Without it the app reads and
  writes the real `~/Library/Application Support/Typeset`.
- `--selftest` needs a seed issue (`Resources/Private/seed-issue.json` and `SeedMedia/`), which isn't in the
  repository. Without one it exits 2 with a message. On the maintainer's seed, 7 checks under "make" / "make
  fixes" / the front-page Header fail on `main` already, and the "Make Component on each page" check varies from
  run to run. Compare against a run of the code before your change, not against zero failures.
- Headless modes (`--render`, `--make-components`, `--fetch`, `--snapshot`) are documented in `README.md` › Headless.
- CI (`.github/workflows/build.yml`) builds the public app on every push to `main` and on pull requests, checks that
  it launches headless, and uploads a DMG. It can't run the self-tests (no seed).

## Layout

- `Sources/Typeset/`: the app. Some starting points:
  - `HouseStyle.swift`: every measurement, colour and face of the paper. The look changes here.
  - `Setup.swift`: onboarding. Font check (`FontCheck`), the paper's settings (`Paper`, `PaperSettings`), the
    *Set Up Typeset* window.
  - `Composer*.swift`: setting type and drawing pages. `Generator.swift` makes a paper from ranked stories.
  - `Store*.swift`: the issue being edited (`IssueStore`). `Components.swift` / `BuiltInComponents.swift`: the
    component system and the shipped Header and Folio.
  - `IDMLExport.swift`: InDesign export. `PolyWeb.swift`: reading stories from poly.rpi.edu, only when setup's
    website is that site.
  - `SelfTest*.swift`: the `--selftest` checks.
- `Resources/`: what ships. `Components/` (Header and Folio, written by `--make-components` with no nameplate or
  website, which `BuiltInComponents.withPaper` fills in from setup), `IDML/` (InDesign package parts), the icon.
- `Resources/Private/` (gitignored): a paper's own fonts, `paper.json`, nameplate, and seed issue. `build.sh`
  bundles it as the app's defaults.
- `tools/`: resource generators (`make_resources.py`, `make_idml_templates.py` need The Polytechnic's source files
  and aren't runnable from a clone, except `make_resources.py icon`), `make_components.sh`, `make_dmg.sh`.
- `repro/`: image-diff and comparison scripts. `repro/notes/` (gitignored) holds local bug notes that comments
  sometimes cite.

## Rules

- **Never commit fonts or a paper's real content.** Minion Pro, Myriad Pro and Utopia Std are Adobe's and can't be
  redistributed. Raleway is OFL, but the modified Bold instance can't carry its Reserved Font Name. Real stories,
  photos, staff names and nameplates belong in `Resources/Private/`. Test fixtures and placeholders use made-up
  names. Before committing, check that `git status` shows nothing under `Resources/Private`, `repro/notes`, or any
  `.otf`/`.ttf`.
- The app has to work with none of `Resources/Private`: no fonts (system fallbacks), no seed (an empty issue), no
  nameplate, no staff. Check `./build.sh --public` after touching resources, setup or startup.
- New faces the house style uses go in `FontCheck.faces` (and `README.md`'s font table), so setup reports them.
- If you change `HouseStyle.Front` or `HouseStyle.Folio`, run `tools/make_components.sh` (after `./build.sh
  --no-open`) and commit the regenerated `Resources/Components`.
- Commit messages are one plain sentence saying what changed, as the user sees it (see `git log`).
- License: GPL-3.0-only (`LICENSE`). Don't add dependencies under incompatible licenses.
