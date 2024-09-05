/**
 * If edge direction is 8 (West), that means the belts enter going north to south.
 * The right hand side of the edge is always the entrance/exit
 *
 * WARNING: Not same indexes as factorio defines direction!
 * These are turned 90 degrees counter clockwise, that is North here = West in factorio
 */
export const directions = [
	"East",
	"East south-east",
	"South-east",
	"South south-east",
	"South",
	"South south-west",
	"South-west",
	"West south-west",
	"West",
	"West north-west",
	"North-west",
	"North north-west",
	"North",
	"North north-east",
	"North-east",
	"East north-east",
];

export function direction_to_string(direction: number | undefined) {
	if (direction === undefined) {
		return "";
	}
	if (typeof direction !== "number" || direction < 0 || direction >= 16) {
		return "unknown";
	}
	return directions[direction % 16];
}
