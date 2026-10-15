// The player-crossing spec's record (§5): where each player crossed, and where they left, kept on the controller in
// memory until their next join anywhere. Not persisted: a restart loses crossings in flight, which then land at the
// player's old body, pulled inside (§6.3).

export type CrossingEntry = {
	to: number; key: string; from: number; x: number; y: number; surface: string; trace: string;
};
export type Arrival = {
	key: string; x: number; y: number; surface: string; trace: string;
	left?: { x: number; y: number; surface: string };
};

type Entry = CrossingEntry & { at: number };
type Left = { from: number; x: number; y: number; surface: string; at: number };
type Crossing = { entries: Entry[]; left?: Left };

export class CrossingRecords {
	static TTL_MS = 600_000;
	static CAP = 1024;
	/** Insertion order is age: a write deletes and re-sets a player, so the first key is the oldest. */
	private records = new Map<string, Crossing>();

	constructor(private now: () => number = Date.now) { }

	private fresh(at: number) {
		return this.now() - at <= CrossingRecords.TTL_MS;
	}

	/** A resolved crossing (§4 step 2): replaces an older entry to the same instance; a stale record starts over. */
	cross(player: string, entry: CrossingEntry): void {
		let record = this.records.get(player);
		if (record && !record.entries.some(e => this.fresh(e.at))) {
			record = undefined;
		}
		record ??= { entries: [] };
		record.entries = record.entries.filter(e => e.to !== entry.to);
		record.entries.push({ ...entry, at: this.now() });
		this.records.delete(player);
		this.records.set(player, record);
		while (this.records.size > CrossingRecords.CAP) {
			this.records.delete(this.records.keys().next().value!);
		}
	}

	/** A leave from a zone (§4 step 5); false when the player has no record, and nothing is kept. */
	left(player: string, left: Omit<Left, "at">): boolean {
		const record = this.records.get(player);
		if (!record) {
			return false;
		}
		record.left = { ...left, at: this.now() };
		return true;
	}

	// A join (§5): the newest fresh entry to instance, with the leave point if it came from that entry's source, and
	// the entry's age in ms for the log. The whole record goes either way: a join ends the crossing, so no older
	// arrival is ever applied (finding 2).
	join(player: string, instance: number): { arrival: Arrival; age: number } | undefined {
		const record = this.records.get(player);
		this.records.delete(player);
		const entry = record?.entries.filter(e => e.to === instance && this.fresh(e.at)).at(-1);
		if (!record || !entry) {
			return undefined;
		}
		const { key, x, y, surface, trace } = entry;
		const l = record.left;
		const left = l && l.from === entry.from && this.fresh(l.at)
			? { x: l.x, y: l.y, surface: l.surface } : undefined;
		const arrival: Arrival = left ? { key, x, y, surface, trace, left } : { key, x, y, surface, trace };
		return { arrival, age: this.now() - entry.at };
	}
}
