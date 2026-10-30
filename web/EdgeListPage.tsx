import React, { useCallback, useContext, useState, useSyncExternalStore } from "react";
import { Button, Card, Checkbox, Form, Input, Modal, Popconfirm, Select, Space, Table } from "antd";
import {
	ControlContext, PageHeader, PageLayout, notifyErrorHandler, useAccount, useInstance, useInstances,
} from "@clusterio/web_ui";
import { EdgeEnsureRequest, EdgeRemoveRequest, type EdgeRecord, type EdgeSpec, type Side } from "../edges/contracts.js";
import type { EdgeSubscriber } from "./index.js";

// v1's "Universal edges" page (universal_edges/web/pages/EdgeListPage.tsx), on SP1a's requests and subscription
// (SP1 spec §7.4, D13). Geometry is read-only once an edge exists (D7): moving an edge means delete and add.

const FACINGS: Record<number, string> = { 0: "north", 4: "east", 8: "south", 12: "west" };
const SURFACES = ["nauvis", "vulcanus", "fulgora", "aquilo", "gleba"];

function SideCard({ side, ready }: { side: Side; ready: boolean | undefined }) {
	const [instance] = useInstance(side.instanceId);
	return <Card size="small" title={instance?.name ?? side.instanceId}>
		<p>Origin: {side.origin[0]}, {side.origin[1]}</p>
		<p>Surface: {side.surface}</p>
		<p>Facing: {FACINGS[side.facing]}</p>
		<p>Ready: {ready === undefined ? "unknown" : String(ready)}</p>
	</Card>;
}

type SideForm = { instanceId?: number; x: string; y: string; surface: string; facing: 0 | 4 | 8 | 12 };
type EdgeForm = { id: string; length: string; a: SideForm; b: SideForm; delete: boolean };

function sideForm(side?: Side): SideForm {
	return side
		? { instanceId: side.instanceId, x: String(side.origin[0]), y: String(side.origin[1]), surface: side.surface,
			facing: side.facing }
		: { x: "0", y: "0", surface: "nauvis", facing: 0 };
}

function toSide(form: SideForm): Side {
	return {
		instanceId: form.instanceId!, surface: form.surface, facing: form.facing,
		origin: [Number.parseInt(form.x, 10), Number.parseInt(form.y, 10)],
	};
}

const INTEGER = { required: true, pattern: /^ *-?[0-9]+ *$/, message: "a whole number" };

function SideFields({ name, locked }: { name: "a" | "b"; locked: boolean }) {
	const [instances] = useInstances();
	return <>
		<Form.Item name={[name, "instanceId"]} label="Instance" rules={[{ required: true }]}>
			<Select disabled={locked} options={[...instances.values()].map(i => ({ value: i.id, label: i.name }))} />
		</Form.Item>
		<Form.Item label="Origin">
			<Space>
				<Form.Item name={[name, "x"]} noStyle rules={[INTEGER]}>
					<Input disabled={locked} style={{ width: 100 }} />
				</Form.Item>
				<Form.Item name={[name, "y"]} noStyle rules={[INTEGER]}>
					<Input disabled={locked} style={{ width: 100 }} />
				</Form.Item>
			</Space>
		</Form.Item>
		<Form.Item name={[name, "surface"]} label="Surface">
			<Select disabled={locked} options={SURFACES.map(s => ({ value: s, label: s }))} />
		</Form.Item>
		<Form.Item name={[name, "facing"]} label="Facing">
			<Select disabled={locked} options={[0, 4, 8, 12].map(f => ({ value: f, label: FACINGS[f] }))} />
		</Form.Item>
	</>;
}

type Editing = { id: string; record?: EdgeRecord };

/**
 * The modal: a new edge (owner "manual", the ctl default), or an existing one, read-only with its Delete box for an
 * account that may write. The record is the one the modal opened with, so a delete from elsewhere can't turn Save into
 * an add.
 */
