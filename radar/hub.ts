import type { OwnT } from "./contracts.js";

/**
 * The controller's hub of the radar sync (radar-sync spec §3, §5). Per radar network (a key) and colour it keeps every
 * hosting tile's own signals and their total. When a tile's own changes, every other host's target (total − its own)
 * changes by the same Δ, sent as ue.radar.delta on the version that host's mirror is at; a host that asks gets its
 * whole target as ue.radar.full. A change applies only on its base, as the circuit link's statuses (circuit §8.3).
 * No state on disk: after a controller restart the tiles' resyncs rebuild it (plan ruling 18).
 */

/** A signal map: "<group>\n<name>" → count; the group is circuit §8.2's type, or "type|quality". */
type Sigs = Map<string, number>;
type Colours = { r: Sigs; g: Sigs };
type Encoded = Record<string, (string | number)[]>;
/** One tile hosting a key: its own at version v; tv is the version of the last target sent to it. */
type Host = { v: number; own: Colours; tv: number; gap: boolean; resent: number };
type Net = { total: Colours; hosts: Map<number, Host> };

export type HubPort = {
	send(id: number, kind: string, payload: object): void;
	log(phase: string, fields: Record<string, unknown>, level?: "info" | "verbose" | "warn"): void;
	now(): number;
};

const COLOURS = ["r", "g"] as const;
/** The own-gap repair's throttle: the circuit link's 120-tick ask (K17), at 60 UPS. */
export const RESEND_MS = 2000;

const colours = (): Colours => ({ r: new Map(), g: new Map() });

function decode(enc: Encoded | undefined, into: Sigs): void {
	for (const [group, list] of Object.entries(enc ?? {})) {
		for (let i = 0; i + 1 < list.length; i += 2) {
			into.set(`${group}\n${String(list[i])}`, Number(list[i + 1]));
		}
	}
}

/** A status for Lua in circuit §8.2's encoding: r and g only when they hold something, base only on a change. */
function status(key: string, v: number, base: number | undefined, m: Colours): Record<string, unknown> {
	const out: Record<string, unknown> = { key, v };
	if (base !== undefined) {
		out.base = base;
	}
	for (const c of COLOURS) {
		const enc: Encoded = {};
		for (const [k, n] of m[c]) {
			const at = k.indexOf("\n");
			const group = k.slice(0, at);
			if (!enc[group]) {
				enc[group] = [];
			}
			enc[group].push(k.slice(at + 1), n);
		}
		if (m[c].size > 0) {
			out[c] = enc;
		}
	}
	return out;
}

export class Hub {
	readonly nets = new Map<string, Net>();
	/** Each live tile's boot id, from its hello and heartbeats. A tile that stopped is absent until its next boot. */
	readonly live = new Map<number, string>();

	constructor(private port: HubPort) { }

	/** A tile's hello or heartbeat (plan ruling 8): a boot not seen before (a start, or ours) resyncs. */
	runtime(id: number, boot: string): void {
		if (this.live.get(id) === boot) {
			return;
		}
		this.live.set(id, boot);
		this.port.send(id, "ue.radar.resync", {});
	}

	/** A tile stopped (§5): its own leaves every other target, so a down tile reads as silence. */
	drop(id: number): void {
		this.live.delete(id);
		for (const [key, net] of [...this.nets]) {
			if (net.hosts.has(id)) {
				this.unhost(key, id, "stopped");
			}
		}
	}

	/** A tile's ue.radar.* message, checked on its bridge. A tile that isn't live is ignored: its resync follows. */
	receive(id: number, kind: string, payload: any): void {
		if (!this.live.has(id)) {
			return;
		}
		const key = String(payload.key);
		if (kind === "ue.radar.own") {
			this.own(id, key, payload as OwnT);
		} else if (kind === "ue.radar.ask") {
			this.full(id, key);
		} else if (kind === "ue.radar.unhost") {
			this.unhost(key, id, "unhost");
		}
	}

	private net(key: string): Net {
		let net = this.nets.get(key);
		if (!net) {
			net = { total: colours(), hosts: new Map() };
			this.nets.set(key, net);
		}
		return net;
	}

	private host(net: Net, key: string, id: number): Host {
		const h: Host = { v: 0, own: colours(), tv: 0, gap: false, resent: -Infinity };
		net.hosts.set(id, h);
		this.port.log("host", { key, instance: id });
		return h;
	}

