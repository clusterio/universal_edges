// Oxlint with Clusterio's rules: the Clusterio checkout's root .oxlintrc.json, whose overrides for TypeScript and web
// code apply only to {packages,plugins}/**, pointed at this plugin's files. Run it inside a Clusterio checkout.
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

// The checkout's root, found through @clusterio/lib's real path, so it works from a symlinked or real directory.
const lib = createRequire(import.meta.url).resolve("@clusterio/lib/package.json");
const root = path.resolve(path.dirname(lib), "..", "..");
const base = JSON.parse((await readFile(path.join(root, ".oxlintrc.json"), "utf8")).replace(/^\/\/.*$/gm, ""));

function swap(pattern) {
	return pattern.replace("{packages,plugins}/*/", "").replace("{packages,plugins}/", "");
}

export default { ...base, overrides: base.overrides.map(o => ({ ...o, files: o.files.map(swap) })) };
