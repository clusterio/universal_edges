import type { NetT, TargetsT } from "../../power/contracts.js";
import { PowerHub, type Knobs } from "../../power/hub.js";
import { solve, type Flows, type Mode, type Usage } from "../../power/solve.js";
import { rng } from "./world59.js";

/**
 * The power hub's model (power hub spec §11.2, plan Task 5), the gate before any game work: simulated tiles, their
 * link ends and the real PowerHub. Each tile is one electric network that the game's class rule solves every tick
 * (solve.ts over one pool with no stock, plan ruling 1); each link end follows the tile's rules (§6, Tasks 7 and 8);
 * the hub (§8) runs a round every 60 ticks. Deterministic: a seeded PRNG sets every phase. Energy in J, flows in kW;
 * x kW for a tick is x × 1000 / 60 J. No tests here: power_model.test.ts drives it and checks §3's bar.
 */

/**
 * One tile's network: solar (kW at second s), steam (kW), accumulators (a count: 5 MJ and 300 kW each, full unless
 * accEmpty) and a secondary load (kW at second s).
 */
export type NetSpec = {
	solar?: (s: number) => number;
	steam?: number;
	acc?: number;
	accEmpty?: boolean;
	load?: (s: number, tick: number) => number; // seconds, and the tick
};
/**
 * links: pairs of network indices; link i's key is `l<i>` on both sides. delay: ticks for reports, targets, offers
 * and acks alike.
 */
export type WorldOpts = {
	nets: NetSpec[]; links: [number, number][]; delay: number; seed: number; knobs?: Partial<Knobs>;
};

const J = 1000 / 60; // J that 1 kW gives in a tick
const KW = 60 / 1000; // kW that 1 J gives in a tick
const TW = 1e9; // the prototype's 1 TW limit, kW
const ACC_J = 5e6;
const ACC_KW = 300;
const STALE = 300; // §6.3: a target older than this (ticks) is none
const BACKOFF_MIN = 300; // the stream lane's re-offer backoff (ledger_core.lua), doubling to BACKOFF_MAX
const BACKOFF_MAX = 3600;
const ROUND = 0; // the hub's round, at this tick of every 60
const SAMPLES = 6; // §6.1: six samples, 10 ticks apart, a report
const FIELDS = ["so", "po", "se", "to", "pd", "sd", "td"] as const;
const FIELD = { solar_output: "so", primary_output: "po", secondary_output: "se", tertiary_output: "to" } as const;
const zero = (): Flows => ({ so: 0, po: 0, se: 0, to: 0, pd: 0, sd: 0, td: 0 });

/**
 * One end of a link: its interface (§5: mode, limits, energy and buffer in J) and its endpoint's data (§6.2–§6.3:
 * n and b in kJ, tat, owe in J, sent and got in kJ) and its outbound stream lane (acked, next, backoff).
 */
export class End {
	partner!: End;
	mode: Mode | "built" = "built";
	out = TW;
	inp = TW;
	e = 0;
	buf = 10e6;
	n = 0;
	b = 0;
	tat = -Infinity;
	busy = false;
	owe = 0;
	sent = 0;
	got = 0;
	acked = 0;
	next = 0;
	backoff = BACKOFF_MIN;
	/** Deactivated (scenario S7): it doesn't poll, isn't reported and stays in the built state (§6.3). */
	off = false;
	/** Removed: torn down, its interface gone. */
	gone = false;
	/** What this tick's network update saw: the interface's mode, offer and demand (kW; Task 5 ruling F4). */
	seen: Mode | "built" = "built";
	o = 0;
	d = 0;
	constructor(readonly key: string, readonly net: Net, readonly phase: number) { }
}

/**
 * A tile: one electric network, its accumulators and its link ends, the pool (§4).
 * ponytail: the accumulators are one bank (equal, so they charge and discharge alike); model them one by one if a
 * scenario ever mixes sizes.
 */
