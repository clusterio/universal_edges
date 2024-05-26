import React, { useContext, useCallback, useSyncExternalStore, } from "react";

import {
	BaseWebPlugin, PageLayout, ControlContext,
} from "@clusterio/web_ui";

import * as messages from "../messages";

import * as lib from "@clusterio/lib";

function MyTemplatePage() {
	const control = useContext(ControlContext);
	const plugin = control.plugins.get("universal_edges") as WebPlugin;
	const [edgeConfigs, synced] = plugin.useEdgeConfigs();

	return <PageLayout nav={[{ name: "Universal edges" }]}>
		<h2>Universal edges</h2>
		Synced: {String(synced)} Data: {JSON.stringify([...edgeConfigs.values()])}
	</PageLayout>;
}

export class WebPlugin extends BaseWebPlugin {
	subscribableEdgeConfigs = new lib.EventSubscriber(messages.EdgeUpdate, this.control);

	async init() {
		this.pages = [
			{
				path: "/universal_edges",
				sidebarName: "universal_edges",
				// This permission is client side only, so it must match the permission string of a resource request to be secure
				// An undefined value means that the page will always be visible
				permission: "universal_edges.config.read",
				content: <MyTemplatePage />,
			},
		];

		// this.control.handle(PluginExampleEvent, this.handlePluginExampleEvent.bind(this));
		// this.control.handle(PluginExampleRequest, this.handlePluginExampleRequest.bind(this));
	}

	useEdgeConfigs() {
		const control = useContext(ControlContext);
		const subscribe = useCallback((callback: () => void) => this.subscribableEdgeConfigs.subscribe(callback), [control]);
		return useSyncExternalStore(subscribe, () => this.subscribableEdgeConfigs.getSnapshot());
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
}
