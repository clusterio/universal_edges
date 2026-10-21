// Zips mod/ to dist/<name>_<version>.zip under a <name>_<version>/ root, as Factorio loads it and Clusterio's
// ModInfo.fromModFile reads it. Kept timestamps and no directory entries (-D) make an unchanged mod zip to the same
// bytes, so its sha1 in a mod pack changes only when the mod does. Needs the zip command.
// The mod's version is the package's: `node build_mod.mjs --sync` writes it into mod/info.json (npm version's
// version script), and a build with the two apart fails.
import { execFile } from "node:child_process";
import { cp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";

const here = import.meta.dirname;
const infoPath = join(here, "mod", "info.json");
const info = await readFile(infoPath, "utf8");
const { name, version } = JSON.parse(info);
const pkg = JSON.parse(await readFile(join(here, "package.json"), "utf8")).version;
if (process.argv.includes("--sync")) {
	// a replace, not JSON.stringify, so the file keeps its layout
	await writeFile(infoPath, info.replace(/("version"\s*:\s*)"[^"]*"/, `$1"${pkg}"`));
	process.exit(0);
}
if (version !== pkg) {
	throw new Error(`mod/info.json is at ${version} but package.json at ${pkg}; run node build_mod.mjs --sync`);
}
const root = `${name}_${version}`;
const stage = join(here, "dist", "mod-stage");
const zip = join(here, "dist", `${root}.zip`);
await rm(stage, { recursive: true, force: true });
await cp(join(here, "mod"), join(stage, root), { recursive: true, preserveTimestamps: true });
await rm(zip, { force: true });
await promisify(execFile)("zip", ["-q", "-X", "-D", "-r", zip, root], { cwd: stage });
await rm(stage, { recursive: true, force: true });
