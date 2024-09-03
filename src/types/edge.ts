import { Type, Static } from "@sinclair/typebox";

export interface Edge {
	id: string;
	updatedAtMs: number;
	isDeleted: boolean;
	source: EdgeTargetSpecification;
	target: EdgeTargetSpecification;
	length: number;
	active: boolean;
	link_destinations: Record<string, { // keys is offset as a string
		reachable_targets: string[];
		reachable_sources: string[];
		source_instance_id: number;
	}>;
}

export interface EdgeTargetSpecification {
	instanceId: number;
	origin: number[];
	surface: number;
	direction: number;
	ready: boolean;
}

export interface TwoWayBuffer {
	buffer: number;
	capacity: number;
	bufferName: string; // Name of the buffered item. Won't balance items if the name doesn't match.
}

// Typebox equivalent
export const EdgeConnectorType = Type.Union([
	Type.Literal("InBelt"),
	Type.Literal("OutBelt"),
	Type.Literal("InTrain"),
	Type.Literal("OutTrain"),
	Type.Literal("Fluid"),
	Type.Literal("Power"),
]);

export const TwoWayBuffer = Type.Object({
	buffer: Type.Number(),
	capacity: Type.Number(),
	bufferName: Type.String(),
});

export const EdgeConnector = Type.Object({
	position: Type.Number(), // Distance along edge from origin
	type: EdgeConnectorType,
	sourcePlaced: Type.Boolean(),
	targetPlaced: Type.Boolean(),
	blocked: Type.Number(),
	sourceBuffer: Type.Optional(TwoWayBuffer),
	targetBuffer: Type.Optional(TwoWayBuffer),
});

export const EdgeTarget = Type.Object({
	instanceId: Type.Number(),
	origin: Type.Array(Type.Number()),
	surface: Type.Number(),
	direction: Type.Number(),
	ready: Type.Boolean(),
});

export const Edge = Type.Object({
	id: Type.String(),
	// For subscriptions etc
	updatedAtMs: Type.Number(),
	isDeleted: Type.Boolean(),
	// Edge teleports data
	source: EdgeTarget,
	target: EdgeTarget,
	length: Type.Number(),
	active: Type.Boolean(),
	link_destinations: Type.Record(Type.String(), Type.Object({
		reachable_targets: Type.Array(Type.String()),
		reachable_sources: Type.Array(Type.String()),
		source_instance_id: Type.Number(),
	})),
});
