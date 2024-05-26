import path from "path";
import * as lib from "@clusterio/lib";
import { BaseControllerPlugin, InstanceInfo } from "@clusterio/controller";

import {
	PluginExampleEvent, PluginExampleRequest,
	EdgeUpdate, SubscribableEdge,
} from "./messages";

export class ControllerPlugin extends BaseControllerPlugin {
	edgeDatastore!: Map<string, SubscribableEdge>;
	storageDirty = false;

	async init() {
		this.controller.handle(PluginExampleEvent, this.handlePluginExampleEvent.bind(this));
		this.controller.handle(PluginExampleRequest, this.handlePluginExampleRequest.bind(this));
		this.controller.subscriptions.handle(EdgeUpdate, this.handleExampleSubscription.bind(this));
		this.edgeDatastore = new Map(); // If needed, replace with loading from database file
	}

	async onControllerConfigFieldChanged(field: string, curr: unknown, prev: unknown) {
		this.logger.info(`controller::onControllerConfigFieldChanged ${field}`);
	}

	async onInstanceConfigFieldChanged(instance: InstanceInfo, field: string, curr: unknown, prev: unknown) {
		this.logger.info(`controller::onInstanceConfigFieldChanged ${instance.id} ${field}`);
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

	async onPlayerEvent(instance: InstanceInfo, event: lib.PlayerEvent) {
		this.logger.info(`controller::onPlayerEvent ${instance.id} ${JSON.stringify(event)}`);
	}

	async handlePluginExampleEvent(event: PluginExampleEvent) {
		this.logger.info(JSON.stringify(event));
	}

	async handlePluginExampleRequest(request: PluginExampleRequest) {
		this.logger.info(JSON.stringify(request));
		return {
			myResponseString: request.myString,
			myResponseNumbers: request.myNumberArray,
		};
	}

	async handleExampleSubscription(request: lib.SubscriptionRequest) {
		const values = [...this.edgeDatastore.values()].filter(
			value => value.updatedAtMs > request.lastRequestTimeMs,
		);
		return values.length ? new EdgeUpdate(values) : null;
	}
}
