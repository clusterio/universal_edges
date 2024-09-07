import React, { useContext, useState } from "react";
import { Button, Card, Divider, Form, Input, Modal, Select, Table, Popconfirm, Space } from "antd";
import { SaveOutlined, GithubOutlined, DeleteOutlined, PlusOutlined } from "@ant-design/icons";

import {
	ControlContext,
	PageLayout,
	PageHeader,
	useInstance,
	useAccount,
} from "@clusterio/web_ui";

import * as messages from "../../messages";
import { Edge, EdgeTargetSpecification } from "../../src/types";
import { WebPlugin } from "..";
import { InstanceSelector } from "../components/InstanceSelector";
import { direction_to_string } from "../../src/util/direction_to_string";
import InputPosition from "../components/InputPosition";

function EdgeTarget({ target }: { target: EdgeTargetSpecification }) {
	const [instance] = useInstance(target.instanceId);

	return <Card size="small" title={instance?.name || target.instanceId}>
		<p>Origin: {JSON.stringify(target.origin)}</p>
		<p>Surface: {target.surface}</p>
		<p>Direction: {target.direction}</p>
		<p>Ready: {target.ready?.toString()}</p>
	</Card>;
}

function edgeToForm(edge?: Edge) {
	if (!edge) {
		return {
			isDeleted: false,
			length: 10,
			active: false,
			source: {
				instanceId: undefined,
				origin: ["0", "0"],
				surface: "1",
				direction: 0,
				ready: false,
			},
			target: {
				instanceId: undefined,
				origin: ["0", "0"],
				surface: "1",
				direction: 0,
				ready: false,
			},
		};
	}

	return {
		...edge,
		updatedAtMs: Date.now(),
		length: String(edge.length),
		source: {
			...edge.source,
			surface: String(edge.source.surface),
			origin: edge.source.origin.map(String),
		},
		target: {
			...edge.target,
			surface: String(edge.target.surface),
			origin: edge.target.origin.map(String),
		},
	};
}
type EdgeForm = NonNullable<ReturnType<typeof edgeToForm>>;

function formToEdge(form: EdgeForm, id: string, link_destinations: Edge["link_destinations"]): Edge {
	return {
		...form,
		link_destinations,
		id,
		updatedAtMs: Date.now(),
		length: Number(form.length),
		active: false,
		source: {
			...form.source,
			ready: false,
			surface: Number.parseInt(form.source.surface, 10),
			instanceId: form.source.instanceId!,
			origin: form.source.origin.map(s => Number.parseInt(s, 10)),
		},
		target: {
			...form.target,
			ready: false,
			surface: Number.parseInt(form.target.surface, 10),
			instanceId: form.target.instanceId!,
			origin: form.target.origin.map(s => Number.parseInt(s, 10)),
		},
	};
}

