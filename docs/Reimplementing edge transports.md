# Reimplementing edge transports

First principes - what do we need?

Each instance must know the following:
- Edges
  - Edge origin
  - Edge length
  - Edge direction
  - Is edge ready? - Everything is set correctly on this side of the link
  - Is edge active?
    - Tracked on the controller. If both instances are `ready` and the configuration makes sense, the link is active
  - Connectors[]
    - InBelt/OutBelt/InTrain/OutTrain/InFluid/OutFluid?
    - Is blocked?

## Blocking

It is important that the origin connector gets blocked if the target is backed up or offline. For trains it must be immediately blocked as we do not want trains waiting in limbo. For chests there needs to be a buffer.

The following blocking logic applies:
- If the edge is not active, block the origin connector
- For trains:
  - When a train is sent, set the blocked status of the origin connector to 0 (for allowing a train length of 0)
  - When the train clears the destination connector, set the blocked status of the origin connector to the max train length that can be received
- For belts:
  - When an item is sent, add the amount of items sent to the blockign status of the origin connector
  - When an item is received and output, set the blocking status of the origin connector to the number of items buffered in the destination chest
  - When blocking status > buffer size, block the origin connector
- For bidirectional fluids:
  - One tank is on each side of the link with a capacity of 25k fluid. Edge transports will attempt to balance the fluid levels at ~12.5k fluid each.
  - Both tanks send their fluid capacity to the controller. The controller will send an add/subtract request to either side when it detects a sizeable imbalance.
  - There is no blocking. If the fluid is not being consumed, it will simply fill up the tanks.
- For power:
  - Same as fluids, but with a modded accumulator

## Messages

### Requests

- SetEdgeConfig - Control -> Controller

### Events

- EdgeUpdate - Controller -> Instance & Control
  - Edge config/active status has been updated
- EdgeConnectorUpdate - Instance -> Controller, Controller -> Instance
  - Controller translates InBelt -> OutBelt etc
- EdgeTransfer - Instance | Controller -> Instance (Does this allow trains to be eaten? Send trains and delay deletion?)
  - Edge ID, Type, Amount, Connector position

## Active status

The active status is key in managing edges. Generally, this is the value you want to diagnose when something is not working.

The active status is FALSE when:
- Either instance is not running
- Source and target is on the same instance

The active status is part of and synchronized with the edge config.

## Connectors

A connector is a singular link, for example a single belt running across the edge. There are different types of connectors for belts, fluids, power and trains, but they use the same code as much as possible.

### Lifecycle

1. Belt is placed facing border
2. `EdgeConnectorUpdate` is sent to partner instance
3. Belt is placed facing away from border on partner, `EdgeConnectorUpdate` is sent
4. Items enter connector and are transfered with `EdgeTransfer`
5. Partner sends `EdgeConnectorUpdate` for destination blocked status
6. Belt is removed, edge is removed or edge position changes
   1. `EdgeConnectorUpdate` is sent to remove the connector on the partner
   2. Waiting items are voided

It is important to note that `EdgeConnectorUpdate` has to be sent both ways to track the status of the link initiator belts. The connector is not removed before the connected belts are removed from both sides of the link.
