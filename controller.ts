import path from "path";
import * as lib from "@clusterio/lib";
import { BaseControllerPlugin, InstanceInfo } from "@clusterio/controller";
import fs from "fs/promises";

import * as messages from "./messages";
import { Edge, EdgeTargetSpecification } from "./src/types";

async function loadDatabase(config: lib.ControllerConfig, filename: string, logger: lib.Logger): Promise<Map<string, Edge>> {
	let itemsPath = path.resolve(config.get("controller.database_directory"), filename);
	logger.verbose(`Loading ${itemsPath}`);
	try {
		let content = await fs.readFile(itemsPath, "utf-8");
		if (content.length === 0) {
			return new Map();
		}
		return new Map(JSON.parse(content));
	} catch (err: any) {
		if (err.code === "ENOENT") {
			logger.verbose("Creating new universal_edges database");
			return new Map();
		}
		throw err;
	}
}

async function saveDatabase(config: lib.ControllerConfig, datastore: Map<any, any>, filename: string, logger: lib.Logger) {
	if (datastore) {
		let file = path.resolve(config.get("controller.database_directory"), filename);
		logger.verbose(`writing ${file}`);
		await lib.safeOutputFile(file, JSON.stringify(Array.from(datastore)));
	}
}

export class ControllerPlugin extends BaseControllerPlugin {
	edgeDatastore!: Map<string, Edge>;
	storageDirty = false;

	async init() {
		// this.controller.handle(PluginExampleEvent, this.handlePluginExampleEvent.bind(this));
		this.controller.handle(messages.SetEdgeConfig, this.handleSetEdgeConfigRequest.bind(this));
		this.controller.handle(messages.TrainLayoutUpdate, this.handleTrainLayoutUpdateEvent.bind(this));
		this.controller.subscriptions.handle(messages.EdgeUpdate, this.handleEdgeConfigSubscription.bind(this));
		this.edgeDatastore = await loadDatabase(this.controller.config, "edgeDatastore.json", this.logger);
		// Set active status
		this.edgeDatastore.forEach(edge => {
			edge.active = this.isEdgeActive(edge);
		});
	}

	async onInstanceStatusChanged(instance: InstanceInfo, prev?: lib.InstanceStatus): Promise<void> {
		// Send edge config updates for relevant edges
		const edges = [...this.edgeDatastore.values()].filter(edge => edge.source.instanceId === instance.id
			|| edge.target.instanceId === instance.id
		);
		// Set active status
		edges.forEach(edge => {
			let newStatus = this.isEdgeActive(edge);
			if (edge.active !== newStatus) {
				edge.updatedAtMs = Date.now();
			}
			edge.active = newStatus;
		});

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

		// Broadcast changes to control subscriptions
		this.controller.subscriptions.broadcast(new messages.EdgeUpdate(edges));
	}

	async onControllerConfigFieldChanged(field: string, curr: unknown, prev: unknown) {
		this.logger.info(`controller::onControllerConfigFieldChanged ${field}`);
	}

