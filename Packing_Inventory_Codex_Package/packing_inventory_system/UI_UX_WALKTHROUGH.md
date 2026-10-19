# UI/UX Walkthrough
## Sidebar
Dashboard; Masters (Parties, Products, Materials, Vendors, Locations, Workers, Units/Conversions); Purchasing (Purchase Orders, Inward, History); Inventory (Current Stock, Ledger, Issue, Worker Custody, Return, Transfer, Damage, Adjustment); Packing (BOM Master, Daily Plans, Jobs, Production Completion, Daily Closing); Reports; Admin.

## Dashboard
Cards: today's jobs, completed, pending, low stock, shortage, worker outstanding and variance. Main table shows Party, Product, BOM/variant, Planned, Completed, Pending, Status. Alerts explain why and link to the correct action.

## Daily Packing Plan
Choose date and add multiple jobs. Each job selects party, product, quantity and default BOM. “Customize Packing” creates a job snapshot. Duplicate product rows are allowed for different specifications. Draft then Release.

## Packing Job detail
Show party/product, frozen BOM, planned/revised quantity, completed/pending, reservation, issued, worker custody, theoretical usage, actual usage, return and variance. Actions depend on role/status.

## Production
Enter actual packed finished units. Display theoretical BOM usage separately. Actual usage is measured/confirmed or follows a clearly configured auto-consumption policy. Never label theoretical usage as measured truth.

## Revision/cancellation
Require reason, show effect on reservations/requirements, preserve audit history. If issue/consumption/completion exists, show reconciliation checklist and block unsafe cancellation.

## Stock and closing
Show physical stock, reserved, available and worker custody separately. Item history lists every movement and linked receipt/job/worker. Closing summarizes plan quantities, expected/actual usage, variance and custody outstanding. Exceptions must be resolved or explicitly approved with reason.
