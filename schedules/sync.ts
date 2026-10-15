import { list } from "../routing/contracts.js";
import type { CountsT, KindT, ReportT } from "./contracts.js";

type Level = "info" | "verbose" | "warn" | "error";
/** One cluster group or interrupt (spec §4): its version and its content, opaque here (each tile's Lua writes it). */
export type Entry = { v: number; content: unknown };
/** What the sync needs from Clusterio (controller.ts) or a test. */
export type Port = {
	/** The running instances: every change goes to each. */
	tiles(): number[];
	name(instanceId: number): string;
	send(instanceId: number, kind: string, payload: object): void;
	log(op: string, phase: string, fields: Record<string, unknown>, level?: Level): void;
};
/** The data file's data (§4): Maps as entry lists, so a name is never an object key. */
export type Saved = {
	groups?: [string, Entry][];
	interrupts?: [string, Entry][];
	counts?: [number, [KindT, string, number][]][];
};
type Counts = Record<KindT, Map<string, number>>;

/** Interrupts first: a tile has an interrupt's content before a group that names it (sync.lua's KINDS). */
export const KINDS: KindT[] = ["interrupt", "group"];
/** §5.5's two sweeps of grace: a name no tile counts at this many checks in a row (10 s apart) is dropped. */
export const GRACE = 3;

const emptyCounts = (): Counts => ({ group: new Map(), interrupt: new Map() });

/** The cluster's groups and interrupts (spec §3, §5.3, §5.5): the master copy, the version rule and the lifetime. */
export class ScheduleSync {
	entries: Record<KindT, Map<string, Entry>> = { group: new Map(), interrupt: new Map() };
	/** Each tile's last counts (§5.4). A stopped tile's stay: its trains still exist in its save. */
	counts = new Map<number, Counts>();
	/** Checks in a row at which no tile counted a name, by kind and name. Not saved: a restart starts it again. */
	private idle = new Map<string, number>();
	/** The last totals broadcast, as JSON; starts as no groups, so an empty cluster says nothing. */
	private sentTotals = JSON.stringify({ groups: [] });

	constructor(private port: Port, saved?: Saved) {
		for (const [name, entry] of saved?.groups ?? []) {
			this.entries.group.set(name, entry);
		}
		for (const [name, entry] of saved?.interrupts ?? []) {
			this.entries.interrupt.set(name, entry);
		}
		for (const [tile, rows] of saved?.counts ?? []) {
			const counts = emptyCounts();
			for (const [kind, name, n] of rows) {
				counts[kind].set(name, n);
			}
			this.counts.set(tile, counts);
		}
	}

	receive(tile: number, kind: string, payload: unknown): void {
		if (kind === "ue.sched.report") {
			this.report(tile, payload as ReportT);
		} else if (kind === "ue.sched.counts") {
			this.count(tile, payload as CountsT);
		}
	}

	/**
	 * §5.3: a report on the current version, or of a name this controller doesn't have, is accepted as v + 1 (1 for
	 * a new name) and goes to every running tile, the reporter's too (it learns the version). Any other report is
	 * refused, and only its tile gets the current version back, which overwrites the edit there: the first edit wins.
	 */
	report(tile: number, r: ReportT): void {
		const entries = this.entries[r.kind];
		const have = entries.get(r.name);
		const fields = { kind: r.kind, name: r.name, tile: this.port.name(tile), base: r.base };
		if (have && r.base !== have.v) {
			this.port.log("ue.sched", "reject", { ...fields, v: have.v });
			this.port.send(tile, "ue.sched.set", { kind: r.kind, name: r.name, v: have.v, content: have.content });
			return;
		}
		const entry: Entry = { v: (have?.v ?? 0) + 1, content: r.content };
		entries.set(r.name, entry);
		this.idle.delete(`${r.kind}:${r.name}`);
		this.port.log("ue.sched", "report", { ...fields, v: entry.v });
		for (const t of this.port.tiles()) {
			this.port.send(t, "ue.sched.set", { kind: r.kind, name: r.name, v: entry.v, content: entry.content });
		}
	}

