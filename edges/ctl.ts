import * as lib from "@clusterio/lib";
import { newId } from "../runtime/ids.js";
import {
	ConnectorChangeRequest, EdgeEnsureRequest, EdgeListRequest, EdgeRemoveRequest, type EdgeRecord,
} from "./contracts.js";

/** The parts of clusterioctl's plugin context this entrypoint uses (CtlPluginContext lives in @clusterio/ctl). */
type CtlContext = { hooks: { addCommands: lib.AsyncHook<[lib.CommandTree]> }; plugin: { name: string } };

function out(text: string) {
	process.stdout.write(`${text}\n`);
}

function parseJson(text: string, what: string): any {
	try {
		return JSON.parse(text);
	} catch (err: any) {
		throw new lib.CommandError(`${what} is not valid JSON: ${err.message}`);
	}
}

function line(e: EdgeRecord): string {
	const connectors = e.connectors.map(c => `${c.cid}:${c.type}@${c.pos}`).join(",") || "-";
	return [
		e.id, e.deleted ? `deleted(${e.reason})` : "live", `rev ${e.revision}`, `owner ${e.owner}`,
		`length ${e.length}`, `a ${e.a.instanceId}`, `b ${e.b.instanceId}`, `connectors ${connectors}`,
	].join(" ");
}

const edgeCommands = new lib.CommandTree({ name: "edge", description: "Universal Edges edges" });
edgeCommands.add(new lib.Command({
	definition: ["ensure <spec-json>", "Create an edge from its spec, or confirm an identical one", yargs => {
		yargs.positional("spec-json", { describe: "EdgeSpec JSON; owner defaults to \"manual\"", type: "string" });
	}],
	handler: async (args: { specJson: string }, control: lib.Link) => {
		const spec = { owner: "manual", ...parseJson(args.specJson, "spec-json") };
		const response = await control.send(new EdgeEnsureRequest(spec));
		out(JSON.stringify(response.edge));
	},
}));
edgeCommands.add(new lib.Command({
	definition: ["remove <id>", "Tombstone an edge; it is purged once both sides are done with it", yargs => {
		yargs.positional("id", { describe: "Edge id", type: "string" });
		yargs.options({ owner: { describe: "The edge's owner", type: "string", default: "manual" } });
	}],
	handler: async (args: { id: string; owner: string }, control: lib.Link) => {
		await control.send(new EdgeRemoveRequest(args.id, args.owner));
	},
}));
edgeCommands.add(new lib.Command({
	definition: [["list", "l"], "List edges, tombstones included", yargs => {
		yargs.options({ json: { describe: "Print the records as JSON", type: "boolean", default: false } });
	}],
	handler: async (args: { json: boolean }, control: lib.Link) => {
		const { edges } = await control.send(new EdgeListRequest());
		if (args.json) {
			out(JSON.stringify(edges));
			return;
		}
		for (const edge of edges) {
			out(line(edge));
		}
	},
}));

type AddArgs = { edge: string; type: string; pos: number; width: number; params?: string };

const connectorCommands = new lib.CommandTree({ name: "connector", description: "Universal Edges connectors" });
connectorCommands.add(new lib.Command({
	definition: ["add <edge> <type> <pos>", "Add a connector at canonical column pos (side a's frame)", yargs => {
		yargs.positional("edge", { describe: "Edge id", type: "string" });
		yargs.positional("type", { describe: "Connector type, e.g. probe", type: "string" });
		yargs.positional("pos", { describe: "Its lowest column, in side a's frame", type: "number" });
		yargs.options({
			width: { describe: "Columns it covers", type: "number", default: 1 },
			params: { describe: "The type's params as JSON, at most 1 KB", type: "string" },
		});
	}],
	handler: async (args: AddArgs, control: lib.Link) => {
		const params = args.params === undefined ? {} : parseJson(args.params, "params");
		const { edge, type, pos, width } = args;
		const result = await control.send(new ConnectorChangeRequest({
			edge, op: "add", type, pos, width, params, trace: newId(),
		}));
		if (!result.ok) {
			throw new lib.CommandError(`connector rejected: ${result.reason}`);
		}
		out(result.cid ?? "");
	},
}));
connectorCommands.add(new lib.Command({
	definition: ["remove <edge> <cid>", "Remove a connector; both sides then close its lanes", yargs => {
		yargs.positional("edge", { describe: "Edge id", type: "string" });
		yargs.positional("cid", { describe: "Connector id, e.g. c12", type: "string" });
	}],
	handler: async (args: { edge: string; cid: string }, control: lib.Link) => {
		const change = { edge: args.edge, op: "remove" as const, cid: args.cid, trace: newId() };
		const result = await control.send(new ConnectorChangeRequest(change));
		if (!result.ok) {
			throw new lib.CommandError(`connector not removed: ${result.reason}`);
		}
	},
}));

const universalEdgesCommands = new lib.CommandTree({ name: "universal-edges", description: "Universal Edges v2" });
universalEdgesCommands.add(edgeCommands);
universalEdgesCommands.add(connectorCommands);

/** clusterioctl entrypoint (SP1 spec §7.2): `clusterioctl universal-edges edge|connector …`. */
export default async function loadCtlPlugin(context: CtlContext) {
	context.hooks.addCommands.attach(context.plugin.name, async rootCommand => {
		rootCommand.add(universalEdgesCommands);
	});
}
