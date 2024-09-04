import * as lib from "@clusterio/lib";
import { BaseInstancePlugin } from "@clusterio/host";
import * as messages from "./messages";
import { Edge } from "./src/types";

type EdgeLinkUpdate = {
	type: string,
	edge_id: string,
	data: {
		offset: number,
		is_input?: boolean,
		belt_type?: string,
		parking_area_size?: number, // For trains only
		penalty_map?: object, // For train station pathfinding penalty
	}
};

type TrainLayoutUpdate = {
	edge_id: string,
	data: {
		offset: number,
		reachable_targets: string[], // backer_name for internal stations
		reachable_sources: string[], // edge_id + offset for exits (sources)
		source_instance_id: number,
	},
};

type BeltTransfer = {
	offset: number,
	set_flow?: boolean,
	item_stacks?: object[],
};

type FluidTransfer = {
	offset: number,
	name: string,
	temperature?: number,
	amount?: number,
	amount_balanced?: number,
}

type PowerTransfer = {
	offset: number,
	energy?: number,
	amount_balanced?: number,
}

type TrainTransfer = {
	offset: number,
	train?: object,
	train_id?: number,
	set_flow?: boolean,
}

type EdgeTransfer = {
	edge_id: string,
	belt_transfers: BeltTransfer[],
	fluid_transfers: FluidTransfer[],
	power_transfers: PowerTransfer[],
	train_transfers: TrainTransfer[],
}

type EdgeBuffer = {
	edge: Edge,
	pendingMessage: {
		beltTransfers: Map<number, BeltTransfer>,
		fluidTransfers: Map<number, FluidTransfer>,
		powerTransfers: Map<number, PowerTransfer>,
		trainTransfers: Map<number, TrainTransfer>,
	},
	messageTransfer: lib.RateLimiter,
	pendingCommand: {
		beltTransfers: Map<number, BeltTransfer>
		fluidTransfers: Map<number, FluidTransfer>
		powerTransfers: Map<number, PowerTransfer>
		trainTransfers: Map<number, TrainTransfer>
	}
	commandTransfer: lib.RateLimiter,
}

function mergeBeltTransfers(
	pendingBeltTransfers: Map<number, BeltTransfer>,
	beltTransfers: BeltTransfer[]
) {
	for (let beltTransfer of beltTransfers) {
		let pending = pendingBeltTransfers.get(beltTransfer.offset);
		if (!pending) {
			pending = {
				offset: beltTransfer.offset,
			};
			pendingBeltTransfers.set(beltTransfer.offset, pending);
		}
		if (beltTransfer.item_stacks) {
			if (!pending.item_stacks) {
				pending.item_stacks = [];
			}
			pending.item_stacks.push(...beltTransfer.item_stacks);
		}
		if (Object.prototype.hasOwnProperty.call(beltTransfer, "set_flow")) {
			pending.set_flow = beltTransfer.set_flow;
		}
	}
}

function mergeFluidTransfers(
	pendingFluidTransfers: Map<number, FluidTransfer>,
	fluidTransfers: FluidTransfer[]
) {
	for (let fluidTransfer of fluidTransfers) {
		let pending = pendingFluidTransfers.get(fluidTransfer.offset);
		if (!pending) {
			pending = {
				offset: fluidTransfer.offset,
				name: fluidTransfer.name,
			};
			pendingFluidTransfers.set(fluidTransfer.offset, pending);
		}
		// When sending amount we send the current amount in the tank, hence we want to overwrite instead of adding here
		if (fluidTransfer.amount) { pending.amount = fluidTransfer.amount; }
		if (fluidTransfer.temperature) { pending.temperature = fluidTransfer.temperature; }
		// Amount balanced is the amount of fluid we have added on the current instance. This one needs to be additive.
		if (fluidTransfer.amount_balanced) {
			if (pending.amount_balanced) {
				pending.amount_balanced += fluidTransfer.amount_balanced;
			} else {
				pending.amount_balanced = fluidTransfer.amount_balanced;
			}
		}
	}
}

