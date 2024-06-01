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
	}
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

type EdgeTransfer = {
	edge_id: string,
	belt_transfers: BeltTransfer[],
	fluid_transfers: FluidTransfer[],
	power_transfers: PowerTransfer[],
}

type EdgeBuffer = {
	edge: Edge,
	pendingMessage: {
		beltTransfers: Map<number, BeltTransfer>,
		fluidTransfers: Map<number, FluidTransfer>,
		powerTransfers: Map<number, PowerTransfer>,
	},
	messageTransfer: lib.RateLimiter,
	pendingCommand: {
		beltTransfers: Map<number, BeltTransfer>
		fluidTransfers: Map<number, FluidTransfer>
		powerTransfers: Map<number, PowerTransfer>
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

export class InstancePlugin extends BaseInstancePlugin {
	edges: Map<string, EdgeBuffer> = new Map();

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

		this.instance.handle(messages.EdgeUpdate, this.handleEdgeUpdate.bind(this));
		this.instance.handle(messages.EdgeLinkUpdate, this.edgeLinkUpdateEventHandler.bind(this));
		this.instance.handle(messages.EdgeTransfer, this.edgeTransferRequestHandler.bind(this));
	}

	async onStart() {
		this.logger.info("instance::onStart");
		this.sendRcon(`/sc universal_edges.set_config({instance_id = ${this.instance.config.get("instance.id")}})`);
	}

	async onStop() {
		this.logger.info("instance::onStop");
	}

	async handleEdgeLinkUpdate(update: EdgeLinkUpdate) {
		let edge = this.edges.get(update.edge_id);
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
		let edge = this.edges.get(data.edge_id);
		if (!edge) {
			console.log(data);
			console.log("edge not found");
			return; // XXX LATER PROBLEM
		}

		mergeBeltTransfers(edge.pendingMessage.beltTransfers, data.belt_transfers || []);
		mergeFluidTransfers(edge.pendingMessage.fluidTransfers, data.fluid_transfers || []);
		mergePowerTransfers(edge.pendingMessage.powerTransfers, data.power_transfers || []);
		edge.messageTransfer.activate();
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
			this.sendRcon(`/sc universal_edges.edge_update("${edge.id}", '${lib.escapeString(JSON.stringify(edge))}')`);
		}
	}

	async edgeTransferSendMessage(edgeId: string) {
		let edge = this.edges.get(edgeId);
		if (!edge) {
			console.log("impossible edge not found!");
			return; // XXX LATER PROBLEM
		}

		// Belts
		let beltTransfers = [];
		for (let [_offset, beltTransfer] of edge.pendingMessage.beltTransfers) {
			beltTransfers.push({
				...beltTransfer,
			});
		}
		edge.pendingMessage.beltTransfers.clear();
		// Fluids
		let fluidTransfers = [];
		for (let [_offset, fluidTransfer] of edge.pendingMessage.fluidTransfers) {
			fluidTransfers.push({
				...fluidTransfer,
			});
		}
		edge.pendingMessage.fluidTransfers.clear();
		// Power
		let powerTransfers = [];
		for (let [_offset, powerTransfer] of edge.pendingMessage.powerTransfers) {
			powerTransfers.push({
				...powerTransfer,
			});
		}
		edge.pendingMessage.powerTransfers.clear();

		try {
			// Find partner instance
			let localInstance = this.instance.config.get("instance.id");
			let partnerInstance = edge.edge.target.instanceId;
			if (edge.edge.target.instanceId === localInstance) {
				partnerInstance = edge.edge.source.instanceId;
			}

			await this.instance.sendTo(
				{ instanceId: partnerInstance },
				new messages.EdgeTransfer(edge.edge.id, beltTransfers, fluidTransfers, powerTransfers)
			);
			// We assume the transfer did not happen if an error occured.
		} catch (err) {
			throw err;
			// TODO return items
		}
	}

	async edgeTransferRequestHandler(message: messages.EdgeTransfer) {
		let { edgeId, beltTransfers, fluidTransfers, powerTransfers } = message;
		let edge = this.edges.get(edgeId);
		if (!edge) {
			console.log("impossible the edge was not found!");
			return { success: false }; // XXX later problem
		}

		mergeBeltTransfers(edge.pendingCommand.beltTransfers, beltTransfers);
		mergeFluidTransfers(edge.pendingCommand.fluidTransfers, fluidTransfers);
		mergePowerTransfers(edge.pendingCommand.powerTransfers, powerTransfers);
		edge.commandTransfer.activate();
		return { success: true };
	}

	async edgeTransferSendCommand(edgeId: string) {
		let edge = this.edges.get(edgeId);
		if (!edge) {
			console.log("how can this happen");
			return; // XXX later problem,
		}

		// Belts
		let beltTransfers = [];
		for (let [_offset, beltTransfer] of edge.pendingCommand.beltTransfers) {
			beltTransfers.push({
				...beltTransfer,
			});
		}
		edge.pendingCommand.beltTransfers.clear();
		// FLuids
		let fluidTransfers = [];
		for (let [_offset, fluidTransfer] of edge.pendingCommand.fluidTransfers) {
			fluidTransfers.push({
				...fluidTransfer,
			});
		}
		edge.pendingCommand.fluidTransfers.clear();
		// Power
		let powerTransfers = [];
		for (let [_offset, powerTransfer] of edge.pendingCommand.powerTransfers) {
			powerTransfers.push({
				...powerTransfer,
			});
		}
		edge.pendingCommand.powerTransfers.clear();

		let json = lib.escapeString(JSON.stringify({
			edge_id: edgeId,
			belt_transfers: beltTransfers,
			fluid_transfers: fluidTransfers,
			power_transfers: powerTransfers,
		}));
		await this.sendRcon(`/sc universal_edges.transfer("${json}")`, true);
	}
}
