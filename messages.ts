import { plainJson } from "@clusterio/lib";
import { Type, Static } from "@sinclair/typebox";
import { Edge } from "./src/types";

/**
 * Edge configuration change event, subscribable
 * Only control has to subscribe - the controller automatically sends updates to affected instances
 */
export class EdgeUpdate {
	declare ["constructor"]: typeof EdgeUpdate;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = ["control", "instance"] as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.config.read";

	constructor(public updates: Static<typeof Edge>[]) { }

	static jsonSchema = Type.Object({
		updates: Type.Array(Edge),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.updates);
	}
}

export class SetEdgeConfig {
	declare ["constructor"]: typeof SetEdgeConfig;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.config.write";

	constructor(public edge: Edge) { }

	static jsonSchema = Type.Object({
		edge: Edge,
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.edge);
	}
}

export class EdgeLinkUpdate {
	declare ["constructor"]: typeof EdgeLinkUpdate;
	static type = "event" as const;
	static src = ["controller", "instance"] as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(public edgeId: string, public type: string, public data: unknown) { }

	static jsonSchema = Type.Object({
		edgeId: Type.String(),
		type: Type.String(),
		data: Type.Unknown(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.edgeId, json.type, json.data);
	}
}

export class TrainLayoutUpdate {
	declare ["constructor"]: typeof TrainLayoutUpdate;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(public edgeId: string, public data: {
		offset: number,
		reachable_targets: string[], // backer_name for internal stations
		reachable_sources: string[] // edge_id + offset for exits (sources)
		source_instance_id: number,
	}) { }

	static jsonSchema = Type.Object({
		edgeId: Type.String(),
		data: Type.Object({
			offset: Type.Number(),
			reachable_targets: Type.Array(Type.String()),
			reachable_sources: Type.Array(Type.String()),
			source_instance_id: Type.Number(),
		}),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.edgeId, {
			offset: json.data.offset,
			reachable_targets: json.data.reachable_targets,
			reachable_sources: json.data.reachable_sources,
			source_instance_id: json.data.source_instance_id,
		});
	}
}

export class TeleportPlayerToServer {
	declare ["constructor"]: typeof TeleportPlayerToServer;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(public playerName: string, public edgeId: string, public instanceId: number, public offset: number) { }

	static jsonSchema = Type.Object({
		playerName: Type.String(),
		edgeId: Type.String(),
		instanceId: Type.Number(),
		offset: Type.Number(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.playerName, json.edgeId, json.instanceId, json.offset);
	}

	static Response = plainJson(Type.Object({
		"address": Type.String(),
	}));
}

const beltTransfersType = Type.Array(Type.Object({
	offset: Type.Number(),
	item_stacks: Type.Optional(Type.Array(Type.Object({}))),
	set_flow: Type.Optional(Type.Boolean()),
}));
const entityTransfersType = Type.Array(Type.Object({
	type: Type.String(),
	player_name: Type.String(),
	edge_pos: Type.Tuple([Type.Number(), Type.Number()]),
}));
const fluidTransfersType = Type.Array(Type.Object({
	offset: Type.Number(),
	name: Type.String(),
	temperature: Type.Optional(Type.Number()),
	amount: Type.Optional(Type.Number()),
	amount_balanced: Type.Optional(Type.Number()),
}));
const powerTransfersType = Type.Array(Type.Object({
	offset: Type.Number(),
	energy: Type.Optional(Type.Number()),
	amount_balanced: Type.Optional(Type.Number()),
}));
const trainTransfersType = Type.Array(Type.Object({
	offset: Type.Number(),
	train: Type.Optional(Type.Object({})),
	train_id: Type.Optional(Type.Number()),
	set_flow: Type.Optional(Type.Boolean()),
}));
export class EdgeTransfer {
	declare ["constructor"]: typeof EdgeTransfer;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(
		public edgeId: string,
		public beltTransfers: Static<typeof beltTransfersType>,
		public entityTransfers: Static<typeof entityTransfersType>,
		public fluidTransfers: Static<typeof fluidTransfersType>,
		public powerTransfers: Static<typeof powerTransfersType>,
		public trainTransfers: Static<typeof trainTransfersType>,
	) { }

	static jsonSchema = Type.Object({
		edgeId: Type.String(),
		beltTransfers: beltTransfersType,
		entityTransfers: entityTransfersType,
		fluidTransfers: fluidTransfersType,
		powerTransfers: powerTransfersType,
		trainTransfers: trainTransfersType,
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(
			json.edgeId,
			json.beltTransfers,
			json.entityTransfers,
			json.fluidTransfers,
			json.powerTransfers,
			json.trainTransfers
		);
	}

	static Response = plainJson(Type.Object({
		"success": Type.Boolean(),
	}));
}