function mergePowerTransfers(
	pendingPowerTransfers: Map<number, PowerTransfer>,
	powerTransfers: PowerTransfer[]
) {
	for (let powerTransfer of powerTransfers) {
		let pending = pendingPowerTransfers.get(powerTransfer.offset);
		if (!pending) {
			pending = {
				offset: powerTransfer.offset,
			};
			pendingPowerTransfers.set(powerTransfer.offset, pending);
		}
		// When sending amount we send the current amount in the tank, hence we want to overwrite instead of adding here
		if (powerTransfer.energy !== undefined) { pending.energy = powerTransfer.energy; }
		// Amount balanced is the amount of fluid we have added on the current instance. This one needs to be additive.
		if (powerTransfer.amount_balanced !== undefined) {
			if (pending.amount_balanced !== undefined) {
				pending.amount_balanced += powerTransfer.amount_balanced;
			} else {
				pending.amount_balanced = powerTransfer.amount_balanced;
			}
		}
	}
}

function mergeTrainTransfers(
	pendingTrainTransfers: Map<number, TrainTransfer>,
	trainTransfers: TrainTransfer[]
) {
	for (let trainTransfer of trainTransfers) {
		// Train transfers can't be merged, only one train can travel at a time. Use the latest request
		let pending = pendingTrainTransfers.get(trainTransfer.offset);
		if (pending !== undefined) {
			if (pending.train_id === trainTransfer.train_id) {
				console.log(`WARN: Train ${pending.train_id} is already being sent`);
			} else {
				// eslint-disable-next-line max-len
				console.log(`FATAL: Sending 2 different trains from same connector: ${pending.train_id} and ${trainTransfer.train_id}`);
			}
			pending.set_flow = trainTransfer.set_flow;
		} else {
			pendingTrainTransfers.set(trainTransfer.offset, trainTransfer);
		}
	}
}

function mapToArray(map: Map<any, any>) {
	let arr = [];
	for (let [_index, item] of map) {
		arr.push({
			...item,
		});
	}
	map.clear();
	return arr;
}

export class InstancePlugin extends BaseInstancePlugin {
	edges: Map<string, EdgeBuffer> = new Map();
	edgeCallbacks: Map<string, ((data: EdgeBuffer) => void)[]> = new Map();

	async init() {

		this.instance.server.on("ipc-universal_edges:edge_link_update", data => {
			this.handleEdgeLinkUpdate(data).catch(err => this.logger.error(
				`Error handling edge_link_update:\n${err.stack}`
			));
		});

		this.instance.server.on("ipc-universal_edges:transfer", data => {
			this.handleEdgeTransferFromGame(data).catch(err => this.logger.error(
				`Error handling transfer:\n${err.stack}`
			));
		});

		this.instance.server.on("ipc-universal_edges:train_layout_update", data => {
			this.handleTrainLayoutUpdate(data).catch(err => this.logger.error(
				`Error handling train_layout_update:\n${err.stack}`
			));
		});

		this.instance.handle(messages.EdgeUpdate, this.handleEdgeUpdate.bind(this));
		this.instance.handle(messages.EdgeLinkUpdate, this.edgeLinkUpdateEventHandler.bind(this));
		this.instance.handle(messages.EdgeTransfer, this.edgeTransferRequestHandler.bind(this));
	}

	async onStart() {
		this.logger.info("instance::onStart");
		await this.sendRcon(`/sc universal_edges.set_config({instance_id = ${this.instance.config.get("instance.id")}})`);
	}

	async onStop() {
		this.logger.info("instance::onStop");
	}

