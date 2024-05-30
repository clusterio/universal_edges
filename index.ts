import * as lib from "@clusterio/lib";
import * as messages from "./messages";

lib.definePermission({
	name: "universal_edges.config.read",
	title: "Read edge configuration",
	description: "Read access to edge configuration, including subscriptions",
});

lib.definePermission({
	name: "universal_edges.config.write",
	title: "Write edge configuration",
	description: "Write access to edge configuration",
});

declare module "@clusterio/lib" {
	export interface ControllerConfigFields { }
	export interface InstanceConfigFields {
		"universal_edges.ticks_per_edge": number;
		"universal_edges.transfer_message_rate": number;
		"universal_edges.transfer_command_rate": number;
	}
}

export const plugin: lib.PluginDeclaration = {
	name: "universal_edges",
	title: "universal_edges",
	description: "Example Description. Plugin. Change me in index.ts",

	controllerEntrypoint: "./dist/node/controller",
	controllerConfigFields: {},

	instanceEntrypoint: "./dist/node/instance",
	instanceConfigFields: {
		"universal_edges.ticks_per_edge": {
			title: "Ticks Per Edge",
			description: "Number of game ticks to use processing each edge.",
			type: "number",
			initialValue: 15,
		},
		"universal_edges.transfer_message_rate": {
			title: "Transfer Message Rate",
			description: "Rate in messages per second to send edge transfers to other instances.",
			type: "number",
			initialValue: 50,
		},
		"universal_edges.transfer_command_rate": {
			title: "Transfer Command Rate",
			description: "Rate in commands per seccond to send edge transfer data into this instance.",
			type: "number",
			initialValue: 1000 / 34, // Factorio protocol update rate
		},

	},

	messages: [
		messages.EdgeLinkUpdate,
		messages.EdgeTransfer,
		messages.EdgeUpdate,
		messages.SetEdgeConfig,
	],

	webEntrypoint: "./web",
	routes: [
		"/universal_edges",
	],
};