export class Net {
	readonly ends: End[] = [];
	readonly accC: number;
	readonly accR: number;
	accE: number;
	/**
	 * The last tick: the engine's offers and demands (kW), its usages, the steam's and solar's offers and outputs and
	 * the accumulators' (kW; negative while charging).
	 */
	f = zero();
	u!: Usage;
	steamOffer = 0;
	solarOffer = 0;
	steam = 0;
	solar = 0;
	acc = 0;
	/** The tick its last targets arrived. */
	arrived = -1;
	sums = zero();
	samples = 0;
	constructor(readonly id: number, readonly spec: NetSpec, readonly phase: number) {
		this.accC = (spec.acc ?? 0) * ACC_J;
		this.accR = (spec.acc ?? 0) * ACC_KW;
		this.accE = spec.accEmpty ? 0 : this.accC;
	}

	/** The pool's energy and capacity (J), over its interfaces that aren't removed. */
	pool(): { a: number; c: number } {
		let a = 0;
		let c = 0;
		for (const e of this.ends) {
			if (!e.gone) {
				a += e.e;
				c += e.buf;
			}
		}
		return { a, c };
	}

	/** §4: a new total A2 (J) written back at one fill ratio over the pool's interfaces of capacity c. */
	write(A2: number, c: number): void {
		const r = A2 / c;
		for (const e of this.ends) {
			if (!e.gone) {
				e.e = r * e.buf;
			}
		}
	}
}

const built = (e: End) => {
	e.mode = "built";
	e.out = TW;
	e.inp = TW;
};

export type Removal = { owe: number; paid: number; cancelled: number; unpaid: number; lane: number; dropped: number };

export class World {
	/** The tick last stepped (−1 before the first). */
	tick = -1;
	readonly nets: Net[];
	readonly links: [End, End][];
	readonly hub: PowerHub;
	readonly initial: number;
	generated = 0;
	consumed = 0;
	/**
	 * Energy dropped at a removal less the owe no refund cancelled (energy the far side got and this side never
	 * paid), J.
	 */
	lost = 0;
	/** Energy sent over links, J. */
	moved = 0;
	/**
	 * Each removal's owe (J): at the removal, paid by teardown, cancelled by the refund, unpaid; and what was in its
	 * lanes and what was dropped.
	 */
	readonly removals: Removal[] = [];
	/** §3 steady: each round where a link's sender differs from the previous round's (a round sending 0 has none). */
	readonly flips: { tick: number; key: string }[] = [];
	private senders = new Map<string, number>();
	/** Messages by the tick they arrive. */
	private readonly queue = new Map<number, Array<() => void>>();

	constructor(private readonly o: WorldOpts) {
		const rand = rng(o.seed);
		const phase = () => Math.floor(rand() * 60);
		this.nets = o.nets.map((spec, i) => new Net(i + 1, spec, phase()));
		this.links = o.links.map(([x, y], i) => {
			const a = new End(`l${i}`, this.nets[x], phase());
			const b = new End(`l${i}`, this.nets[y], phase());
			a.partner = b;
			b.partner = a;
			this.nets[x].ends.push(a);
			this.nets[y].ends.push(b);
			return [a, b];
		});
		this.initial = this.nets.reduce((s, n) => s + n.accE, 0);
		this.hub = new PowerHub({
			now: () => this.tick * 1000 / 60,
			send: (id, targets) => {
				for (const [key, t] of Object.entries(targets.l)) {
					if (t.n > 0) {
						this.senders.set(key, id);
					}
				}
				this.later(() => this.targets(id, targets));
			},
		}, o.knobs);
	}

	/** The end of link i on network index net. */
	end(i: number, net: number): End {
		return this.links[i].find(e => e.net === this.nets[net])!;
	}

