import React, { useContext, useState } from "react";
import { Button, Card, Divider, Form, Input, Modal, Select, Table } from "antd";
import { SaveOutlined } from "@ant-design/icons";

import {
	PageLayout, ControlContext,
	useInstance
} from "@clusterio/web_ui";

import * as messages from "../../messages";
import { Edge, EdgeTargetSpecification } from "../../src/types";
import { WebPlugin } from "..";
import { InstanceSelector } from "../components/InstanceSelector";
import { direction_to_string } from "../../src/util/direction_to_string";
import InputPosition from "../components/InputPosition";

export default function EdgeListPage() {
	const control = useContext(ControlContext);
	const plugin = control.plugins.get("universal_edges") as WebPlugin;
	const [edgeConfigs, synced] = plugin.useEdgeConfigs();
	const [editing, setEditing] = useState("");

	const fIStyle = {
		style: {
			marginBottom: "5px",
		},
	};

	return <PageLayout nav={[{ name: "Universal edges" }]}>
		<h2>Universal edges</h2>
		Synced: {String(synced)} Data: {JSON.stringify([...edgeConfigs.values()])}
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
				}
			})}
		/>
		<Modal
			title="Edit edge"
			open={!!editing}
			onCancel={() => setEditing("")}
			destroyOnClose // Reset form when modal is closed
			footer={null}
		>
			<Form
				preserve={false} // Reset form when modal is closed
				size="small"
				labelCol={{ span: 8 }}
				wrapperCol={{ span: 16 }}
				onFinish={(values) => {
					values.id = editing;
					values.updatedAtMs = Date.now();
					values.source.ready = false;
					values.target.ready = false;
					values.active = false;
					console.log(values);
					control.send(new messages.SetEdgeConfig(values));
				}}
				initialValues={edgeConfigs.get(editing) || {
					isDeleted: false,
					length: 10,
					active: false,
					source: {
						instanceId: undefined,
						origin: [0, 0],
						surface: 1,
						direction: 0,
						ready: false,
					},
					target: {
						instanceId: undefined,
						origin: [0, 0],
						surface: 1,
						direction: 0,
						ready: false,
					},
				}}
			>
				<Form.Item {...fIStyle} name="isDeleted" label="Delete" valuePropName="checked">
					<Input type="checkbox" />
				</Form.Item>
				<Form.Item {...fIStyle} name="length" label="Length">
					<Input type="number" />
				</Form.Item>
				<Divider>Source</Divider>
				<Form.Item {...fIStyle} name={["source", "instanceId"]} label="Source instance">
					<InstanceSelector />
				</Form.Item>
				<Form.Item {...fIStyle} name={["source", "origin"]} label="Position">
					<InputPosition />
				</Form.Item>
				<Form.Item {...fIStyle} name={["source", "surface"]} label="Surface">
					<Input />
				</Form.Item>
				<Form.Item {...fIStyle} name={["source", "direction"]} label="Direction">
					<Select>
						{[0, 2, 4, 6].map(value => <Select.Option key={value} value={value}>
							{direction_to_string(value)}
						</Select.Option>)}
					</Select>
				</Form.Item>
				<Divider>Target</Divider>
				<Form.Item {...fIStyle} name={["target", "instanceId"]} label="Target instance">
					<InstanceSelector />
				</Form.Item>
				<Form.Item {...fIStyle} name={["target", "origin"]} label="Position">
					<InputPosition />
				</Form.Item>
				<Form.Item {...fIStyle} name={["target", "surface"]} label="Surface">
					<Input />
				</Form.Item>
				<Form.Item {...fIStyle} name={["target", "direction"]} label="Direction">
					<Select>
						{[0, 2, 4, 6].map(value => <Select.Option key={value} value={value}>
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

function EdgeTarget({ target }: { target: EdgeTargetSpecification }) {
	const [instance] = useInstance(target.instanceId);

	return <Card size="small" title={instance?.name || target.instanceId}>
		<p>Origin: {JSON.stringify(target.origin)}</p>
		<p>Surface: {target.surface}</p>
		<p>Direction: {target.direction}</p>
		<p>Ready: {target.ready?.toString()}</p>
	</Card>
}
