# Stage dependency failure semantics

Issue #220 defines how one invocation handles a provider/family failure in an earlier collection stage without allowing a later dependency gate to obscure the initiating error.

## Principle

Stage1 remains the prerequisite inventory for Stage2 and Stage3. Inventory-first validation still fails closed when Stage2 or Stage3 is explicitly invoked against missing, stale, or incompatible prior evidence.

Within a single multi-stage invocation, however, the collector already knows when a selected section failed upstream. Invoking a dependent stage for that same section would add no trustworthy evidence and can replace the useful provider/authentication/connectivity error with a secondary missing-inventory error.

## Invocation-local blocking

The orchestrator maintains an in-memory set of blocked sections for the current invocation only.

- A persisted Stage1 result with `failedBatches > 0` blocks that section from Stage2 and Stage3 in the same invocation.
- A persisted Stage2 result with `failedBatches > 0` blocks that section from Stage3 in the same invocation.
- Other selected sections remain eligible and continue normally.
- All completed/failed family results are persisted before they influence later-stage eligibility.
- The original family error remains in the invocation/run `failures` collection.

The block is deliberately section-scoped rather than family-scoped. Current stage APIs execute section groups, and a failed prerequisite family means the section does not have a complete trustworthy prerequisite set. A separate family dependency graph would add complexity without a current correctness requirement.

## What does not change

- Stage2-only and Stage3-only invocations do not inherit an in-memory block set from earlier invocations. They continue to execute their existing inventory-first checks against persisted checkpoints/artifacts.
- Resume and failed-only checkpoint semantics are unchanged.
- Stage1, Stage2, and Stage3 collector modules retain ownership of their provider and inventory validation behavior.
- No checkpoint, snapshot, catalog, or run-manifest schema changes are introduced.
- A hard thrown orchestration/provider exception still follows the existing terminal `Failed` path; this contract addresses durable family results that report `failedBatches > 0` without throwing.

## Operator-visible outcome

When an upstream provider failure is represented as a failed family result, the invocation can finish as `CompletedWithErrors` after independent sections complete. The returned and persisted failure remains the initiating Stage1/Stage2 family error; a blocked dependent stage does not manufacture a replacement inventory-first failure.