	// Get an edge from cache, if it is not yet in cahce then wait for it to become available. This fixes inconsistent state on server startup
	async getEdge(id: string) {
		let edge = this.edges.get(id);
		if (edge) {
			return edge;
		}

		return new Promise<EdgeBuffer>((resolve, reject) => {
			let timeout = setTimeout(() => {
				this.edgeCallbacks.delete(id);
				reject(new Error(`Timeout waiting for edge ${id}`));
			}, 10000);
			let callback = (data: EdgeBuffer) => {
				this.edgeCallbacks.delete(id);
				clearTimeout(timeout);
				resolve(data);
			}
			let cb = this.edgeCallbacks.get(id);
			if (cb) {
				cb.push(callback);
			} else {
				this.edgeCallbacks.set(id, [callback]);
			}
		});
	}

	async handleEdgeLinkUpdate(update: EdgeLinkUpdate) {
		let edge = await this.getEdge(update.edge_id);
		if (!edge) {
			this.logger.warn(`Got update for unknown edge ${update.edge_id}`);
			return;
		}

		// Find partner instance
		let localInstance = this.instance.config.get("instance.id");
		let partnerInstance = edge.edge.target.instanceId;
		if (edge.edge.target.instanceId === localInstance) {
			partnerInstance = edge.edge.source.instanceId;
		}

		await this.instance.sendTo(
			{ instanceId: partnerInstance },
			new messages.EdgeLinkUpdate(
				edge.edge.id,
				update.type,
				update.data,
			)
		);
	}

	async edgeLinkUpdateEventHandler(message: messages.EdgeLinkUpdate) {
		let { type, edgeId, data } = message;
		let json = lib.escapeString(JSON.stringify({ type, edge_id: edgeId, data }));
		await this.sendRcon(`/sc universal_edges.edge_link_update("${json}")`, true);
	}

	async handleEdgeTransferFromGame(data: EdgeTransfer) {
		let edge = await this.getEdge(data.edge_id);
		if (!edge) {
			console.log(data);
			console.log("edge not found");
			return; // XXX LATER PROBLEM
		}

		mergeBeltTransfers(edge.pendingMessage.beltTransfers, data.belt_transfers || []);
		mergeFluidTransfers(edge.pendingMessage.fluidTransfers, data.fluid_transfers || []);
		mergePowerTransfers(edge.pendingMessage.powerTransfers, data.power_transfers || []);
		mergeTrainTransfers(edge.pendingMessage.trainTransfers, data.train_transfers || []);
		edge.messageTransfer.activate();
	}

	// Important - assumed to only be sent from the destination side of train connectors
	async handleTrainLayoutUpdate(data: TrainLayoutUpdate) {
		let edge = await this.getEdge(data.edge_id);
		if (!edge) {
			console.log("impossible edge not found!");
			return; // XXX LATER PROBLEM
		}

		// Handle no stations in the world causing empty table to serialize as object
		if (!Array.isArray(data.data.reachable_targets)) data.data.reachable_targets = [];
		if (!Array.isArray(data.data.reachable_sources)) data.data.reachable_sources = [];

		// Send the source connector ID to the controller so it is able to return the proxy station layout correctly
		const destination_instance_id = this.instance.config.get("instance.id");
		if (destination_instance_id === edge.edge.source.instanceId) {
			data.data.source_instance_id = edge.edge.target.instanceId;
		} else {
			data.data.source_instance_id = edge.edge.source.instanceId;
		}

		// Send to controller
		await this.instance.sendTo("controller", new messages.TrainLayoutUpdate(data.edge_id, data.data));
	}