function EdgeModal({ editing, canWrite, onClose }: { editing: Editing; canWrite: boolean; onClose: () => void }) {
	const control = useContext(ControlContext);
	const { id, record } = editing;
	const initial: EdgeForm = {
		id, length: String(record?.length ?? 64), a: sideForm(record?.a), b: sideForm(record?.b), delete: false,
	};
	async function save(form: EdgeForm) {
		if (record) {
			if (form.delete) {
				await control.send(new EdgeRemoveRequest(record.id, record.owner));
			}
			return;
		}
		const spec: EdgeSpec = {
			id: form.id.trim(), owner: "manual", length: Number.parseInt(form.length, 10), a: toSide(form.a),
			b: toSide(form.b),
		};
		await control.send(new EdgeEnsureRequest(spec));
	}
	const failed = notifyErrorHandler(record ? "Deleting the edge failed" : "Adding the edge failed");
	const title = record ? `Edge ${record.id}` : "Add edge";
	return <Modal title={title} open onCancel={onClose} footer={null} destroyOnClose>
		<Form<EdgeForm>
			size="small"
			labelCol={{ span: 8 }}
			wrapperCol={{ span: 16 }}
			initialValues={initial}
			onFinish={form => save(form).then(onClose, failed)}
		>
			<Form.Item name="id" label="ID" rules={[{ required: true }]}>
				<Input disabled={Boolean(record)} />
			</Form.Item>
			<Form.Item name="length" label="Length" rules={[INTEGER]}>
				<Input disabled={Boolean(record)} />
			</Form.Item>
			<h4>Side a</h4>
			<SideFields name="a" locked={Boolean(record)} />
			<h4>Side b</h4>
			<SideFields name="b" locked={Boolean(record)} />
			{record && canWrite && <Form.Item name="delete" label="Delete" valuePropName="checked">
				<Checkbox />
			</Form.Item>}
			{canWrite && <Form.Item><Button htmlType="submit" type="primary">Save</Button></Form.Item>}
		</Form>
	</Modal>;
}

export default function EdgeListPage({ edges }: { edges: EdgeSubscriber }) {
	const control = useContext(ControlContext);
	const account = useAccount();
	const subscribe = useCallback((callback: () => void) => edges.subscribe(callback), [edges]);
	const [rows] = useSyncExternalStore(subscribe, () => edges.getSnapshot());
	const [editing, setEditing] = useState<Editing>();
	const [deleting, setDeleting] = useState(false);
	const list = [...rows.edges.values()];
	const gridworld = list.filter(r => r.owner === "gridworld").length;
	const canWrite = account.hasPermission("universal_edges.edges.write") === true;
	const ready = (r: EdgeRecord) => rows.readiness.get(r.id);

	async function deleteAll() {
		setDeleting(true);
		// As v1: every edge, whatever its owner. Gridworld re-creates its own once they are purged (SP2 spec §10.2).
		await Promise.all(list.map(r => control.send(new EdgeRemoveRequest(r.id, r.owner))))
			.catch(notifyErrorHandler("Deleting the edges failed"));
		setDeleting(false);
	}

	return <PageLayout nav={[{ name: "Universal edges" }]}>
		<PageHeader
			title="Universal edges"
			extra={canWrite ? <Space>
				<Button type="primary" onClick={() => setEditing({ id: Math.random().toString(36).substring(2) })}>
					Add
				</Button>
				<Popconfirm
					title={`Permanently delete ALL ${list.length} edges, ${gridworld} of them gridworld's?`}
					okText="Delete"
					okButtonProps={{ danger: true, loading: deleting }}
					onConfirm={deleteAll}
				>
					<Button danger loading={deleting}>Delete ALL</Button>
				</Popconfirm>
			</Space> : undefined}
		/>
		<Table
			size="small"
			dataSource={list}
			rowKey="id"
			columns={[
				{ title: "ID", dataIndex: "id" },
				{ title: "Owner", dataIndex: "owner" },
				{ title: "Side a", key: "a", render: (_, r) => <SideCard side={r.a} ready={ready(r)?.a} /> },
				{ title: "Side b", key: "b", render: (_, r) => <SideCard side={r.b} ready={ready(r)?.b} /> },
				{ title: "Active", key: "active", render: (_, r) => String(ready(r)?.active ?? false) },
				{ title: "Length", dataIndex: "length" },
				{ title: "Connectors", key: "connectors", render: (_, r) => r.connectors.length },
			]}
			onRow={r => ({ onClick: () => setEditing({ id: r.id, record: r }) })}
		/>
		{editing && <EdgeModal editing={editing} canWrite={canWrite} onClose={() => setEditing(undefined)} />}
	</PageLayout>;
}
