import { RefSelectProps, Select, SelectProps } from "antd";
import { useInstances } from "@clusterio/web_ui";
import { DefaultOptionType } from "antd/es/select";
import { ReactNode, RefAttributes } from "react";
import { JSX } from "react/jsx-runtime";

export function InstanceSelector(props: JSX.IntrinsicAttributes
	& SelectProps<any, DefaultOptionType>
	& { children?: ReactNode; } & RefAttributes<RefSelectProps>
) {
	const [instances] = useInstances();
	return <Select
		{...props}
		style={{ width: "auto", minWidth: "200px" }}
	>
		{[...instances.values()].map?.(instance => <Select.Option key={instance.id} value={instance.id}>
			{instance.name}
		</Select.Option>)}
	</Select>;
}
