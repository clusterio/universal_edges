import type * as lib from "@clusterio/lib";
import {
	ConnectorChangeRequest, EdgeActivationEvent, EdgeAppliedEvent, EdgeChangedEvent, EdgeEnsureRequest,
	EdgeListRequest, EdgePurgedEvent, EdgeRemoveRequest, EdgeSyncEvent, EdgeUpdateEvent, LaneBatchEvent,
	PlayerCrossRequest, PlayerLeftEvent, PlayerJoinRequest,
} from "./edges/contracts.js";
import { PingEvent, RuntimeEvent } from "./messages.js";
import { RouteDownEvent, RouteUpEvent } from "./routing/contracts.js";
import { RadarDownEvent, RadarUpEvent } from "./radar/contracts.js";
import { SchedDownEvent, SchedUpEvent } from "./schedules/contracts.js";

declare module "@clusterio/lib" {
	export interface Permissions {
		"universal_edges.edges.read": never;
		"universal_edges.edges.write": never;
	}
}

export const plugin: lib.PluginDeclaration = {
	name: "universal_edges",
	title: "Universal Edges",
	description: "Links Clusterio instances with belts, fluids, power and trains (v2).",
	controllerEntrypoint: "dist/node/controller.js",
	instanceEntrypoint: "dist/node/instance.js",
	ctlEntrypoint: "dist/node/edges/ctl.js",
	features: ["SavePatching", "ScriptCommands"],
	messages: [
		RuntimeEvent,
		PingEvent,
		EdgeSyncEvent,
		EdgeUpdateEvent,
		EdgeActivationEvent,
		EdgePurgedEvent,
		EdgeAppliedEvent,
		ConnectorChangeRequest,
		EdgeEnsureRequest,
		EdgeRemoveRequest,
		EdgeListRequest,
		EdgeChangedEvent,
		LaneBatchEvent,
		PlayerCrossRequest,
		PlayerLeftEvent,
		PlayerJoinRequest,
		RouteUpEvent,
		RouteDownEvent,
		RadarUpEvent,
		RadarDownEvent,
		SchedUpEvent,
		SchedDownEvent,
	],
	permissions: [
		{
			name: "universal_edges.edges.read",
			title: "View edges",
			description: "List Universal Edges edges and subscribe to their changes.",
			grantByDefault: true,
		},
		{
			name: "universal_edges.edges.write",
			title: "Change edges",
			description: "Create and remove Universal Edges edges and their connectors.",
		},
	],
	webEntrypoint: "./web",
	routes: ["/universal_edges"],
};
