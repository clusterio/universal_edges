import * as fs from "node:fs/promises";
import * as lib from "@clusterio/lib";

/** Upgrades a data file's `data` by one schema: migrations[n - 1] takes schema n to n + 1. */
export type Migration = (data: any) => any;

/**
 * The data of a stored `{ schema, data }`, brought to the latest schema (migrations.length + 1).
 * It never wipes: a schema this code doesn't know, or a value that isn't a data file, throws.
 */
export function upgrade(file: unknown, migrations: Migration[]): unknown {
	const latest = migrations.length + 1;
	const stored = typeof file === "object" && file !== null ? file : {};
	const { schema, data } = stored as { schema?: unknown; data?: unknown };
	if (typeof schema !== "number" || !Number.isInteger(schema) || schema < 1 || schema > latest) {
		throw new Error(`data file schema ${String(schema)} is not one this code can read (1 to ${latest})`);
	}
	let result = data;
	for (let from = schema; from < latest; from++) {
		result = migrations[from - 1](result);
	}
	return result;
}

/** Load a file written by saveDataFile; undefined when it doesn't exist yet. */
export async function loadDataFile(file: string, migrations: Migration[]): Promise<unknown> {
	let text: string;
	try {
		text = await fs.readFile(file, "utf8");
	} catch (err: any) {
		if (err.code === "ENOENT") {
			return undefined;
		}
		throw err;
	}
	return upgrade(JSON.parse(text), migrations);
}

/** Write `{ schema: latest, data }` atomically (spec §7.4). */
export async function saveDataFile(file: string, migrations: Migration[], data: unknown): Promise<void> {
	await lib.safeOutputFile(file, JSON.stringify({ schema: migrations.length + 1, data }, null, "\t"));
}