	async handleEdgeUpdate(event: messages.EdgeUpdate) {
		for (const edge of event.updates) {
			// Cache locally to avoid passing extra data from game
			let edgeBuffer = this.edges.get(edge.id);
			if (!edgeBuffer) {
				this.edges.set(edge.id, {
					edge,
					pendingMessage: {
						beltTransfers: new Map(),
						fluidTransfers: new Map(),
						powerTransfers: new Map(),
						trainTransfers: new Map(),
					},
					messageTransfer: new lib.RateLimiter({
						maxRate: this.instance.config.get("universal_edges.transfer_message_rate"),
						action: () => this.edgeTransferSendMessage(edge.id).catch(err => this.logger.error(
							`Error sending transfer message:\n${err.stack ?? err.message}`
						)),
					}),
					pendingCommand: {
						beltTransfers: new Map(),
						fluidTransfers: new Map(),
						powerTransfers: new Map(),
						trainTransfers: new Map(),
					},
					commandTransfer: new lib.RateLimiter({
						maxRate: this.instance.config.get("universal_edges.transfer_command_rate"),
						action: () => this.edgeTransferSendCommand(edge.id).catch(err => this.logger.error(
							`Error sending transfer command:\n${err.stack ?? err.message}`
						)),
					}),
				});
			} else {
				edgeBuffer.edge = edge;
			}
			// Update ingame config
			await this.sendRcon(`/sc universal_edges.edge_update("${edge.id}", '${lib.escapeString(JSON.stringify(edge))}')`);

			// Update edge callbacks
			let callbacks = this.edgeCallbacks.get(edge.id);
			if (callbacks) {
				for (let callback of callbacks) {
					callback(this.edges.get(edge.id)!);
				}
				this.edgeCallbacks.delete(edge.id);
			}
		}
	}

	async edgeTransferSendMessage(edgeId: string) {
		let edge = await this.getEdge(edgeId);
		if (!edge) {
			console.log("impossible edge not found!");
			return; // XXX LATER PROBLEM
		}

		// Belts
		let beltTransfers = mapToArray(edge.pendingMessage.beltTransfers);
		// Fluids
		let fluidTransfers = mapToArray(edge.pendingMessage.fluidTransfers);
		// Power
		let powerTransfers = mapToArray(edge.pendingMessage.powerTransfers);
		// Trains
		let trainTransfers = mapToArray(edge.pendingMessage.trainTransfers);

		try {
			// Find partner instance
			let localInstance = this.instance.config.get("instance.id");
			let partnerInstance = edge.edge.target.instanceId;
			if (edge.edge.target.instanceId === localInstance) {
				partnerInstance = edge.edge.source.instanceId;
			}

			await this.instance.sendTo(
				{ instanceId: partnerInstance },
				new messages.EdgeTransfer(
					edge.edge.id,
					beltTransfers,
					fluidTransfers,
					powerTransfers,
					trainTransfers,
				)
			);
			// We assume the transfer did not happen if an error occured.
		} catch (err) {
			throw err;
			// TODO return items
		}
	}

	async edgeTransferRequestHandler(message: messages.EdgeTransfer) {
		let { edgeId, beltTransfers, fluidTransfers, powerTransfers, trainTransfers } = message;
		let edge = await this.getEdge(edgeId);
		if (!edge) {
			console.log("impossible the edge was not found!");
			return { success: false }; // XXX later problem
		}

		mergeBeltTransfers(edge.pendingCommand.beltTransfers, beltTransfers);
		mergeFluidTransfers(edge.pendingCommand.fluidTransfers, fluidTransfers);
		mergePowerTransfers(edge.pendingCommand.powerTransfers, powerTransfers);
		mergeTrainTransfers(edge.pendingCommand.trainTransfers, trainTransfers);
		edge.commandTransfer.activate();
		return { success: true };
	}

	async edgeTransferSendCommand(edgeId: string) {
		let edge = await this.getEdge(edgeId);
		if (!edge) {
			console.log("how can this happen");
			return; // XXX later problem,
		}

		// Belts
		let beltTransfers = mapToArray(edge.pendingCommand.beltTransfers);
		// FLuids
		let fluidTransfers = mapToArray(edge.pendingCommand.fluidTransfers);
		// Power
		let powerTransfers = mapToArray(edge.pendingCommand.powerTransfers);
		// Trains
		let trainTransfers = mapToArray(edge.pendingCommand.trainTransfers);

		let json = lib.escapeString(JSON.stringify({
			edge_id: edgeId,
			belt_transfers: beltTransfers,
			fluid_transfers: fluidTransfers,
			power_transfers: powerTransfers,
			train_transfers: trainTransfers,
		}));
		await this.sendRcon(`/sc universal_edges.transfer("${json}")`, true);
	}
}
