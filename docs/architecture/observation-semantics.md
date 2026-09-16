# Bounded Observation Semantics

Issue #215 defines the collector contract for evidence that represents a bounded period of time rather than a point-in-time configuration inventory.

This is an **opt-in foundation**. Existing Stage1/Stage2/Stage3 families remain point-in-time unless a consuming family explicitly adopts this contract. Time does not create a fourth collection stage.

## Observation descriptor

A bounded snapshot carries `observation` in addition to the normal provenance envelope.

```text
observation
  schemaVersion: 1.0
  requested
    startUtc
    endUtc
  eventTimeProperty
  providerAvailable
    startUtc
    endUtc
    retentionCaveat
  planIdentity
```

`requested.startUtc` and `requested.endUtc` are the operator/collector-requested evidence interval. They are normalized to UTC round-trip timestamps before identity comparison or persistence. Input timestamps without an explicit UTC designator or numeric offset are rejected because they are ambiguous.

`eventTimeProperty` names the provider field whose event timestamp defines membership in the requested interval when the consuming family has one. It is part of plan identity because changing the timestamp semantic changes the observation even if the clock boundaries are unchanged.

`providerAvailable` is separate from `requested`. It is optional and records only provider evidence actually known during collection. A provider may expose a start boundary, an end boundary, a retention caveat, or a combination. The collector must not invent a retention boundary that the provider did not expose or that the consuming family cannot justify.

`planIdentity` is a deterministic SHA-256 identity over the normalized requested start/end and event-time property. Provider-available boundaries are deliberately excluded because they are observed execution evidence, not requested plan input.

## Resume identity

Bounded families use `Initialize-CollectorBoundedCheckpointPlan` instead of the ordinary plan initializer.

The underlying batch/BatchSize/source-fingerprint compatibility rules remain unchanged. The bounded adapter adds an observation-plan descriptor to the checkpoint and requires the persisted `planIdentity` to equal the current normalized requested window identity before successful prior work may be reused.

Equivalent absolute windows expressed with different offsets normalize to the same plan identity. A changed start, end, or event-time property is incompatible and fails closed rather than reusing numeric batch IDs from a different observation.

A historical checkpoint containing successful batches but no bounded observation identity cannot be resumed as a bounded family. It must be recollected without `-Resume` so evidence from an unknown time window is not silently reused.

## Availability and completeness

Every bounded snapshot carries `evidenceState` together with `observation`. Neither property is valid by itself.

The contract intentionally uses two closed dimensions:

| availability | allowed completeness | Meaning |
| --- | --- | --- |
| `available` | `complete` | Provider evidence covered the requested interval and the family reached its terminal collection state. Zero events is a valid result. |
| `available` | `partial` | Provider was available but the collected result is known to be truncated/incomplete, for example a provider/export cap or other bounded partial result. |
| `permission-denied` | `unavailable` | Required read access was not available. This is not equivalent to zero events. |
| `feature-unavailable` | `unavailable` | The provider/tenant feature needed by the family is unavailable. |
| `license-unavailable` | `unavailable` | Required licensing is unavailable. |
| `retention-limited` | `partial` | The requested interval extends beyond provider-available history. A provider boundary or retention caveat must support the classification. |
| `failed` | `failed` | Ordinary collector/provider execution failure. This does not satisfy bounded plan completion. |

Free-form `detail` text is optional supplemental evidence. It never replaces the machine-readable state.

### Complete zero versus unavailable zero

`itemCount = 0`, `availability = available`, and `completeness = complete` means the provider was successfully queried for the bounded interval and returned no events/items.

`itemCount = 0` with `permission-denied`, `feature-unavailable`, `license-unavailable`, or `retention-limited` has materially different meaning and must remain machine-readable as such. Consumers must not collapse these states into an empty successful inventory.

## Provider-window truthfulness

A snapshot cannot claim `available/complete` when a persisted provider-available start is later than the requested start or a provider-available end is earlier than the requested end. Such evidence must instead use a truthful partial/retention classification.

`retention-limited/partial` is accepted only when `providerAvailable` carries at least one concrete boundary or a retention caveat. This prevents the collector from manufacturing a retention explanation with no supporting provider evidence.

## Plan completion versus evidence completeness

Checkpoint `plan.completed` means that every planned unit reached a validated terminal collection artifact. It does **not** mean the provider could supply the entire requested historical interval.

Therefore a `retention-limited/partial` bounded observation may complete its checkpoint plan: execution is terminal and fully accounted for, while the snapshot still truthfully says the requested evidence is partial.

A snapshot classified `failed/failed` cannot satisfy bounded checkpoint completion even if a caller accidentally records the batch as `Succeeded`.

## Snapshot and package validation

Snapshot schema version remains `1.0`; bounded metadata is an additive optional extension. Point-in-time snapshots omit both `observation` and `evidenceState` and remain valid without migration.

`Test-CollectorSnapshotSchemaVersion` validates the bounded pair when present, including:

- normalized UTC requested/provider timestamps;
- deterministic plan identity;
- closed availability/completeness vocabulary and allowed combinations;
- retention evidence requirements;
- prevention of complete-overclaim against a narrower provider window.

`Complete-CollectorBoundedCheckpointPlan` additionally verifies that every successful planned artifact contains a valid bounded snapshot whose `planIdentity` matches the checkpoint observation plan.

Offline catalog/package generation continues to use the existing v1 catalog descriptor shape. The raw snapshot and checkpoint remain the source of truth; catalog generation revalidates the snapshot contract and checkpoint terminal state without contacting a provider. An invalid bounded state therefore fails package regeneration instead of being silently indexed.

The catalog intentionally does not copy `observation`, `evidenceState`, `requestContext`, or payload items into its metadata-only descriptors in this foundation slice. Consumers follow the canonical artifact path to the raw bounded snapshot when temporal evidence details are needed.

## High-volume and paged observations

This foundation does not prescribe one paging/export strategy. A future bounded family must map its real provider behavior into deterministic planned batches/pages/windows and may set checkpoint completion only after every planned unit reaches a terminal artifact.

The family must not infer history outside a provider-supported interval. If the provider returns only part of the requested interval because of retention, the terminal snapshot must remain `retention-limited/partial` even when every available page was collected successfully.

## Non-goals

Issue #215 does not:

- add sign-in, audit, provisioning, service-health, Defender, incident, alert, report, or other live telemetry endpoints;
- choose a global/default lookback for future families;
- create Stage4;
- change Graph/provider token ownership;
- add cross-provider identity correlation;
- create continuous streaming or infinite history;
- reinterpret current point-in-time families as historical evidence.
