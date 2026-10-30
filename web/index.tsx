import React from "react";
import * as lib from "@clusterio/lib";
import type { WebPluginContext } from "@clusterio/web_ui";
import { EdgeChangedEvent, type EdgeReadiness, type EdgeRecord } from "../edges/contracts.js";
import EdgeListPage from "./EdgeListPage.js";

/** What the page shows: every unpurged live edge, and each edge's readiness. */
export type EdgeRows = { edges: Map<string, EdgeRecord>; readiness: Map<string, EdgeReadiness> };

/**
 * The edges from the EdgeChangedEvent subscription (SP1 spec §7.4). lib.MapSubscriber wants { updates, isDeleted },
 * so this keeps its own maps: a tombstone or a purge removes an edge, and readiness arrives on its own.
 */
export class EdgeSubscriber extends lib.EventSubscriber<EdgeChangedEvent, EdgeRows> {
	private edges = new Map<string, EdgeRecord>();
	private ready = new Map<string, EdgeReadiness>();
	private version = 0;

	constructor(control: lib.Link) {
		super(EdgeChangedEvent, control);
	}

	/**
	 * ponytail: a counter, not an update time. Readiness and purges carry no time, and the page always wants the whole
	 * list: a small lastRequestTimeMs makes the controller replay every record (universal_edges/edges/controller.ts).
	 */
	protected override getLastUpdatedTimeMs(): number {
		this.version += 1;
		return this.version;
	}

	protected override processEvent(event: EdgeChangedEvent): void {
		for (const edge of event.edges) {
			if (edge.deleted) {
				this.edges.delete(edge.id);
			} else {
				this.edges.set(edge.id, edge);
			}
		}
		for (const id of event.purged) {
			this.edges.delete(id);
			this.ready.delete(id);
		}
		for (const r of event.readiness) {
			this.ready.set(r.id, r);
		}
	}

	protected override makeSnapshot(): EdgeRows {
		// Also called from the base constructor, before this class's fields exist: new Map(undefined) is empty.
		return { edges: new Map(this.edges), readiness: new Map(this.ready) };
	}

	/** A new connection replays everything, so an edge purged while this page was disconnected goes. */
	override handleConnectionEvent(event: "connect" | "drop" | "resume" | "close"): void {
		if (event === "connect" || event === "resume") {
			this.edges.clear();
			this.ready.clear();
		}
		super.handleConnectionEvent(event);
	}
}

/** The web entry point (the pin's function form, packages/create/templates/plugin-ts/web/plugin.tsx:55-75). */
export default async function loadWebPlugin(context: WebPluginContext) {
	const { control, plugin } = context;
	const edges = new EdgeSubscriber(control);
	control.hooks.pages.attach(plugin.name, () => [
		{
			path: "/universal_edges",
			sidebarName: "Universal edges",
			// Client side only: the controller checks each request's own permission.
			permission: "universal_edges.edges.read",
			content: <EdgeListPage edges={edges} />,
		},
	]);
}
