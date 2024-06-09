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
import { EdgeTargetSpecification } from "../../src/types";
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
							const updates = [...edgeConfigs.values()].map(edge => {
								return {
									...edge,
									isDeleted: true,
								}
							});
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
					</Popconfirm>
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
					values.length = Number(values.length);
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
