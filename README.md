# Typeset

A Mac app that lays out a tabloid student newspaper. Paste stories in, rank them, and get a paper; then edit the
pages directly. It exports print-ready PDF, and IDML for anyone who finishes in InDesign.

Typeset was built for *The Polytechnic*, RPI's independent student newspaper. As a result, the app has some very strong opinions. All the settings to change those opinions are in code, so the look of the paper changes by editing `HouseStyle.swift`. The paper's name, website, staff and
nameplate are settings and require no code changes.

## Getting started

You're going to need macOS 14 or later and the Swift toolchain that comes with Xcode or the Command Line Tools.

```bash
git clone https://github.com/RonanHevenor/typeset.git
cd typeset
./build.sh            # swift build, assemble build/Typeset.app, sign ad hoc, open
```

`./build.sh --no-open` builds without opening; `tools/make_dmg.sh` then packages it as `build/Typeset.dmg`. Every push
to `main` is built on GitHub Actions.
