# Universal edges

A clusterio plugin for seemlessly combining factorio servers

Based on edge transports by @Hornwitser

## Setup

	npm install universal_edges
	npx clusteriocontroller plugin add universal_edges

Edges are configured through the web interface.

## Differences from edge transports
- Uses global config system instead of instance config
- Rewritten in typescript
- Support for fluids, electricity and trains (eventually)

## Features

- [x] Web gui for configuration
	- [ ] Handle connectors when edges are moved
- [x] Belt transfers
- [x] Fluids transfers
- [x] Electricity transfers
- [ ] Train transfers
	- [x] Delete source train
	- [x] Correct landing location
	- [x] Rotate trains when landing 
	- [x] Train fuel and schedules go missing
	- [x] Retry sending when destination gets unblocked
	- [ ] Test all 4 in and out directions
	- [x] Pathfinding
		- [x] Make it only check paths after a change event
		- [x] Test creating penalty map on source
		- [x] Update local destinations when a source updates
		- [x] Update on edge activation/deactivation
		- [ ] Global option to not repath on edge deactivated
- [ ] Vehicle support (cars, tanks)
- [ ] Spidertron support (like vehicles, but with paths saved)

## Development

### Publishing releases

Releases are built and published with github actions. To publish a new version, run `npm version <major|minor|patch>` and push the commit and tag using `git push --tags`
