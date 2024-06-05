# Universal edges

A clusterio plugin for seemlessly combining factorio servers

Based on edge transports by @Hornwitser

## Differences from edge transports
- Uses global config system instead of instance config
- Rewritten in typescript
- Support for fluids, electricity and trains (eventually)

## Features

- [x] Web gui for configuration
- [x] Belt transfers
- [x] Fluids transfers
- [x] Electricity transfers
- [ ] Train transfers
  - [x] Delete source train
  - [ ] Correct landing location
  - [ ] Rotate trains when landing 
  - [x] Train fuel and schedules go missing
  - [x] Retry sending when destination gets unblocked
  - [ ] Test all 4 in and out directions
  - [ ] Pathfinding
    - [x] Make it only check paths after a change event
    - [x] Test creating penalty map on source
    - [x] Update local destinations when a source updates
    - [ ] Update on edge activation/deactivation
