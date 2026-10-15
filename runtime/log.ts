import type * as lib from "@clusterio/lib";

/** Log one lifecycle phase (spec §7.2): "<op> <phase>", with op, phase and fields as top-level metadata. */
export function lifecycle(
	logger: lib.Logger,
	op: string,
	phase: string,
	fields: Record<string, unknown> = {},
	level: "info" | "verbose" | "warn" | "error" = "info",
): void {
	logger.log(level, `${op} ${phase}`, { ...fields, op, phase });
}

/**
 * A warner for repeated warnings (spec §7.2). Each key reaches the log at most once per window (60 s),
 * and each line carries `count`: the occurrences since the key's previous line, this one included.
 */
export function rateLimited(logger: lib.Logger, windowMs = 60_000, now: () => number = Date.now) {
	const last = new Map<string, { at: number; count: number }>();
	return (key: string, message: string, fields: Record<string, unknown> = {}): void => {
		const at = now();
		const entry = last.get(key);
		if (entry && at - entry.at < windowMs) {
			entry.count += 1;
			return;
		}
		logger.warn(message, { ...fields, count: (entry?.count ?? 0) + 1 });
		// ponytail: an unbounded set of keys never expires; a global clear at 1000 is enough for SP0's fixed
		// set of task/warning names. Switch to per-key TTL eviction if hostile input can mint new keys.
		if (last.size >= 1000) {
			last.clear();
		}
		last.set(key, { at, count: 0 });
	};
}
