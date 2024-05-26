import path from "path";
import * as lib from "@clusterio/lib";
import { BaseControllerPlugin, InstanceInfo } from "@clusterio/controller";

import * as messages from "./messages";
import { Edge } from "./src/types";

export class ControllerPlugin extends BaseControllerPlugin {
	edgeDatastore!: Map<string, Edge>;
	storageDirty = false;

	async init() {
		// this.controller.handle(PluginExampleEvent, this.handlePluginExampleEvent.bind(this));
		// this.controller.handle(PluginExampleRequest, this.handlePluginExampleRequest.bind(this));
		this.controller.subscriptions.handle(messages.EdgeUpdate, this.handleEdgeConfigSubscription.bind(this));
		this.edgeDatastore = new Map([
			["999", {
				id: "999",
				updatedAtMs: Date.now(),
				isDeleted: false,
				source: {
					instanceId: 928502558,
					origin: [0, 0],
					surface: 1,
					direction: 0,
					ready: false,
				},
				target: {
					instanceId: 1446149399,
					origin: [0, 0],
					surface: 1,
					direction: 4,
					ready: false,
				},
				length: 20,
				active: false,
			}]
		]); // If needed, replace with loading from database file
	}

	async onInstanceStatusChanged(instance: InstanceInfo, prev?: lib.InstanceStatus): Promise<void> {
		if (instance.status === "running") {
			// Send edge config updates for relevant edges
			const edges = [...this.edgeDatastore.values()].filter(edge => edge.source.instanceId === instance.id || edge.target.instanceId === instance.id);
			this.logger.info(`Instance running ${instance.id} relevant edge count ${edges.length}`)
			this.controller.sendTo({ instanceId: instance.id }, new messages.EdgeUpdate(edges));
		}
	}

	async onControllerConfigFieldChanged(field: string, curr: unknown, prev: unknown) {
		this.logger.info(`controller::onControllerConfigFieldChanged ${field}`);
	}

	async onSaveData() {
		this.logger.info("controller::onSaveData");
		// Save edgeDatastore to file
		if (this.storageDirty) {
			this.logger.info("Saving edgeDatastore to file");
			this.storageDirty = false;
			const file = path.resolve(this.controller.config.get("controller.database_directory"), "edgeDatastore.json");
			await lib.safeOutputFile(file, JSON.stringify(Array.from(this.edgeDatastore)));
		}
	}

	async onShutdown() {
		this.logger.info("controller::onShutdown");
	}

	async handleEdgeConfigSubscription(request: lib.SubscriptionRequest) {
		const values = [...this.edgeDatastore.values()].filter(
			value => value.updatedAtMs > request.lastRequestTimeMs,
		);
		return values.length ? new messages.EdgeUpdate(values) : null;
	}
}