	step(): void {
		this.tick += 1;
		const t = this.tick;
		const due = this.queue.get(t);
		if (due) {
			this.queue.delete(t);
			for (const f of due) {
				f();
			}
		}
		if (t % 60 === ROUND) {
			const before = this.senders;
			this.senders = new Map();
			this.hub.round();
			for (const [key, id] of this.senders) {
				if ((before.get(key) ?? id) !== id) {
					this.flips.push({ tick: t, key });
				}
			}
		}
		for (const [a, b] of this.links) {
			for (const e of [a, b]) {
				if (!e.gone && !e.off && t % 60 === e.phase) {
					this.poll(e);
					// the visit's lanes after the poll (lanes.visit): a remainder whose backoff is up re-offers.
					// ponytail: an end is visited only at its poll; the walk rests between periods (scheduler_core)
					if (e.sent > e.acked && t >= e.next) {
						this.offer(e);
					}
				}
			}
		}
		const s = Math.floor(t / 60);
		for (const n of this.nets) {
			this.engine(n, s, t);
		}
		for (const n of this.nets) {
			if (t % 10 === n.phase % 10) {
				this.sample(n);
			}
		}
	}

	/** Σ stored + in the lanes − Σ owe + lost − (initial + generated − consumed), J: 0 when energy is conserved. */
	ledger(): number {
		let held = 0;
		for (const n of this.nets) {
			held += n.accE;
			for (const e of n.ends) {
				held += e.e - e.owe + (e.sent - e.partner.got) * 1000;
			}
		}
		return held + this.lost - (this.initial + this.generated - this.consumed);
	}

	/** S7: a deactivated end doesn't poll and takes the built state at once (Task 7's deactivated hook). */
	deactivate(e: End, off: boolean): void {
		e.off = off;
		if (off) {
			built(e);
		}
	}

	/**
	 * S7: link i is removed on both tiles (§6.4, plan review S4). Each end pays its owe from its pool as far as it
	 * holds; its interface's energy goes into the pool's other interfaces, then the accumulators, and the rest is
	 * dropped. Then each lane's refund, what its partner never credited, cancels the owe first; the rest goes to the
	 * accumulators (the interface is gone) and the remainder is dropped. An owe no refund cancels is counted in lost.
	 */
	// ponytail: both ends close in one tick and the refund lands at once; its energy goes to accumulators or is
	// dropped either way (the interface is gone), so the close's round trip changes nothing the ledger sees
	remove(i: number): void {
		const r = { owe: 0, paid: 0, cancelled: 0, unpaid: 0, lane: 0, dropped: 0 };
		for (const e of this.links[i]) {
			r.owe += e.owe;
			const { a, c } = e.net.pool();
			const pay = Math.min(e.owe, a);
			if (pay > 0) {
				e.net.write(a - pay, c);
				e.owe -= pay;
				r.paid += pay;
			}
			e.gone = true;
			const others = e.net.pool();
			const put = Math.max(0, Math.min(e.e, others.c - others.a));
			if (put > 0) {
				e.net.write(others.a + put, others.c);
			}
			r.dropped += this.toAcc(e.net, e.e - put);
			e.e = 0;
			e.buf = 0;
		}
		for (const e of this.links[i]) {
			const back = (e.sent - e.partner.got) * 1000;
			r.lane += back;
			e.sent = e.partner.got;
			const cancel = Math.min(e.owe, back);
			e.owe -= cancel;
			r.cancelled += cancel;
			r.dropped += this.toAcc(e.net, back - cancel);
			r.unpaid += e.owe;
			this.lost -= e.owe;
			e.owe = 0;
		}
		this.lost += r.dropped;
		this.removals.push(r);
	}

	/** What fits in the network's accumulators goes there; returns the rest (dropped). */
	private toAcc(n: Net, joules: number): number {
		const put = Math.max(0, Math.min(joules, n.accC - n.accE));
		n.accE += put;
		return joules - put;
	}

	private later(f: () => void): void {
		const at = this.tick + this.o.delay;
		const list = this.queue.get(at);
		if (list) {
			list.push(f);
		} else {
			this.queue.set(at, [f]);
		}
	}

