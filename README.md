# doksuela

This repository contains a tool for exploring or managing a DOKS cluster, essentially a front-end to kubectl, doctl, and clusterlint.

Why? Well, if you don't live and breathe kubectl daily, it can sometimes be a bit onerous to find what you're looking for. Moreso for doctl. At the same time, there's a lot of data in there that is obscured away and likely forgotten if you're not actively looking for it.

Sure, there are a handful of web interfaces, but all are lacking in some respect. The DigitalOcean web UI is quite nice, but doesn't give you much depth, being naturally focused on managing DigitalOcean's products and services, resources, that kind of thing. 
Various Kubernetes cluster management tools don't know anything in particular about DigitalOcean or DOKS, which is a problem when you're looking at something that spans both realms.

## Running

doksuela needs Lua 5.5, the [terminal.lua](https://github.com/lunarmodules/terminal.lua) library, and `doctl`, `kubectl`, and `clusterlint` on `PATH`. JSON decoding uses the vendored `dkjson`.

```sh
luarocks --lua-version 5.5 install terminal
lua doksuela.lua
```

The last cluster is remembered, and check results are cached under `~/.cache/doksuela/`, so the next launch draws immediately. Counts stay blue until a check started in this session returns, then turn green. `--cache DIR` uses another cache directory. `--fixture DIR` reads JSON fixtures and does not run the CLIs, which is how the UI is exercised without a cluster. `lua doksuela.lua --help` prints the flags.

## Additional Notes
While this project is currently under active development, feel free to give it a try and post any issues you encounter.  Or start a discussion if you would like to help steer the project in a particular direction.  Early days yet, so a good time to have your voice heard.  As the project unfolds, additional resources will be made available, including platform binaries, more documentation, demos, and so on.

## Repository Information 
[![Count Lines of Code](https://github.com/500Foods/doksuela/actions/workflows/main.yml/badge.svg)](https://github.com/500Foods/doksuela/actions/workflows/main.yml)
<!--CLOC-START -->
```cloc
Last updated at 2026-10-17 00:39:48 UTC
-------------------------------------------------------------------------------
Language                     files          blank        comment           code
-------------------------------------------------------------------------------
Lua                             23            446            120           6262
JSON                            28              0              0            235
Markdown                         3             91              2            191
YAML                             2              8             13             37
Text                             1              0              0              1
-------------------------------------------------------------------------------
SUM:                            57            545            135           6726
-------------------------------------------------------------------------------
3 Files were skipped (duplicate, binary, or without source code):
  gitattributes: 1
  gitignore: 1
  rockspec: 1
```
<!--CLOC-END-->

## Sponsor / Donate / Support
If you find this work interesting, helpful, or valuable, or that it has saved you time, money, or both, please consider directly supporting these efforts financially via [GitHub Sponsors](https://github.com/sponsors/500Foods) or donating via [Buy Me a Pizza](https://www.buymeacoffee.com/andrewsimard500). Also, check out these other [GitHub Repositories](https://github.com/500Foods?tab=repositories&q=&sort=stargazers) that may interest you.
