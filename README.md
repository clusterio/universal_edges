# Universal Edges v2

Links Clusterio instances along their edges for Factorio 2.1. Belts, fluids, power, trains, vehicles, players, circuit networks and logistic requests cross from one server to the next. Trains route and keep their schedules across servers, and radars share what they see. Its prototypes ship as the `universal_edges` mod.

## Requirements

- Clusterio 2.0, built from source: a checkout of tag `v2.0.2` or later in the 2.0 series. The plugin builds inside Clusterio's pnpm workspace. 2.0.0-alpha.27 and older lack APIs this uses, and Clusterio 2.1 may change the plugin API.
- Node 22 or later, and pnpm at the version in Clusterio's `packageManager`.
- `zip` (the mod build), and `lua5.2` and `luacheck` (tests and lint).

## Install

In a Clusterio checkout:

```sh
git clone -b v2 https://github.com/clusterio/universal_edges.git external_plugins/universal_edges
pnpm install
pnpm build
pnpm run -r --if-present prepare
```

`prepare` compiles the plugin, bundles its web page and zips its mod to `dist/universal_edges_<mod version>.zip`, the version in `mod/info.json` (2.1.3). Add the plugin to the controller's plugin list with `npx clusteriocontroller plugin add ./external_plugins/universal_edges` and to each host's with `npx clusteriohost plugin add ./external_plugins/universal_edges`, from the checkout (a path needs the `./`). Upload the mod with `npx clusterioctl mod upload external_plugins/universal_edges/dist/universal_edges_<mod version>.zip`, and add it to the instances' mod pack with `npx clusterioctl mod-pack edit <pack> --add-mods universal_edges:<mod version>`.

## Test and lint

Run these from inside the Clusterio checkout, where ESLint is installed:

```sh
pnpm --filter universal_edges run test   # TypeScript and Lua unit tests; run prepare first
pnpm --filter universal_edges run lint   # ESLint with Clusterio's rules, and luacheck
```

Game tests (headless Factorio, the `*_game_test.lua` files) and multi-instance end-to-end tests run from the clusterio-v2 integration repo, which isn't public. The design documents that code comments cite by section (§) live there too.

## Licence

Blue Oak Model License 1.0.0, in `LICENSE.md`.