	/**
	 * Task 7's handler (§6.2): each key held here stores n, b and the tick, and takes its class and cap at once (the
	 * cap on that side, 0 on the other), or with no m the built state. An end that doesn't poll stays built (§6.3).
	 * A remainder already pending at the previous targets is nudged: it re-offers at the end's next visit instead of
	 * waiting out its backoff (plan review M1).
	 */
	private targets(id: number, msg: TargetsT): void {
		const net = this.nets[id - 1];
		net.arrived = this.tick;
		for (const e of net.ends) {
			const x = msg.l[e.key];
			if (e.gone || !x) {
				continue;
			}
			e.n = x.n;
			e.b = x.b;
			e.tat = this.tick;
			if (e.off || !x.m) {
				built(e);
			} else if (x.m === "secondary_input") {
				e.mode = x.m;
				e.inp = x.k;
				e.out = 0;
			} else {
				e.mode = x.m;
				e.out = x.k;
				e.inp = 0;
			}
			const busy = e.sent > e.acked;
			if (busy && e.busy) {
				e.backoff = BACKOFF_MIN;
				e.next = 0;
			}
			e.busy = busy;
		}
	}

	/** Task 7's poll (§6.3, plan ruling 3): pay, freshness, buffer, send. */
	private poll(e: End): void {
		if (e.partner.gone) {
			return;
		}
		const n = e.net;
		const p = n.pool();
		const pay = Math.min(e.owe, p.a);
		if (pay > 0) {
			n.write(p.a - pay, p.c);
			p.a -= pay;
			e.owe -= pay;
		}
		if (this.tick - e.tat > STALE) {
			built(e);
			return;
		}
		const B = Math.max(1000 * e.b, e.e);
		if (B !== e.buf) {
			// Task 5 ruling F3: a changed buffer rewrites the pool at one fill ratio. A buffer shrunk to its stored
			// energy would otherwise sit full (room 0) until the pool's next write, and take none of its share of an
			// export.
			p.c += B - e.buf;
			e.buf = B;
			n.write(p.a, p.c);
		}
		const x = Math.min(e.n, Math.floor((p.a + 1000 * e.b - e.owe) / 1000));
		if (x > 0 && e.sent === e.acked) {
			e.sent += x;
			this.moved += 1000 * x;
			const take = Math.min(1000 * x, p.a);
			if (take > 0) {
				n.write(p.a - take, p.c);
			}
			e.owe += 1000 * x - take;
			this.offer(e);
		}
	}

	/**
	 * The stream lane's offer (ledger_core.lua): the total sent so far reaches the partner after the delay; the next
	 * re-offer waits a backoff that doubles each time.
	 */
	private offer(e: End): void {
		e.next = this.tick + e.backoff;
		e.backoff = Math.min(2 * e.backoff, BACKOFF_MAX);
		const total = e.sent;
		this.later(() => this.credit(e.partner, total));
	}

	/** Task 7's credit (§6.4, T2): only what fits, at one fill ratio over the pool; the ack carries the total got. */
	private credit(r: End, total: number): void {
		if (r.gone) {
			return; // a removed lane: the refund settles it
		}
		const d = total - r.got;
		if (d > 0) {
			const p = r.net.pool();
			const x = Math.min(d, Math.floor((p.c - p.a) / 1000));
			if (x > 0) {
				r.net.write(p.a + 1000 * x, p.c);
				r.got += x;
			}
		}
		const recv = r.got;
		this.later(() => this.ack(r.partner, recv));
	}

	/**
	 * The ack (ledger_core.lua): what wasn't credited stays pending. An ack with progress resets the backoff, and a
	 * remainder then re-offers at once, in the same batch (lanes.lua's perf item 1); one without waits its backoff.
	 */
	private ack(s: End, recv: number): void {
		if (s.gone) {
			return;
		}
		const progress = recv > s.acked;
		s.acked = recv;
		if (progress) {
			s.backoff = BACKOFF_MIN;
			s.next = 0;
			if (s.sent > s.acked && !s.off) {
				this.offer(s);
			}
		}
	}

