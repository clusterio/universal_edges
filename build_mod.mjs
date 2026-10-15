// Zips mod/ to dist/<name>_<version>.zip under a <name>_<version>/ root, as Factorio loads it and Clusterio's
// ModInfo.fromModFile reads it. Kept timestamps and no directory entries (-D) make an unchanged mod zip to the same
// bytes, so its sha1 in a mod pack changes only when the mod does. Needs the zip command.
import { execFile } from "node:child_process";
import { cp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";

const here = import.meta.dirname;
const { name, version } = JSON.parse(await readFile(join(here, "mod", "info.json"), "utf8"));
const root = `${name}_${version}`;
const stage = join(here, "dist", "mod-stage");
const zip = join(here, "dist", `${root}.zip`);
await rm(stage, { recursive: true, force: true });
await cp(join(here, "mod"), join(stage, root), { recursive: true, preserveTimestamps: true });
await rm(zip, { force: true });
await promisify(execFile)("zip", ["-q", "-X", "-D", "-r", zip, root], { cwd: stage });
await rm(stage, { recursive: true, force: true });
