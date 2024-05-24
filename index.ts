import * as lib from "@clusterio/lib";
import * as Messages from "./messages";

lib.definePermission({
	name: "universal_edges.example.permission.event",
	title: "Example permission event",
	description: "Example Description. Event. Change me in index.ts",
});

lib.definePermission({
	name: "universal_edges.example.permission.request",
	title: "Example permission request",
	description: "Example Description. Request. Change me in index.ts",
});

lib.definePermission({
	name: "universal_edges.example.permission.subscribe",
	title: "Example permission subscribe",
	description: "Example Description. Subscribe. Change me in index.ts",
});

lib.definePermission({
	name: "universal_edges.page.view",
	title: "Example page view permission",
	description: "Example Description. View. Change me in index.ts",
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
		Messages.PluginExampleEvent,
		Messages.PluginExampleRequest,
		Messages.ExampleSubscribableUpdate,
	],

	webEntrypoint: "./web",
	routes: [
		"/universal_edges",
	],
};
