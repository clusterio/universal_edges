import { test } from "node:test";
import assert from "node:assert/strict";
import { plugin } from "../../index.js";
import { RadarDownEvent, RadarUpEvent } from "../../radar/contracts.js";
import { Hub, RESEND_MS, type HubPort } from "../../radar/hub.js";

type Sent = { to: number; kind: string; payload: any };
type Log = { phase: string; fields: Record<string, unknown>; level: string };

// A hub whose port records what it is given; tiles 1, 2 and 3 are live, and the resyncs that made them so are
// cleared. clock.t is its now(). take() returns what was sent since the last take.
function hub() {
	const sent: Sent[] = [];
	const logs: Log[] = [];
	const clock = { t: 0 };
	const port: HubPort = {
		send: (to, kind, payload) => {
			sent.push({ to, kind, payload });
		},
		log: (phase, fields, level = "info") => {
			logs.push({ phase, fields, level });
		},
		now: () => clock.t,
	};
	const h = new Hub(port);
	for (const id of [1, 2, 3]) {
		h.runtime(id, `boot${id}`);
	}
	sent.length = 0;
	return { h, logs, clock, take: () => sent.splice(0) };
}
const S = "s:nauvis";
const v = (...pairs: (string | number)[]) => ({ virtual: pairs });

test("a host's own reaches every other host of its key as a Δ on the version it builds on; colours stay apart; a " +
	"tile hosting nothing gets nothing; a third host's full target is the total (§5)", () => {
	const { h, take } = hub();
	h.receive(1, "ue.radar.ask", { key: S });
	h.receive(2, "ue.radar.ask", { key: S });
	assert.deepEqual(take(), [
		{ to: 1, kind: "ue.radar.full", payload: { key: S, v: 1 } },
		{ to: 2, kind: "ue.radar.full", payload: { key: S, v: 1 } },
	]);
	h.receive(1, "ue.radar.own", { key: S, v: 1, r: v("signal-A", 5), g: v("signal-G", 1) });
	assert.deepEqual(take(), [
		{ to: 2, kind: "ue.radar.delta", payload: { key: S, v: 2, base: 1, r: v("signal-A", 5), g: v("signal-G", 1) } },
	], "tile 3 hosts nothing and gets nothing");
	h.receive(2, "ue.radar.own", { key: S, v: 1, r: v("signal-A", 2, "signal-B", 7) });
	assert.deepEqual(take(), [
		{ to: 1, kind: "ue.radar.delta", payload: { key: S, v: 2, base: 1, r: v("signal-A", 2, "signal-B", 7) } },
	], "1's target is 2's own");
	h.receive(3, "ue.radar.ask", { key: S });
	const total = { key: S, v: 1, r: v("signal-A", 7, "signal-B", 7), g: v("signal-G", 1) };
	assert.deepEqual(take(), [{ to: 3, kind: "ue.radar.full", payload: total }]);
	h.receive(1, "ue.radar.own", { key: S, v: 2, base: 1, r: v("signal-A", 0) });
	assert.deepEqual(take(), [
		{ to: 2, kind: "ue.radar.delta", payload: { key: S, v: 3, base: 2, r: v("signal-A", 0) } },
		{ to: 3, kind: "ue.radar.delta", payload: { key: S, v: 2, base: 1, r: v("signal-A", 2) } },
	], "1's signal-A left: 2's target loses it (0), 3's falls to 2's own");
});

test("an own change applies only on its base: a repeat is ignored; a gap asks the tile to resend its full own at " +
	"most once per RESEND_MS, and changes wait for that full (§5; circuit §8.3)", () => {
	const { h, take, clock, logs } = hub();
	h.receive(1, "ue.radar.ask", { key: S });
	h.receive(2, "ue.radar.own", { key: S, v: 1, r: v("signal-A", 1) });
	take();
	h.receive(2, "ue.radar.own", { key: S, v: 1, base: 0, r: v("signal-A", 1) });
	assert.deepEqual(take(), [], "a repeat is ignored");
	h.receive(2, "ue.radar.own", { key: S, v: 3, base: 2, r: v("signal-A", 3) });
	assert.deepEqual(take(), [{ to: 2, kind: "ue.radar.resend", payload: { key: S } }], "a gap asks for the full own");
	assert.ok(logs.some(l => l.phase === "gap" && l.fields.instance === 2));
	h.receive(2, "ue.radar.own", { key: S, v: 4, base: 3, r: v("signal-A", 4) });
	clock.t = RESEND_MS - 1;
	h.receive(2, "ue.radar.own", { key: S, v: 5, base: 4, r: v("signal-A", 5) });
	assert.deepEqual(take(), [], "changes wait for the full; no second resend within RESEND_MS");
	clock.t = RESEND_MS;
	h.receive(2, "ue.radar.own", { key: S, v: 6, base: 5, r: v("signal-A", 6) });
	assert.deepEqual(take(), [{ to: 2, kind: "ue.radar.resend", payload: { key: S } }], "and again after it");
	h.receive(2, "ue.radar.own", { key: S, v: 6, r: v("signal-A", 6) });
	assert.deepEqual(take(), [
		{ to: 1, kind: "ue.radar.delta", payload: { key: S, v: 3, base: 2, r: v("signal-A", 6) } },
	], "the full ends the gap");
	h.receive(2, "ue.radar.own", { key: S, v: 7, base: 6, r: v("signal-A", 7) });
	assert.deepEqual(take()[0].payload.r, v("signal-A", 7), "changes apply again");
});