export default function EdgeListPage() {
	const control = useContext(ControlContext);
	const account = useAccount();
	const plugin = control.plugins.get("universal_edges") as WebPlugin;
	const [edgeConfigs, synced] = plugin.useEdgeConfigs();
	const [editing, setEditing] = useState("");
	const [deleting, setDeleting] = useState(false);

	const fIStyle = {
		style: {
			marginBottom: "5px",
		},
	};

	return <PageLayout nav={[{ name: "Universal edges" }]}>
		<PageHeader
			title="Universal edges"
			subTitle={<Button href="https://github.com/danielv123/universal_edges"><GithubOutlined /></Button>}
			extra={
				<Space>{[
					<Button
						key="1"
						type="primary"
						onClick={() => {
							const id = Math.random().toString(36).substring(2);
							setEditing(id);
						}}
					>
						Add
						<PlusOutlined />
					</Button>,
					account.hasPermission("core.instance.delete")
					&& <Popconfirm
						key="delete"
						title="Permanently delete ALL edges?"
						okText="Delete"
						placement="bottomRight"
						okButtonProps={{ danger: true, loading: deleting }}
						onConfirm={async () => {
							setDeleting(true);
							// Set isDeleted on all edges
							const updates = [...edgeConfigs.values()].map(edge => (
								{
									...edge,
									isDeleted: true,
								}
							));
							const results = updates.map(update => control.send(new messages.SetEdgeConfig(update)));
							await Promise.all(results);
							setDeleting(false);
						}}
					>
						<Button
							danger
							loading={deleting}
						>
							<DeleteOutlined />
						</Button>
					</Popconfirm>,
				]}</Space>
			}
		/>
		<Table
			size="small"
			dataSource={[...edgeConfigs.values()]}
			rowKey="id"
			columns={[{
				title: "ID",
				dataIndex: "id",
			}, {
				title: "Source",
				key: "source",
				render: (_, record) => <EdgeTarget target={record.source} />,
			}, {
				title: "Target",
				key: "target",
				render: (_, record) => <EdgeTarget target={record.target} />,
			}, {
				title: "Length",
				dataIndex: "length",
			}]}
			onRow={edge => ({
				onClick: () => {
					console.log("Clicked", edge.id);
					setEditing(edge.id);
				},
			})}
		/>
		<Modal
			title="Edit edge"
			open={Boolean(editing)}
			onCancel={() => setEditing("")}
			destroyOnClose // Reset form when modal is closed
			footer={null}
		>
			<Form<EdgeForm>
				preserve={false} // Reset form when modal is closed
				size="small"
				labelCol={{ span: 8 }}
				wrapperCol={{ span: 16 }}
				onFinish={(values) => {
					const original = edgeConfigs.get(editing);
					const edge = formToEdge(values, editing, original?.link_destinations ?? {});
					console.log(edge);
					control.send(new messages.SetEdgeConfig(edge));
				}}
				initialValues={edgeToForm(edgeConfigs.get(editing))}
			>
				<Form.Item {...fIStyle} name="isDeleted" label="Delete" valuePropName="checked">
					<Input type="checkbox" />
				</Form.Item>
				<Form.Item
					{...fIStyle}
					name="length"
					label="Length"
					rules={[{ required: true, pattern: /^ *-?[0-9]+ *$/, message: "must be a number" }]}
				>
					<Input />
				</Form.Item>
				<Divider>Source</Divider>
				<Form.Item
					{...fIStyle}
					name={["source", "instanceId"]}
					label="Source instance"
					rules={[{ required: true }]}
				>
					<InstanceSelector />
				</Form.Item>
				<Form.Item
					{...fIStyle}
					name={["source", "origin"]}
					label="Position"
					rules={[{
						validator: async (_, value) => {
							for (const pos of value) {
								if (!/^ *-?[0-9]+ *$/.test(pos)) {
									throw new Error("Position must be two numbers");
								}
							}
						},
					}]}
				>
					<InputPosition />
				</Form.Item>
				<Form.Item {...fIStyle} name={["source", "surface"]} label="Surface" valuePropName="checked">
					<Select>
						{["nauvis", "vulcanus", "fulgora", "aquilo", "gleba"].map(value => (
							<Select.Option key={value} value={value}>
								{value}
							</Select.Option>
						))}
					</Select>
				</Form.Item>
				<Form.Item {...fIStyle} name={["source", "direction"]} label="Direction">
					<Select>
						{[0, 4, 8, 12].map(value => <Select.Option key={value} value={value}>
							{direction_to_string(value)}
						</Select.Option>)}
					</Select>
				</Form.Item>
				<Divider>Target</Divider>
				<Form.Item
					{...fIStyle}
					name={["target", "instanceId"]}
					label="Target instance"
					rules={[{ required: true }]}
				>
					<InstanceSelector />
				</Form.Item>
				<Form.Item
					{...fIStyle}
					name={["target", "origin"]}
					label="Position"
				>
					<InputPosition />
				</Form.Item>
				<Form.Item {...fIStyle} name={["source", "surface"]} label="Surface" valuePropName="checked">
					<Select>
						{["nauvis", "vulcanus", "fulgora", "aquilo", "gleba"].map(value => (
							<Select.Option key={value} value={value}>
								{value}
							</Select.Option>
						))}
					</Select>
				</Form.Item>
				<Form.Item {...fIStyle} name={["target", "direction"]} label="Direction">
					<Select>
						{[0, 4, 8, 12].map(value => <Select.Option key={value} value={value}>
							{direction_to_string(value)}
						</Select.Option>)}
					</Select>
				</Form.Item>
				<Form.Item>
					<Button htmlType="submit" type="primary">
						<SaveOutlined /> Save
					</Button>
				</Form.Item>
			</Form>
		</Modal>
	</PageLayout>;
}
