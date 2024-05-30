import { plainJson } from "@clusterio/lib";
import { Type, Static } from "@sinclair/typebox";
import { Edge, EdgeConnector } from "./src/types";

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
		updates: Type.Array(Edge)
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

	constructor(public edge: Edge,) { }

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
	static src = "instance" as const;
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

const beltTransfersType = Type.Array(Type.Object({
	offset: Type.Number(),
	item_stacks: Type.Optional(Type.Array(Type.Object({}))),
	set_flow: Type.Optional(Type.Boolean()),
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
export class EdgeTransfer {
	declare ["constructor"]: typeof EdgeTransfer;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(
		public edgeId: string,
		public beltTransfers: Static<typeof beltTransfersType>,
		public fluidTransfers: Static<typeof fluidTransfersType>,
		public powerTransfers: Static<typeof powerTransfersType>,
	) { }

	static jsonSchema = Type.Object({
		edgeId: Type.String(),
		beltTransfers: beltTransfersType,
		fluidTransfers: fluidTransfersType,
		powerTransfers: powerTransfersType,
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.edgeId, json.beltTransfers, json.fluidTransfers, json.powerTransfers);
	}

	static Response = plainJson(Type.Object({
		"success": Type.Boolean(),
	}));
}
