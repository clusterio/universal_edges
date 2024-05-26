import * as lib from "@clusterio/lib";
import { BaseInstancePlugin } from "@clusterio/host";
import * as messages from "./messages";

type PuginExampleIPC = {
	tick: number,
	player_name: string,
};

export class InstancePlugin extends BaseInstancePlugin {
	async init() {
		this.instance.handle(messages.EdgeUpdate, this.handleEdgeUpdate.bind(this));
		this.instance.server.handle("universal_edges-plugin_example_ipc", this.handlePluginExampleIPC.bind(this));
	}

	async onStart() {
		this.logger.info("instance::onStart");
		this.sendRcon(`/sc universal_edges.set_config({instance_id = ${this.instance.config.get("instance.id")}}`)
	}

	async onStop() {
		this.logger.info("instance::onStop");
	}

	async handleEdgeUpdate(event: messages.EdgeUpdate) {
		for (const edge of event.updates) {
			this.sendRcon(`/c universal_edges.edge_update("${edge.id}", '${lib.escapeString(JSON.stringify(edge))}')`);
		}
	}

	// async handlePluginExampleEvent(event: PluginExampleEvent) {
	// 	this.logger.info(JSON.stringify(event));
	// }

	// async handlePluginExampleRequest(request: PluginExampleRequest) {
	// 	this.logger.info(JSON.stringify(request));
	// 	return {
	// 		myResponseString: request.myString,
	// 		myResponseNumbers: request.myNumberArray,
	// 	};
	// }

	async handlePluginExampleIPC(event: PuginExampleIPC) {
		this.logger.info(JSON.stringify(event));
	}
}
