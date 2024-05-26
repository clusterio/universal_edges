import React, { useContext, useCallback, useSyncExternalStore, } from "react";

import {
	BaseWebPlugin, ControlContext,
} from "@clusterio/web_ui";

import * as messages from "../messages";

import * as lib from "@clusterio/lib";
import EdgeListPage from "./pages/EdgeListPage";

export class WebPlugin extends BaseWebPlugin {
	subscribableEdgeConfigs = new lib.EventSubscriber(messages.EdgeUpdate, this.control);

	async init() {
		this.pages = [
			{
				path: "/universal_edges",
				sidebarName: "Universal edges",
				// This permission is client side only, so it must match the permission string of a resource request to be secure
				// An undefined value means that the page will always be visible
				permission: "universal_edges.config.read",
				content: <EdgeListPage />,
			},
		];
	}

	useEdgeConfigs() {
		const control = useContext(ControlContext);
		const subscribe = useCallback((callback: () => void) => this.subscribableEdgeConfigs.subscribe(callback), [control]);
		return useSyncExternalStore(subscribe, () => this.subscribableEdgeConfigs.getSnapshot());
	}
}
