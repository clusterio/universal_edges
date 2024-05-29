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

export class EdgeConnectorUpdate {
	declare ["constructor"]: typeof EdgeConnectorUpdate;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "control" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.permission.subscribe_connector";

	constructor(
		public id: string,
		public connectors: Edge["connectors"],
	) { }

	static jsonSchema = Type.Object({
		"id": Type.String(),
		"connectors": Type.Array(EdgeConnector), // type Edge["connectors"]
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.id, json.connectors as Edge["connectors"]);
	}
}

export class EdgeTransfer {
	declare ["constructor"]: typeof EdgeTransfer;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.permission.transfer";
	constructor(
		json: Static<typeof EdgeTransfer.jsonSchema>
	) {
		Object.assign(this, json);
	}

	static jsonSchema = Type.Array(Type.Object({
		"edge_id": Type.Number(),
		"connectors": Type.Array(Type.Object({
			"type": Type.String(),
			"name": Type.String(),
			"amount": Type.Number(),
		})),
	}));

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json);
	}

	static Response = plainJson(Type.Object({
		"success": Type.Boolean(),
	}));
}
