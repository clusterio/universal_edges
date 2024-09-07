import { Input } from "antd";
import { useState } from "react";

interface InputPositionProps {
	id?: string;
	value?: string[];
	onChange?: (value: string[]) => void;
}

/**
 * Input position coordinates and get [x, y] as value, for use in antd Form
 */
export default function InputPosition(props: InputPositionProps) {
	const { id, value = ["0", "0"], onChange } = props;

	return (
		<span id={id}>
			<Input
				value={value[0]}
				onChange={e => onChange?.([e.target.value, value[1]])}
				style={{ width: 100 }}
			/>
			<Input
				value={value[1]}
				onChange={e => onChange?.([value[0], e.target.value])}
				style={{ width: 100 }}
			/>
		</span>
	);
}
