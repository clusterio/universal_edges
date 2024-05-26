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
	export interface ControllerConfigFields {
		"universal_edges.myControllerField": string;
	}
	export interface InstanceConfigFields {
		"universal_edges.myInstanceField": string;
	}
}

export const plugin: lib.PluginDeclaration = {
	name: "universal_edges",
	title: "universal_edges",
	description: "Example Description. Plugin. Change me in index.ts",

	controllerEntrypoint: "./dist/node/controller",
	controllerConfigFields: {
		"universal_edges.myControllerField": {
			title: "My Controller Field",
			description: "This should be removed from index.js",
			type: "string",
			initialValue: "Remove Me",
		},
	},

	instanceEntrypoint: "./dist/node/instance",
	instanceConfigFields: {
		"universal_edges.myInstanceField": {
			title: "My Instance Field",
			description: "This should be removed from index.js",
			type: "string",
			initialValue: "Remove Me",
		},
	},

	messages: [
		messages.EdgeConnectorUpdate,
		messages.EdgeTransfer,
		messages.EdgeUpdate,
		messages.SetEdgeConfig,
	],

	webEntrypoint: "./web",
	routes: [
		"/universal_edges",
	],
};