	/** §5.4: one counts message; first replaces the tile's counts, a later part adds to them. */
	count(tile: number, c: CountsT): void {
		let counts = this.counts.get(tile);
		if (c.first || !counts) {
			counts = emptyCounts();
			this.counts.set(tile, counts);
		}
		for (const [kind, name, n] of list<[KindT, string, number]>(c.rows)) {
			counts[kind].set(name, n);
		}
	}

	/**
	 * §5.5, every 10 s (controller.ts): a name no tile counts at GRACE checks in a row is dropped on every running
	 * tile. ponytail: a deleted instance's counts are never removed, so its names stay listed; drop them with the
	 * instance if that ever matters.
	 */
	sweep(): void {
		const all = [...this.counts.values()];
		for (const kind of KINDS) {
			for (const [name, entry] of [...this.entries[kind]]) {
				const key = `${kind}:${name}`;
				if (all.some(counts => (counts[kind].get(name) ?? 0) > 0)) {
					this.idle.delete(key);
					continue;
				}
				const idle = (this.idle.get(key) ?? 0) + 1;
				if (idle < GRACE) {
					this.idle.set(key, idle);
					continue;
				}
				this.idle.delete(key);
				this.entries[kind].delete(name);
				this.port.log("ue.sched", "drop", { kind, name, v: entry.v });
				for (const t of this.port.tiles()) {
					this.port.send(t, "ue.sched.drop", { kind, name });
				}
			}
		}
		const totals = this.totals();
		const json = JSON.stringify(totals);
		if (json !== this.sentTotals) {
			this.sentTotals = json;
			this.port.log("ue.sched", "totals", { groups: totals.groups.length }, "verbose");
			for (const t of this.port.tiles()) {
				this.port.send(t, "ue.sched.totals", totals);
			}
		}
	}

	/**
	 * Each group's trains cluster-wide, with the per-tile split [tile name, n, stopped]; sorted by name so it compares
	 * stably. A stopped tile (not in tiles()) counts: its trains still exist in its save.
	 */
	totals(): { groups: [string, number, [string, number, boolean][]][] } {
		const running = new Set(this.port.tiles());
		const by = new Map<string, [string, number, boolean][]>();
		for (const [tile, counts] of this.counts) {
			for (const [name, n] of counts.group) {
				if (n > 0) {
					by.set(name, [...by.get(name) ?? [], [this.port.name(tile), n, !running.has(tile)]]);
				}
			}
		}
		const order = (a: string, b: string) => a.localeCompare(b, "en");
		return { groups: [...by].sort(([a], [b]) => order(a, b)).map(([name, tiles]) => [
			name, tiles.reduce((sum, [, n]) => sum + n, 0), tiles.sort(([a], [b]) => order(a, b)),
		]) };
	}

	/** §5.2: a tile's start (or one not synced since this controller started) gets every entry, interrupts first. */
	full(tile: number): void {
		const entries = KINDS.flatMap(kind => [...this.entries[kind]].map(
			([name, e]) => ({ kind, name, v: e.v, content: e.content }),
		));
		this.port.log("ue.sched", "full", { tile: this.port.name(tile), entries: entries.length });
		this.port.send(tile, "ue.sched.full", { entries });
		this.port.send(tile, "ue.sched.totals", this.totals());
	}

	toJSON(): Saved {
		const rows = (counts: Counts) => KINDS.flatMap(
			kind => [...counts[kind]].map(([name, n]): [KindT, string, number] => [kind, name, n]),
		);
		return {
			groups: [...this.entries.group],
			interrupts: [...this.entries.interrupt],
			counts: [...this.counts].map(([tile, counts]): [number, [KindT, string, number][]] => [tile, rows(counts)]),
		};
	}
}
