import { plainJson } from "@clusterio/lib";
import { Type, Static } from "@sinclair/typebox";
import { Edge } from "./src/types";

export class EdgeUpdate {
	declare ["constructor"]: typeof EdgeUpdate;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "control" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.example.permission.subscribe";

	constructor(edge: Static<typeof Edge>) {
		Object.assign(this, edge);
	}

	static jsonSchema = Edge;

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json);
	}
}

export class SetEdgeConfig {
	declare ["constructor"]: typeof SetEdgeConfig;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.permission.set_config";

	constructor(
		public id: string,
		public config: Partial<Edge>,
	) { }

	static jsonSchema = Type.Object({
		"id": Type.String(),
		"config": Edge, // type Edge
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.id, json.config as Partial<Edge>);
	}
}

export class GetEdgeConfig {
	declare ["constructor"]: typeof GetEdgeConfig;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.permission.get_config";

	constructor(
		public id: string,
	) { }

	static jsonSchema = Type.Object({
		"id": Type.String(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.id);
	}

	static Response = plainJson(Type.Object({
		"config": Type.Object({}), // type Edge
	}));
}

export class GetEdges {
	declare ["constructor"]: typeof GetEdges;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.permission.get_edges";

	constructor() { }

	static jsonSchema = Type.Object({});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this();
	}

	static Response = plainJson(Type.Array(Edge));
}

export class SubscribeEdgeConfig {
	declare ["constructor"]: typeof SubscribeEdgeConfig;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.permission.subscribe_config";

	constructor(
		public id: string,
	) { }

	static jsonSchema = Type.Object({
		"id": Type.String(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.id);
	}

	static Response = EdgeUpdate.jsonSchema;
}

export class SubscribeEdgeConnector {
	declare ["constructor"]: typeof SubscribeEdgeConnector;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.permission.subscribe_connector";

	constructor(
		public id: string,
	) { }

	static jsonSchema = Type.Object({
		"id": Type.String(),
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.id);
	}

	static Response = EdgeUpdate.jsonSchema;
}

export class EdgeConfigUpdate {
	declare ["constructor"]: typeof EdgeConfigUpdate;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "control" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.permission.subscribe_config";

	constructor(
		public id: string,
		public config: Partial<Edge>,
	) { }

	static jsonSchema = Type.Object({
		"id": Type.String(),
		"config": Type.Object({}), // type Edge
	});

	static fromJSON(json: Static<typeof this.jsonSchema>) {
		return new this(json.id, json.config as Partial<Edge>);
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
		"connectors": Type.Array(Type.Object({})), // type Edge["connectors"]
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
