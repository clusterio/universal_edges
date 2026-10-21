"use strict";
const path = require("path");
const webpack = require("webpack");
const { merge } = require("webpack-merge");

const common = require("@clusterio/web_ui/webpack.common");

// The universal_edges web bundle (SP1 spec §7.4), as plugins/player_sync/webpack.config.cjs.
module.exports = (env = {}, argv = {}) => merge(common(env, argv), {
	context: __dirname,
	entry: "./web/index.tsx",
	output: {
		path: path.resolve(__dirname, "dist", "web"),
	},
	plugins: [
		new webpack.container.ModuleFederationPlugin({
			name: "universal_edges",
			library: { type: "var", name: "plugin_universal_edges" },
			exposes: {
				"./": "./index.ts",
				"./package.json": "./package.json",
				"./web": "./web/index.tsx",
			},
			shared: {
				"@clusterio/lib": { import: false },
				"@clusterio/web_ui": { import: false },
				"antd": { import: false },
				"react": { import: false },
				"react-dom": { import: false },
			},
		}),
	],
});
