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
  - [x] Train fuel and schedules go missing
  - [ ] Retry sending when destination gets unblocked
    - [ ] Check flow before sending
    - [ ] Check signal status in push trains to reset flow
  - [ ] Test all 4 in and out directions
  - [ ] Pathfinding