	/** One tick of the game's class rule on one network (plan ruling 1), with its link interfaces and accumulators. */
	private engine(n: Net, s: number, t: number): void {
		const solar = n.spec.solar?.(s) ?? 0;
		const steam = n.spec.steam ?? 0;
		const load = n.spec.load?.(s, t) ?? 0;
		const aOut = Math.min(n.accR, n.accE * KW);
		const aIn = Math.min(n.accR, (n.accC - n.accE) * KW);
		const f: Flows = { so: solar, po: 0, se: steam, to: aOut, pd: 0, sd: load, td: aIn };
		for (const e of n.ends) {
			if (e.gone) {
				continue;
			}
			const held = Math.max(0, e.e) * KW;
			const room = Math.max(0, e.buf - e.e) * KW;
			e.seen = e.mode;
			if (e.mode === "built") {
				e.o = Math.min(TW, held);
				e.d = Math.min(TW, room);
				f.to += e.o;
				f.td += e.d;
			} else if (e.mode === "secondary_input") {
				e.o = 0;
				e.d = Math.min(e.inp, room);
				f.sd += e.d;
			} else {
				e.o = Math.min(e.out, held);
				e.d = 0;
				f[FIELD[e.mode]] += e.o;
			}
		}
		const { u } = solve([{ ...f, a: 0, c: 0 }]);
		for (const e of n.ends) {
			if (e.gone) {
				continue;
			}
			if (e.mode === "built") {
				e.e += (u.st * e.d - u.to * e.o) * J;
			} else if (e.mode === "secondary_input") {
				e.e += u.sq * e.d * J;
			} else {
				e.e -= u[FIELD[e.mode]] * e.o * J;
			}
		}
		n.accE += (u.st * aIn - u.to * aOut) * J;
		n.f = f;
		n.u = u;
		n.steamOffer = steam;
		n.solarOffer = solar;
		n.steam = u.se * steam;
		n.solar = u.so * solar;
		n.acc = u.to * aOut - u.st * aIn;
		this.generated += (n.steam + n.solar) * J;
		this.consumed += u.sq * load * J;
	}

	/**
	 * Task 8's walk and sample (§6.1, plan review S3): an interface whose end doesn't poll or has no fresh target
	 * takes the built state; then the engine's flows less the pool's own interfaces as that network update saw them
	 * (Task 5 ruling F4: read after the tick, an interface emptied in it showed its offer as generation), clamped at 0.
	 * Every sixth sample a report.
	 */
	private sample(n: Net): void {
		const own = zero();
		for (const e of n.ends) {
			if (e.gone) {
				continue;
			}
			if (e.off || this.tick - e.tat > STALE) {
				built(e);
			}
			if (e.seen === "built") {
				own.to += e.o;
				own.td += e.d;
			} else if (e.seen === "secondary_input") {
				own.sd += e.d;
			} else {
				own[FIELD[e.seen]] += e.o;
			}
		}
		for (const k of FIELDS) {
			n.sums[k] += Math.max(0, n.f[k] - own[k]);
		}
		n.samples += 1;
		if (n.samples < SAMPLES) {
			return;
		}
		const ready = n.ends.filter(e => !e.gone && !e.off);
		if (ready.length > 0) {
			let a = 0;
			let c = 0;
			for (const e of n.ends) {
				if (!e.gone) {
					a += e.e - e.owe;
					c += e.buf;
				}
			}
			const f = zero();
			for (const k of FIELDS) {
				f[k] = Math.floor(n.sums[k] / SAMPLES);
			}
			const net: NetT = { a: Math.floor(a / 1000), c: Math.floor(c / 1000), f,
				l: ready.map(e => [e.key, e.sent, e.got]) };
			this.later(() => this.hub.report(n.id, { nets: [net] }));
		}
		n.sums = zero();
		n.samples = 0;
	}
}
