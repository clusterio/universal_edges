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
		this.controller.handle(messages.SetEdgeConfig, this.handleSetEdgeConfigRequest.bind(this));
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
			}],
		]); // If needed, replace with loading from database file
	}

	async onInstanceStatusChanged(instance: InstanceInfo, prev?: lib.InstanceStatus): Promise<void> {
		// Send edge config updates for relevant edges
		const edges = [...this.edgeDatastore.values()].filter(edge => edge.source.instanceId === instance.id
			|| edge.target.instanceId === instance.id
		);
		// Set active status
		edges.forEach(edge => { edge.active = this.isEdgeActive(edge); });

		// Update instances consuming the edges
		const instanceEdgeMap: Map<number, Edge[]> = new Map();
		edges.forEach(edge => {
			if (edge.source.instanceId !== undefined) {
				const arr = instanceEdgeMap.get(edge.source.instanceId) || [];
				if (!arr.includes(edge)) {
					arr.push(edge);
				}
				instanceEdgeMap.set(edge.source.instanceId, arr);
			}
			if (edge.target.instanceId !== undefined) {
				const arr = instanceEdgeMap.get(edge.target.instanceId) || [];
				if (!arr.includes(edge)) {
					arr.push(edge);
				}
				instanceEdgeMap.set(edge.target.instanceId, arr);
			}
		});

		// Send update
		for (let instanceId of instanceEdgeMap.keys()) {
			if (this.controller.instances.get(instanceId)?.status === "running") {
				const edgesToSend = instanceEdgeMap.get(instanceId)!;
				this.logger.info(`Instance running ${instanceId} relevant edge count ${edgesToSend.length}`);
				this.controller.sendTo({ instanceId }, new messages.EdgeUpdate(edgesToSend));
			}
		}
	}

	async onControllerConfigFieldChanged(field: string, curr: unknown, prev: unknown) {
		this.logger.info(`controller::onControllerConfigFieldChanged ${field}`);
	}

	async onSaveData() {
		// Save edgeDatastore to file
		if (this.storageDirty) {
			this.logger.info("Saving edgeDatastore to file");
			this.storageDirty = false;
			const file = path.resolve(
				this.controller.config.get("controller.database_directory"),
				"edgeDatastore.json"
			);
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

	async handleSetEdgeConfigRequest({ edge }: messages.SetEdgeConfig) {
		const oldEdge = this.edgeDatastore.get(edge.id);
		this.edgeDatastore.set(edge.id, edge);

		// Set active status
		edge.active = this.isEdgeActive(edge);

		// Broadcast changes to affected instances
		const instancesToUpdate = [
			oldEdge?.source.instanceId,
			oldEdge?.target.instanceId,
			edge.source.instanceId,
			edge.target.instanceId,
		];
		for (let instanceId of instancesToUpdate) {
			if (instanceId) {
				let instance = this.controller.instances.get(instanceId);
				if (instance?.status === "running") {
					await this.controller.sendTo({ instanceId }, new messages.EdgeUpdate([edge]));
				}
			}
		}
	}

	isEdgeActive(edge: Edge) {
		if (edge.source.instanceId === edge.target.instanceId) { return false; }
		const source = this.controller.instances.get(edge.source.instanceId);
		if (!source || source.status !== "running") { return false; }
		const target = this.controller.instances.get(edge.target.instanceId);
		if (!target || target.status !== "running") { return false; }
		return true;
	}
}
