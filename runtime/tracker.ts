export type Rollback = { instanceId: number; tick: number; lastTick: number };

/** In-process rollback listeners: UE's own subsystems, and other plugins via "universal_edges/runtime". */
export const rollbackListeners = new Set<(rollback: Rollback) => void>();

/**
 * The last game tick each instance's Lua runtime reported, in hellos and heartbeats (spec §7.5).
 * A report below it means the server went back in time: restored from an older save, or rolled back.
 */
export class RuntimeTracker {
	private lastTick: Map<number, number>;

	constructor(
		saved: Record<string, number>,
		private onListenerError: (err: Error) => void = () => undefined,
	) {
		this.lastTick = new Map(
			Object.entries(saved)
				.filter(([, tick]) => Number.isInteger(tick))
				.map(([id, tick]): [number, number] => [Number(id), tick]),
		);
	}

	/** Record a report. When its tick went back, notify the listeners and return the rollback. */
	observe(instanceId: number, tick: number): Rollback | undefined {
		const last = this.lastTick.get(instanceId);
		this.lastTick.set(instanceId, tick);
		if (last === undefined || tick >= last) {
			return undefined;
		}
		const rollback = { instanceId, tick, lastTick: last };
		for (const listener of rollbackListeners) {
			try {
				listener(rollback);
			} catch (err) {
				this.onListenerError(err as Error);
			}
		}
		return rollback;
	}

	toJSON(): Record<string, number> {
		return Object.fromEntries(this.lastTick);
	}
}