test("a full own replacing the last sends the others only what changed, a removal as 0; quality groups pass as they " +
	"are (circuit §8.2)", () => {
	const { h, take } = hub();
	const rare = { "item|rare": ["iron-plate", 3] };
	h.receive(1, "ue.radar.ask", { key: S });
	h.receive(2, "ue.radar.own", { key: S, v: 1, r: { ...v("signal-A", 1, "signal-B", 2), ...rare } });
	take();
	h.receive(2, "ue.radar.own", { key: S, v: 2, r: { ...v("signal-A", 1, "signal-C", 3), ...rare } });
	assert.deepEqual(take(), [
		{ to: 1, kind: "ue.radar.delta", payload: { key: S, v: 3, base: 2, r: v("signal-B", 0, "signal-C", 3) } },
	]);
});

test("targets wrap at int32, as a wire's sum does (circuit §8.6)", () => {
	const { h, take } = hub();
	h.receive(1, "ue.radar.own", { key: S, v: 1, r: v("signal-A", 2147483647) });
	h.receive(2, "ue.radar.own", { key: S, v: 1, r: v("signal-A", 1) });
	take();
	h.receive(3, "ue.radar.ask", { key: S });
	assert.deepEqual(take(), [
		{ to: 3, kind: "ue.radar.full", payload: { key: S, v: 1, r: v("signal-A", -2147483648) } },
	]);
	h.receive(1, "ue.radar.ask", { key: S });
	assert.deepEqual(take()[0].payload.r, v("signal-A", 1), "1's target is the rest: 2's own");
});

test("unhost and a stop: the tile's own leaves every other target, so a down tile reads as silence; a stopped tile's " +
	"late messages are ignored until its next boot, which gets a resync (§5; Review Focus 1)", () => {
	const { h, take, logs } = hub();
	h.receive(1, "ue.radar.ask", { key: S });
	h.receive(2, "ue.radar.own", { key: S, v: 1, r: v("signal-B", 2) });
	h.receive(3, "ue.radar.own", { key: S, v: 1, r: v("signal-C", 3) });
	take();
	h.receive(3, "ue.radar.unhost", { key: S });
	assert.deepEqual(take(), [
		{ to: 1, kind: "ue.radar.delta", payload: { key: S, v: 4, base: 3, r: v("signal-C", 0) } },
		{ to: 2, kind: "ue.radar.delta", payload: { key: S, v: 2, base: 1, r: v("signal-C", 0) } },
	]);
	h.drop(2);
	assert.deepEqual(take(), [
		{ to: 1, kind: "ue.radar.delta", payload: { key: S, v: 5, base: 4, r: v("signal-B", 0) } },
	], "2 stopped: silence");
	assert.ok(logs.some(l => l.phase === "unhost" && l.fields.instance === 2 && l.fields.reason === "stopped"));
	h.receive(2, "ue.radar.own", { key: S, v: 2, base: 1, r: v("signal-B", 9) });
	assert.deepEqual(take(), [], "a late message from the stopped tile is ignored");
	h.runtime(2, "boot2b");
	assert.deepEqual(take(), [{ to: 2, kind: "ue.radar.resync", payload: {} }], "its next boot gets a resync");
	h.receive(2, "ue.radar.own", { key: S, v: 2, r: v("signal-B", 9) });
	assert.deepEqual(take(), [
		{ to: 1, kind: "ue.radar.delta", payload: { key: S, v: 6, base: 5, r: v("signal-B", 9) } },
	]);
	h.receive(1, "ue.radar.unhost", { key: S });
	h.receive(2, "ue.radar.unhost", { key: S });
	assert.equal(h.nets.size, 0, "a key nobody hosts is forgotten");
});

test("runtime: an unknown boot (a tile's start, or every tile after a controller restart) gets one resync; the same " +
	"boot again gets nothing; before it, a tile's messages are ignored (Review Focus 2)", () => {
	const sent: Sent[] = [];
	const h = new Hub({
		send: (to, kind, payload) => {
			sent.push({ to, kind, payload });
		},
		log: () => undefined,
		now: () => 0,
	});
	h.receive(1, "ue.radar.own", { key: S, v: 3, base: 2, r: v("signal-A", 1) });
	assert.deepEqual(sent, [], "before the tile's first heartbeat its messages wait for the resync");
	h.runtime(1, "b1");
	h.runtime(1, "b1");
	assert.deepEqual(sent, [{ to: 1, kind: "ue.radar.resync", payload: {} }]);
	h.runtime(1, "b2");
	assert.equal(sent.length, 2, "a new boot resyncs again");
});

test("the declaration registers the radar relay's two events", () => {
	assert.ok(plugin.messages!.includes(RadarUpEvent) && plugin.messages!.includes(RadarDownEvent));
});
