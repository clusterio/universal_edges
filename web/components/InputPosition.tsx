import { Input } from "antd";
import { useState } from "react";

interface InputPositionProps {
	id?: string;
	value?: number[];
	onChange?: (value: number[]) => void;
}

/**
 * Input position coordinates and get [x, y] as value, for use in antd Form
 */
export default function InputPosition(props: InputPositionProps) {
	const { id, value = [], onChange } = props;
	const [x, setX] = useState(0);
	const [y, setY] = useState(0);

	function triggerChange(changedValue: { x?: number; y?: number }) {
		onChange?.([changedValue.x || x, changedValue.y || y]);
	};

	function onXChange(e: React.ChangeEvent<HTMLInputElement>) {
		const newX = parseInt(e.target.value || "0", 10);
		if (Number.isNaN(x)) {
			return;
		}
		setX(newX);
		triggerChange({ x: newX });
	};
	function onYChange(e: React.ChangeEvent<HTMLInputElement>) {
		const newY = parseInt(e.target.value || "0", 10);
		if (Number.isNaN(y)) {
			return;
		}
		setY(newY);
		triggerChange({ y: newY });
	};

	return (
		<span id={id}>
			<Input
				value={value[0] || x}
				onChange={onXChange}
				style={{ width: 100 }}
			/>
			<Input
				value={value[1] || y}
				onChange={onYChange}
				style={{ width: 100 }}
			/>
		</span>
	);
}
