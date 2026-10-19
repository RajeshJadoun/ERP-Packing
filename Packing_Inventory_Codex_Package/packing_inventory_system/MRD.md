# MRD — Material Requirements
## Material variants
Treat materially different sizes/specifications as distinct stock items (e.g. Screw 8mm vs Screw 10mm, Poly Bag 8x4). Dimensions may be nullable when not applicable.

## Units and conversion
Use a canonical base unit per material variant. Support PCS, KG, BOX and future units. Conversion rules are material-specific and tagged `exact` or `estimated`, with factor, effective dates and provenance. Example: 1 kg ≈ 100 poly bags is estimated unless validated by exact counting. Preserve measured kg separately from estimated PCS; never add KG and PCS together without a valid conversion.

## BOM
BOM header: product, optional party, packing variant/name, version, status and effective dates. Lines: material variant, quantity per finished unit, unit, required/optional flag and notes. BOM changes create versions; released jobs keep immutable BOM snapshots.

## Daily jobs
A daily plan groups independently tracked jobs. Each job has party, product, quantity, BOM snapshot and status. Repeated party/product rows are allowed for different packing specifications. Copy prior configurations; customize at job level without altering the master BOM.

## Examples
- BOM: 1 poly bag + 1 foam + 4 screws per product. Plan 1000, complete 530: theoretical requirement = 530 bags, 530 foam, 2120 screws.
- Revise 520 to 450: preserve old/new values and reason; recalculate reservation.
- Cancel before issue: release reservation. Cancel after issue: reconcile custody/returns. If some units were packed, preserve completed quantity and cancel only eligible remainder.
- Receive 25 kg poly bags; with estimated 1 kg ≈ 100 PCS, display ≈2500 PCS, not exact 2500. If kg is canonical, authoritative stock remains 25 kg.

## Ground rule
Software cannot know how many loose bags a worker took unless the process measures, weighs or uses standard bundles. Capture the measurement method; never invent unknown quantities.
