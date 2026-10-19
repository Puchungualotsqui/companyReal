# Town economy design

All units belong to a town. Workers operate automatically; players only change citizens' roles. Food and water are static town potentials, recalculated from terrain, assigned workers, and buildings rather than tracked as stocks.

- **Builder:** gathers wood from nearby trees, builds one home per citizen, and builds farmland on growable ground.
- **Water Collector:** contributes to the town's water potential based on nearby fresh water.
- **Farmer:** works the town's farmland to contribute to food potential.

Population growth stops when the town cannot support another citizen with its food and water potential. A unit without a home regenerates health more slowly. Shortages affect only units belonging to that town: low water randomly slows combat units; low food randomly increases their cooldown. The share of affected units is proportional to the shortage.
