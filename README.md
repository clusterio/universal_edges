# Universal Edges v2

Links Clusterio instances along their edges for Factorio 2.1. Belts, fluids, power, trains, vehicles, players, circuit networks and logistic requests cross from one server to the next. Trains route and keep their schedules across servers, and radars share what they see. Its prototypes ship as the `universal_edges` mod.

## Requirements

- Clusterio 2.0, built from source: a checkout of tag `v2.0.2` or later in the 2.0 series. The plugin builds inside Clusterio's pnpm workspace. 2.0.0-alpha.27 and older lack APIs this uses, and Clusterio 2.1 may change the plugin API.
- Node 22 or later, and pnpm at the version in Clusterio's `packageManager`.
- `zip` (the mod build), and `lua5.2` and `luacheck` (tests and lint).

## Install

In a Clusterio checkout:

```sh
git clone https://github.com/clusterio/universal_edges.git external_plugins/universal_edges
pnpm install
pnpm build
pnpm run -r --if-present prepare
```

`prepare` compiles the plugin, bundles its web page and zips its mod to `dist/universal_edges_<mod version>.zip`. The mod's version is the package's, kept in step in `mod/info.json`. Add the plugin to the controller's plugin list with `npx clusteriocontroller plugin add ./external_plugins/universal_edges` and to each host's with `npx clusteriohost plugin add ./external_plugins/universal_edges`, from the checkout (a path needs the `./`). Upload the mod with `npx clusterioctl mod upload external_plugins/universal_edges/dist/universal_edges_<mod version>.zip`, and add it to the instances' mod pack with `npx clusterioctl mod-pack edit <pack> --add-mods universal_edges:<mod version>`.

## Test and lint

Run these from inside the Clusterio checkout, where ESLint is installed:

```sh
pnpm --filter universal_edges run test   # TypeScript and Lua unit tests; run prepare first
pnpm --filter universal_edges run lint   # ESLint with Clusterio's rules, and luacheck
```

Game tests (headless Factorio, the `*_game_test.lua` files) and multi-instance end-to-end tests run from the clusterio-v2 integration repo, which isn't public. The design documents that code comments cite by section (§) live there too.

## Release

```sh
npm version minor   # or major/patch: bumps package.json and mod/info.json, commits and tags v<version>
git push --follow-tags
```

A pushed `v*` tag runs CI's release job once the tests pass. It publishes the package to npm through trusted publishing (no token), and uploads `universal_edges_<version>.zip` to the [mod portal](https://mods.factorio.com/mod/universal_edges) with the `FACTORIO_MOD_TOKEN` secret, a factorio.com API key with the "ModPortal: Upload Mods" usage.

## Licence

Blue Oak Model License 1.0.0, in `LICENSE.md`.
