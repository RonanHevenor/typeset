# Typeset

A Mac app that lays out a tabloid newspaper. Typeset removes a lot of the tedium associated with making a newspaper in InDesign. It simultaneously removes a lot of user control and opportunity for creativity.

Typeset was built for *The Polytechnic*, RPI's independent student newspaper. As a result, the app has some very strong opinions. All the settings to change those opinions are in code, so the look of the paper changes by editing `HouseStyle.swift`. The paper's name, website, staff and
nameplate are settings and require no code changes.

## Getting started

You're going to need macOS 14 or later and the Swift toolchain that comes with Xcode or the Command Line Tools.

```bash
git clone https://github.com/RonanHevenor/typeset.git
cd typeset
./build.sh
```