	async onSaveData() {
		// Save edgeDatastore to file
		if (this.storageDirty) {
			this.logger.info("Saving edgeDatastore to file");
			this.storageDirty = false;
			await saveDatabase(this.controller.config, this.edgeDatastore, "edgeDatastore.json", this.logger);
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
		this.storageDirty = true;
		const oldEdge = this.edgeDatastore.get(edge.id);
		this.edgeDatastore.set(edge.id, edge);

		// Set active status
		edge.active = this.isEdgeActive(edge);
		edge.updatedAtMs = Date.now();

		// Check if any properties other than updatedAtMs changed
		if (oldEdge) {
			const keys = Object.keys(edge) as (keyof Edge)[];
			if (keys.every(key => {
				if (["updatedAtMs"].includes(key)) {
					return true;
				}
				if (["source", "target"].includes(key)) {
					return (Object.keys(edge[key]) as (keyof EdgeTargetSpecification)[]).every(subKey => {
						return (edge[key] as EdgeTargetSpecification)[subKey] === (oldEdge[key] as EdgeTargetSpecification)[subKey];
					});
				}
				return edge[key] === oldEdge[key]
			})) {
				// No changes
				return;
			}
		}

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

		// Broadcast changes to control subscriptions
		this.controller.subscriptions.broadcast(new messages.EdgeUpdate([edge]));
	}

	async handleTrainLayoutUpdateEvent({ edgeId, data }: messages.TrainLayoutUpdate) {
		const edge = this.edgeDatastore.get(edgeId);
		if (!edge) {
			this.logger.warn(`Received TrainLayoutUpdate for non-existing edge ${edgeId}`);
			return;
		}

		// Add to cache
		if (!edge.link_destinations[data.offset]) {
			edge.link_destinations[data.offset] = {
				reachable_targets: [],
				reachable_sources: [],
				source_instance_id: data.source_instance_id,
			};
		}
		edge.link_destinations[data.offset].reachable_targets = data.reachable_targets;
		edge.link_destinations[data.offset].reachable_sources = data.reachable_sources;
		edge.link_destinations[data.offset].source_instance_id = data.source_instance_id;

		this.pathfinderUpdate();
	}

	pathfinderUpdate() {
		// Build destinations
		type destination = {
			id: string; // edge.id .. " " .. offset
			targets: string[]; // backer_name for internal stations
			sources: string[]; // edge.id .. " " .. offset
			source_instance_id: number;
			reachable_targets: Map<string, number>; // output, number is the distance in links
		};
		const destinations = new Map<string, destination>();

		// Populate destinations
		this.edgeDatastore.forEach((edge) => {
			Object.keys(edge.link_destinations).forEach((offset) => {
				const link = edge.link_destinations[offset];
				const id = `${edge.id} ${offset}`;
				destinations.set(id, {
					id,
					targets: link.reachable_targets,
					sources: link.reachable_sources,
					source_instance_id: link.source_instance_id,
					reachable_targets: new Map(),
				});
			});
		});

		// Ugly hack to make it propagate paths
		for (let i = 0; i < 10; i++) {
			// Find reachable_sources
			[...destinations.values()].forEach((dest) => {
				// Add targets from adjacent node
				dest.targets.forEach((target) => dest.reachable_targets.set(target, 1));
			});

			[...destinations.values()].forEach((dest) => {
				for (const source of dest.sources) {
					const target = destinations.get(source)!;
					// Add targets alraedy processed by the patfhinder (distance > 1)
					target.reachable_targets.forEach((value, key) => {
						dest.reachable_targets.set(key, Math.min(value + 1, dest.reachable_targets.get(key) || Infinity));
					});
				}
			});
		}

		// Multiply all distances by 100k because that is what the Lua code and mod assumes
		destinations.forEach((dest) => {
			dest.reachable_targets.forEach((value, key) => {
				dest.reachable_targets.set(key, value * 100_000);
			});
		});

		console.log(destinations);

		// Send updates to instances
		destinations.forEach((dest) => {
			const split = dest.id.split(" ");
			const offset = split[split.length - 1];
			const edgeId = dest.id.slice(0, dest.id.length - offset.length - 1);
			const edge = this.edgeDatastore.get(edgeId);
			if (!edge) {
				this.logger.warn(`Edge ${edgeId} not found for pathfinder update`);
				return;
			}
			const link = edge.link_destinations[offset];
			link.reachable_targets = Array.from(dest.reachable_targets.keys());

			this.controller.sendTo({ instanceId: dest.source_instance_id }, new messages.EdgeLinkUpdate(edgeId, "update_train_penalty_map", {
				offset: Number(offset),
				penalty_map: Object.fromEntries(dest.reachable_targets.entries()),
			}));
		});
	}

	isEdgeActive(edge: Edge) {
		if (edge.isDeleted) { return false; }
		if (edge.source.instanceId === edge.target.instanceId) { return false; }
		const source = this.controller.instances.get(edge.source.instanceId);
		if (!source || source.status !== "running") { return false; }
		const target = this.controller.instances.get(edge.target.instanceId);
		if (!target || target.status !== "running") { return false; }
		return true;
	}
}