	/** §5: a full replaces the tile's own; a change applies on its base only; else a gap (circuit §8.3). */
	private own(id: number, key: string, p: OwnT): void {
		const net = this.net(key);
		let h = net.hosts.get(id);
		const changed = colours();
		if (p.base === undefined) {
			if (!h) {
				h = this.host(net, key, id);
			}
			for (const c of COLOURS) {
				const fresh: Sigs = new Map();
				decode(p[c], fresh);
				for (const k of h.own[c].keys()) {
					if (!fresh.has(k)) {
						changed[c].set(k, 0);
					}
				}
				for (const [k, n] of fresh) {
					if (h.own[c].get(k) !== n) {
						changed[c].set(k, n);
					}
				}
			}
			h.gap = false;
		} else if (h && !h.gap && p.base === h.v) {
			for (const c of COLOURS) {
				decode(p[c], changed[c]);
			}
		} else if (h && p.v === h.v) {
			return; // a repeat
		} else {
			if (!h) {
				h = this.host(net, key, id);
			}
			h.gap = true;
			const now = this.port.now();
			if (now - h.resent >= RESEND_MS) {
				h.resent = now;
				this.port.send(id, "ue.radar.resend", { key });
				this.port.log("gap", { key, instance: id, base: p.base, have: h.v });
			}
			return;
		}
		h.v = p.v;
		this.apply(key, net, id, h, changed);
	}

	/** Each changed own value (0: gone) into the tile's own and the total; every other host gets its Δ. */
	private apply(key: string, net: Net, id: number, h: Host, changed: Colours): void {
		let n = 0;
		for (const c of COLOURS) {
			for (const [k, x] of changed[c]) {
				const t = (net.total[c].get(k) ?? 0) + x - (h.own[c].get(k) ?? 0);
				if (x === 0) {
					h.own[c].delete(k);
				} else {
					h.own[c].set(k, x);
				}
				if (t === 0) {
					net.total[c].delete(k);
				} else {
					net.total[c].set(k, t);
				}
				n += 1;
			}
		}
		if (n === 0) {
			return;
		}
		for (const [j, o] of net.hosts) {
			if (j !== id) {
				const delta = colours();
				for (const c of COLOURS) {
					for (const k of changed[c].keys()) {
						// int32, as a wire's sum wraps (circuit §8.6); | 0 is exact on sums of int32s (below 2^53)
						delta[c].set(k, ((net.total[c].get(k) ?? 0) - (o.own[c].get(k) ?? 0)) | 0);
					}
				}
				o.tv += 1;
				this.port.send(j, "ue.radar.delta", status(key, o.tv, o.tv - 1, delta));
			}
		}
	}

	/** §5: a tile that asks gets its whole target, total − its own, at its next version. */
	private full(id: number, key: string): void {
		const net = this.net(key);
		const h = net.hosts.get(id) ?? this.host(net, key, id);
		const target = colours();
		for (const c of COLOURS) {
			for (const [k, x] of net.total[c]) {
				target[c].set(k, (x - (h.own[c].get(k) ?? 0)) | 0);
			}
			for (const [k, x] of h.own[c]) {
				if (!net.total[c].has(k)) {
					target[c].set(k, -x | 0);
				}
			}
			for (const [k, x] of target[c]) {
				if (x === 0) {
					target[c].delete(k);
				}
			}
		}
		h.tv += 1;
		this.port.send(id, "ue.radar.full", status(key, h.tv, undefined, target));
		this.port.log("full", { key, instance: id, n: target.r.size + target.g.size });
	}

	/** §4, §5: the tile stopped hosting key, or stopped: its own leaves the total and the others' targets. */
	private unhost(key: string, id: number, reason: string): void {
		const net = this.nets.get(key);
		const h = net?.hosts.get(id);
		if (!net || !h) {
			return;
		}
		const gone = colours();
		for (const c of COLOURS) {
			for (const k of h.own[c].keys()) {
				gone[c].set(k, 0);
			}
		}
		this.apply(key, net, id, h, gone);
		net.hosts.delete(id);
		if (net.hosts.size === 0) {
			this.nets.delete(key);
		}
		this.port.log("unhost", { key, instance: id, reason });
	}
}
