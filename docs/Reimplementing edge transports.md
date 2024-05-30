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

## Belts

1. Belt is placed facing border
2. `edge_link_update` is sent to partner
3. Link is created on partner
4. Item enters into link, is sent to partner
5. Partner is full, sends `edge_link_update` with set_flow = false

Issues:
- Connectors can only created/removed while link is active

## Fluids

1. Pipe is placed near border
2. `edge_link_update` is sent to partner
3. Link is created on partner
4. Tank fills with fluid
5. Current fluid level is sent to partner.
   1. If partner receives higher fluid level than current, set current level to average between local level and parther level
   2. Send back amount added as amount_balanced
   3. Origin removes the amount_balanced from their storage tank

This allows for 2 way flows and makes the flow physics act pretty similar to vanilla pipes.

## Electricity transfer

### Option 1: Balancing accumulator

Simply balancing an accumulator is not sufficient since accumulators don't redsitribute. Implementing general accumulator redistribution would be expensive with a lot of solar and accumulators. One solution could be to rebalance with accumulators, then spawning a temporary generator to "drain" the accumulator when it is full.

### Option 2: bidirectional directional power transfer.

On both sides:
- A burner generator with a special energy item in it with secondary priority
- An accumulator for charge monitoring
- An EEI for consumption

If the accumulator charge + fuel in generator gets unbalanced, the EEI is activated on the side with a higher charge to refuel the generator. The generator on the lower side is always running. Fuel is capped at equivalent of X number of full accumulators.

This approach is also good because it makes it clear how much power is imported/exported in the graph.

This approach requires a mod to provide the fuel generator (unless I can figure out how to use EEI with secondary priotity maybe). It is probably not worth implementing both and mods are now low friction enough that I find this acceptble.

### Option 3: Simplify and just use a single electric energy interface

There is one electric energy interfae on either side. Lets say it holds 100 MJ. It acts like an accumulator. If there is excess power, it will charge. It has *secondary* input priority, this means it will recharge from accumulators while also having *tertiary* output priority, preventing it from recharging accumulators but allowing it to charge other edge links.

1. Substation is placed next to border
2. Electric energy interface is created on both sides of border with generation 0w usage 0w
3. generation = min(50mw, max(0, (remote - local) - 10mj))
4. comsumption = min(50mw, max(0, (local - remote) - 10mj))

usage_priority:
- solar
  - Solar panels, free power
- lamp
  - lamp
- primary-output
  - Portable fusion reactor
- primary-input
  - Personal shields
  - rocket silo
- secondary-output
  - burner-generator
  - steam-engine
  - steam-turbine
- secondary-input
  - assemblers etc
- tertiary
  - accumulator

Priority doesn't work quite right.

- When `secondary-input` it charges from accumulators
- When `secondary-output` it recharges accumulators

but I want both. I can achieve this by either usign 2 entities, or swapping the entity at some point.

1. Swap to output when above 50%, input when below 50%
2. Use one entity with output and one with input, balancing them continuously in script
   1. I think this is actually worse for performance and might mess with the graph more, so i avoid it

This is not working, we are going back to fluids with a sense loop

1. Balance EEI energy same as fluids
2. Use charge sensor accumulator to see how things are going
   1. If charge sensor < 10%, `secondary-output`
   2. If charge sensor > 10%
      1. If EEI < 50% `secondary-input`
      2. If EEI > 50% `tertiary`
