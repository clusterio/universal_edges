import type { InstancePluginContext } from "@clusterio/host";
import { on, rateLimited, type Bridge, type Handler } from "../runtime/index.js";
import {
	PlayerCrossPayload, PlayerCrossRequest, PlayerJoinRequest, PlayerJoinedPayload, PlayerLeftEvent, PlayerLeftPayload,
	type EdgeRecord, type PlayerTarget,
} from "./contracts.js";
import type { CrossingResolver } from "./index.js";

// Players crossing (player-crossing spec §4–§6): a zone key resolved to an instance, the record kept on the controller
// (edges/crossings.ts), and the join that fetches the arrival. Message classes live in edges/contracts.ts, re-exported
// here so consumers of this task import them from one place.
export {
	PlayerCrossPayload, PlayerCrossRequest, PlayerJoinRequest, PlayerJoinedPayload, PlayerLeftEvent, PlayerLeftPayload,
	PlayerTargetSchema, type PlayerTarget,
} from "./contracts.js";

export type InstanceFacts = { name: string; host?: number; status: string; gamePort?: number };

// The instance a zone key leads to from `from` (§4 step 2): `edge:<id>` → the edge's partner; another prefix → its
// registered resolver; or why there is none.
export function destination(
	key: string,
	from: number,
	surface: string,
	edge: (id: string) => EdgeRecord | undefined,
	resolver: (prefix: string) => CrossingResolver | undefined,
): number | string {
	const colon = key.indexOf(":");
	if (colon <= 0) {
		return "unknown_zone";
	}
	const prefix = key.slice(0, colon);
	if (prefix === "edge") {
		const record = edge(key.slice(colon + 1));
		if (!record || record.deleted) {
			return "unknown_edge";
		}
		if (record.a.instanceId === from) {
			return record.b.instanceId;
		}
		if (record.b.instanceId === from) {
			return record.a.instanceId;
		}
		return "not_a_side";
	}
	const resolve = resolver(prefix);
	return resolve ? resolve(from, key, surface) : "unknown_zone";
}

/** v1's resolution (`universal_edges/controller.ts:253-271`): a running instance at its host's public address. */
export function target(
	id: number,
	instance: (id: number) => InstanceFacts | undefined,
	host: (id: number) => { publicAddress?: string } | undefined,
): PlayerTarget {
	const found = instance(id);
	if (!found) {
		return { ok: false, reason: "no_instance" };
	}
	if (found.status !== "running") {
		return { ok: false, reason: "not_running" };
	}
	const address = found.host === undefined ? undefined : host(found.host)?.publicAddress;
	if (!address || found.gamePort === undefined) {
		return { ok: false, reason: "no_address" };
	}
	return { ok: true, address: `${address}:${found.gamePort}`, name: found.name, instanceId: id };
}

/**
 * §4 step 2: each key in order (the zone's, then the edge's fallback) to an instance and its address; the first that
 * works is chosen, with its instance and key, for the record. With none, the last key's reason.
 */
export function resolveKeys(
	keys: string[],
	from: number,
	surface: string,
	edge: (id: string) => EdgeRecord | undefined,
	resolver: (prefix: string) => CrossingResolver | undefined,
	instance: (id: number) => InstanceFacts | undefined,
	host: (id: number) => { publicAddress?: string } | undefined,
): { result: PlayerTarget; to?: number; key?: string } {
	let result: PlayerTarget = { ok: false, reason: "no_keys" };
	for (const key of keys) {
		const to = destination(key, from, surface, edge, resolver);
		result = typeof to === "string" ? { ok: false, reason: to } : target(to, instance, host);
		if (result.ok) {
			return { result, to: to as number, key };
		}
	}
	return { result };
}

/** The instance end (§4, §6.1): crossings and prompts, leaves, and joins with their arrivals. */
export function playerForwarding(context: InstancePluginContext) {
	const { instance, logger } = context;
	const warn = rateLimited(logger);
	let bridge: Bridge | undefined;
	const handlers: Record<string, Handler> = {
		"ue.player.cross": on(PlayerCrossPayload, p => {
			const { player, trace } = p;
			// Not awaited: the bridge dispatches Lua's messages in order; a round trip mustn't hold the rest.
			const request = new PlayerCrossRequest(player, p.keys, p.surface, p.x, p.y, trace);
			instance.sendTo("controller", request).then(r => {
				if (r.ok) {
					bridge!.send("ue.player.prompt", {
						player, address: r.address ?? "", name: r.name ?? "", instance_id: r.instanceId, trace,
					});
				} else {
					bridge!.send("ue.player.none", { player, reason: r.reason ?? "refused", trace });
				}
			}, (err: Error) => {
				bridge!.send("ue.player.none", { player, reason: `error: ${err.message}`, trace });
			});
		}),
		"ue.player.left": on(PlayerLeftPayload, p => {
			try {
				instance.sendTo("controller", new PlayerLeftEvent(p.player, p.surface, p.x, p.y, p.trace));
			} catch (err: any) {
				warn("left", "ue.player left_unsent", { op: "ue.player", phase: "left_unsent", player: p.player,
					trace: p.trace, error: err.message });
			}
		}),
		"ue.player.joined": on(PlayerJoinedPayload, p => {
			const { player } = p;
			instance.sendTo("controller", new PlayerJoinRequest(player)).then(r => {
				bridge!.send("ue.player.arrival", r.arrival ? { player, entry: r.arrival } : { player });
			}, (err: Error) => {
				warn("joined", "ue.player arrival_unfetched", { op: "ue.player", phase: "arrival_unfetched", player,
					error: err.message });
				bridge!.send("ue.player.arrival", { player });
			});
		}),
	};
	function attach(b: Bridge) {
		bridge = b;
	}
	return { handlers, attach };
}
