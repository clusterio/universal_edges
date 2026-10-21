import { randomBytes } from "node:crypto";

/** A random 8-hex-digit boot id, new at every process (or Factorio) start (spec §7.2). */
export function newBootId(): string {
	return randomBytes(4).toString("hex");
}

const processBootId = newBootId();
let seq = 0;

/** `<bootId>.<seq>` for this process. The boot id is new at each start, so ids stay unique across restarts. */
export function newId(): string {
	seq += 1;
	return `${processBootId}.${seq}`;
}
