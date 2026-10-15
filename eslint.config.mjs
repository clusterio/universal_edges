// ESLint with Clusterio's rules: the Clusterio checkout's root eslint.config.mjs, whose TypeScript sections apply only
// to {packages,plugins}/**, plus a copy of each for this plugin's files. Run it inside a Clusterio checkout.
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";

const TS_FILES = "{packages,plugins}/**/*.ts?(x)";
// The checkout's root, found through @clusterio/lib's real path, so it works from a symlinked or real directory.
const lib = createRequire(import.meta.url).resolve("@clusterio/lib/package.json");
const root = path.resolve(path.dirname(lib), "..", "..");
const base = (await import(pathToFileURL(path.join(root, "eslint.config.mjs")).href)).default;

function swap(pattern) {
	if (pattern === TS_FILES) {
		return "**/*.ts?(x)";
	}
	return Array.isArray(pattern) ? pattern.map(swap) : pattern;
}

function isTs(pattern) {
	return pattern === TS_FILES || (Array.isArray(pattern) && pattern.includes(TS_FILES));
}

export default [
	...base,
	...base
		.filter(section => section.files?.some(isTs))
		.map(section => ({ ...section, files: section.files.map(swap) })),
];
