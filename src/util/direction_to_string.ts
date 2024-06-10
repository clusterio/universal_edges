/**
 * If edge direction is 4 (West), that means the belts enter going north to south.
 * The right hand side of the edge is always the entrance/exit
 * 
 * WARNING: Not same indexes as factorio defines direction!
 * These are turned 90 degrees counter clockwise, that is North here = West in factorio
 */
export const directions = [
	"East",
	"South-east",
	"South",
	"South-west",
	"West",
	"North-west",
	"North",
	"North-east",
];

export function direction_to_string(direction: number | undefined) {
	if (direction === undefined) {
		return "";
	}
	if (typeof direction !== "number" || direction < 0 || direction >= 8) {
		return "unknown";
	}
	return directions[direction % 8];
}
