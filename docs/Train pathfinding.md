# Train pathfinding

To be vanilla compatible, we have to let trains use vanilla pathfinding. This means we need to mirror all reachable trainstops and pathfinding penalties on edge connectors. This is a lot of data to sync, so it is critical to keep it infrequent.

The following should trigger penalty updates:
- Train station placed/removed on destination (delayed and debounced)
- Rail placed/destroyed on destination (very delayed and debounded)
- Connector on destination had significant penalty update (delayed and debounced)
  - New station added
  - Penalty changed by more than 50k - This is **critical** to avoid infinite update loops
- Link changed to inactive (set penalty to 10m)
- Link changed to active (reset penalty to whatever it was before)

Each edge traversed adds another 100k to the penalty.
