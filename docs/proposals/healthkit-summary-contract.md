# Draft: Apple Health summary bridge

Status: accepted direction in Discussion #176; contract-only implementation in
progress. No HealthKit entitlement, authorization UI, queries, server adapter,
or widget is included in this slice.

This proposal adds an explicitly enabled, read-only Apple Health integration to
Tesserae Companion. The iPhone remains authoritative. Companion converts only
the user's selected HealthKit categories into a bounded seven-day summary and
publishes that summary directly to the user's paired Tesserae Server.

The HealthKit-specific direction was accepted by the Tesserae maintainer in
Discussion #176. The authoritative OpenAPI, synthetic fixtures, Swift models,
privacy text, and tests now form the next reviewable contract-only Draft PR.

## Confirmed product decisions

- The first release includes daily activity, sleep, and workout details.
- The snapshot covers the latest seven calendar dates in the active Tesserae
  instance's IANA time zone, including the current partial date.
- A sleep night belongs to the date on which the primary sleep episode ends.
- Workout start and end times are included.
- Before showing Apple's authorization sheet, Companion explains every data
  type it will request and every field it may upload.
- Users choose whether Activity, Sleep, and Workouts are included. All three
  choices default to off.
- Apple remains the final authorization authority and presents its own
  per-type read controls.
- Tesserae may retain an already-rendered health Dashboard in its ordinary live
  History thumbnail cache. The app must disclose this before enablement and on
  the Apple Health settings page.

## Proposed capability and endpoint

The server advertises both the separate Health feature and the strict source:

```json
{
  "features": ["personal_data_health"],
  "personal_data": {
    "sources": ["reminders", "reminders.fridge", "health.summary"]
  }
}
```

The proposed source ID is `health.summary`, not `health.daily`, because the
payload contains per-workout records and per-night sleep summaries in addition
to daily activity totals.

It reuses the accepted generic family and existing write-only server scope:

```http
PUT    /api/app/v1/personal-data/health.summary
DELETE /api/app/v1/personal-data/health.summary
GET    /api/app/v1/personal-data/status
```

The envelope remains `personal_data_bridge_v1`. Its latest-only, required
expiry, atomic replacement, publisher isolation, ordering, status, and DELETE
semantics do not change. The server exposes freshness metadata but no API for
reading raw health snapshot values.

Health support is never inferred from Reminders support or from the generic
`personal_data:write` scope. Companion exposes the integration only when both
`personal_data_health` appears in `features` and `health.summary` appears in
`personal_data.sources`.

## Consent and authorization model

There are two separate decisions:

1. Companion upload selection controls which sections may leave the iPhone for
   the selected Tesserae instance.
2. Apple's Health authorization sheet controls which HealthKit object types the
   app may read.

Companion requests no write access and does not save anything to Apple Health.
The main app target needs the HealthKit entitlement and
`NSHealthShareUsageDescription`. The Share Extension receives no HealthKit
entitlement and cannot read health data.

Apple intentionally does not reveal whether read access to an individual type
was denied. A successful authorization request means the sheet completed, not
that every requested read type was granted. Companion therefore must not show
fabricated per-type states such as "Deep Sleep denied." For a requested type it
can truthfully say only that readable data was found or that no readable data
is currently available.

Apple may also let the user grant only a recent portion of Health history.
Companion honors that system selection and never asks the user to broaden it.
Dates earlier than the readable window use the same null/empty representation
as any other date for which no value is readable.

Turning off a Companion section stops uploading it but does not revoke Apple's
Health permission. Users manage Health permissions in Apple Health or iOS
Settings. Turning off the final section issues DELETE for `health.summary`.

### Permission and field map

| Companion choice | Apple Health read type | Values that may leave the phone |
| --- | --- | --- |
| Activity | `HKObjectType.activitySummaryType()` | Move mode, active energy or move minutes, exercise minutes, stand hours, and the corresponding goals |
| Activity | `HKQuantityType(.stepCount)` | Per-day step total |
| Activity | `HKQuantityType(.distanceWalkingRunning)` | Per-day walking and running distance |
| Sleep | `HKCategoryType(.sleepAnalysis)` | Primary episode start/end, total asleep/in-bed/awake time, and Core/Deep/REM/unspecified stage totals |
| Workouts | `HKObjectType.workoutType()` | Opaque workout ID, activity type, start/end, active duration, and multi-activity segment timing |
| Workouts | `HKQuantityType(.activeEnergyBurned)` | Per-workout and per-segment active energy total |
| Workouts | `HKQuantityType(.distanceWalkingRunning)` | Per-workout and per-segment walking/running distance |
| Workouts | `HKQuantityType(.distanceCycling)` | Per-workout and per-segment cycling distance |
| Workouts | `HKQuantityType(.distanceSwimming)` | Per-workout and per-segment swimming distance |
| Workouts | `HKQuantityType(.distanceWheelchair)` | Per-workout and per-segment wheelchair distance |
| Workouts | `HKQuantityType(.flightsClimbed)` | Per-workout and per-segment flights climbed |
| Workouts | `HKQuantityType(.swimmingStrokeCount)` | Per-workout and per-segment swimming stroke count |

The same HealthKit type is requested only once when it supports more than one
enabled section. For example, walking/running distance can support both the
Activity day total and a running workout.

The first release does not request or upload:

- workout routes or any location coordinates;
- heart rate, resting heart rate, heart-rate variability, or heart-rate series;
- raw step, energy, distance, sleep, or workout-associated samples;
- source app names, source bundle identifiers, device names, or device models;
- HealthKit UUIDs;
- workout events, free-form metadata, user-entered titles, or notes;
- clinical records, medications, reproductive health, body measurements, or
  nutrition data.

## Proposed strict wire schema

Wire keys use the existing snake-case JSON convention. The `activity`, `sleep`,
and `workouts` keys are always present and nullable. A selected readable section
remains an object even if its array is empty; null does not claim a specific
HealthKit denial because Apple does not expose individual read authorization.

```json
{
  "version": "personal_data_bridge_v1",
  "source_id": "health.summary",
  "generated_at": "2026-08-14T12:30:00Z",
  "expires_at": "2026-08-16T12:30:00Z",
  "data": {
    "time_zone": "Asia/Shanghai",
    "window_start_date": "2026-08-08",
    "window_end_date": "2026-08-14",
    "activity": {
      "days": [
        {
          "date": "2026-08-08",
          "steps": 7184,
          "walking_running_distance_meters": 5230.8,
          "move_mode": "active_energy",
          "active_energy_kcal": 401.7,
          "active_energy_goal_kcal": 600.0,
          "move_minutes": null,
          "move_goal_minutes": null,
          "exercise_minutes": 27,
          "exercise_goal_minutes": 30,
          "stand_hours": 9,
          "stand_goal_hours": 12
        },
        {
          "date": "2026-08-09",
          "steps": 9630,
          "walking_running_distance_meters": 7012.2,
          "move_mode": "active_energy",
          "active_energy_kcal": 511.6,
          "active_energy_goal_kcal": 600.0,
          "move_minutes": null,
          "move_goal_minutes": null,
          "exercise_minutes": 38,
          "exercise_goal_minutes": 30,
          "stand_hours": 11,
          "stand_goal_hours": 12
        },
        {
          "date": "2026-08-10",
          "steps": 6042,
          "walking_running_distance_meters": 4421.9,
          "move_mode": "active_energy",
          "active_energy_kcal": 366.8,
          "active_energy_goal_kcal": 600.0,
          "move_minutes": null,
          "move_goal_minutes": null,
          "exercise_minutes": 21,
          "exercise_goal_minutes": 30,
          "stand_hours": 8,
          "stand_goal_hours": 12
        },
        {
          "date": "2026-08-11",
          "steps": 11240,
          "walking_running_distance_meters": 8320.5,
          "move_mode": "active_energy",
          "active_energy_kcal": 623.0,
          "active_energy_goal_kcal": 600.0,
          "move_minutes": null,
          "move_goal_minutes": null,
          "exercise_minutes": 51,
          "exercise_goal_minutes": 30,
          "stand_hours": 13,
          "stand_goal_hours": 12
        },
        {
          "date": "2026-08-12",
          "steps": 7789,
          "walking_running_distance_meters": 5662.7,
          "move_mode": "active_energy",
          "active_energy_kcal": 422.4,
          "active_energy_goal_kcal": 600.0,
          "move_minutes": null,
          "move_goal_minutes": null,
          "exercise_minutes": 29,
          "exercise_goal_minutes": 30,
          "stand_hours": 10,
          "stand_goal_hours": 12
        },
        {
          "date": "2026-08-13",
          "steps": 8954,
          "walking_running_distance_meters": 6503.1,
          "move_mode": "active_energy",
          "active_energy_kcal": 477.9,
          "active_energy_goal_kcal": 600.0,
          "move_minutes": null,
          "move_goal_minutes": null,
          "exercise_minutes": 35,
          "exercise_goal_minutes": 30,
          "stand_hours": 11,
          "stand_goal_hours": 12
        },
        {
          "date": "2026-08-14",
          "steps": 8421,
          "walking_running_distance_meters": 6110.4,
          "move_mode": "active_energy",
          "active_energy_kcal": 436.2,
          "active_energy_goal_kcal": 600.0,
          "move_minutes": null,
          "move_goal_minutes": null,
          "exercise_minutes": 32,
          "exercise_goal_minutes": 30,
          "stand_hours": 10,
          "stand_goal_hours": 12
        }
      ]
    },
    "sleep": {
      "nights": [
        {
          "wake_date": "2026-08-14",
          "start_at": "2026-08-13T15:18:00Z",
          "end_at": "2026-08-13T23:06:00Z",
          "in_bed_minutes": 468,
          "asleep_minutes": 432,
          "awake_minutes": 24,
          "core_minutes": 251,
          "deep_minutes": 61,
          "rem_minutes": 98,
          "unspecified_minutes": 22
        }
      ]
    },
    "workouts": {
      "items": [
        {
          "id": "0e6a6183c76c0ee93a41d163",
          "activity_type": "running",
          "start_at": "2026-08-14T10:02:00Z",
          "end_at": "2026-08-14T10:46:13Z",
          "duration_seconds": 2531,
          "active_energy_kcal": 386.7,
          "walking_running_distance_meters": 6231.5,
          "cycling_distance_meters": null,
          "swimming_distance_meters": null,
          "wheelchair_distance_meters": null,
          "flights_climbed": null,
          "swimming_stroke_count": null,
          "segments": [],
          "segments_truncated": false
        }
      ],
      "items_truncated": false
    }
  }
}
```

### Common envelope rules

- `version` must equal `personal_data_bridge_v1`.
- `source_id` must equal both `health.summary` and the endpoint path value.
- `generated_at` and `expires_at` are UTC ISO 8601 instants.
- `expires_at` must be after `generated_at` and no later than the server's
  advertised personal-data maximum TTL. The proposed initial policy remains
  stale after 24 hours and expired after at most 48 hours.
- `data` permits only `time_zone`, `window_start_date`, `window_end_date`,
  `activity`, `sleep`, and `workouts`.
- `time_zone` must be the active Tesserae instance's valid IANA time zone.
- `time_zone` is a 1-64 character identifier recognized by the server's time
  zone database; fixed abbreviations such as `CST` are invalid.
- The date window is inclusive, ordered, and exactly seven calendar dates.
- At least one of `activity`, `sleep`, or `workouts` must be non-null.
- Unknown fields are rejected at every level.
- The decoded request body is limited to 256 KiB.

### Missing and zero values

Numeric fields are nullable but, when their parent record exists, are explicit.

- `0` means HealthKit returned a real zero.
- `null` means no value was readable. It does not claim whether the user denied
  access, no source recorded data, or HealthKit returned no statistic.
- The server and widgets must never coerce `null` to zero.
- No authorization state is uploaded to the server.

Quantities use canonical units only: count, kilocalories, metres, minutes,
hours, and seconds. Energy and distance are rounded to one decimal place;
durations and counts are rounded to whole units. Values must be finite and
non-negative.

### Activity rules

- When Activity is enabled, `days` contains exactly one record for every date
  in the seven-date window, in ascending order.
- `date` values are unique and must match the window dates.
- `steps` is a non-negative integer or `null`.
- Distances and energy are finite non-negative numbers or `null`.
- Durations, stand hours, and goals are non-negative integers or `null`.
- Per-day steps are bounded at 1,000,000; walking/running distance at
  1,000,000 metres; active energy at 100,000 kcal; move/exercise minutes at
  1,440; and stand hours at 24. Goal fields use the same unit bounds. These are
  corruption guards, not physiological judgments.
- `move_mode` is `active_energy`, `move_time`, or `null`.
- In `active_energy` mode, the energy value and goal may be present while the
  move-minute pair must be null. In `move_time` mode the inverse applies.
- A missing activity summary makes all ring values, goals, and `move_mode`
  null. It does not affect separately readable steps or distance.
- The current date is explicitly partial until a later snapshot replaces it.

### Sleep normalization and rules

The contract carries summaries, not raw `HKCategorySample` objects.

- Query far enough before `window_start_date` to capture a sleep episode that
  began on the preceding date and ended inside the seven-date window.
- Build candidate episodes from authorized sleep-analysis samples; a gap of
  three hours separates episodes.
- Ignore candidate episodes with less than 60 minutes of unioned asleep time so
  ordinary naps do not become the night's primary sleep.
- For each `wake_date`, keep the candidate with the greatest unioned asleep
  duration. A deterministic local tie-break chooses the later end time.
- To avoid double counting competing apps and devices, choose one source for
  the episode: greatest coverage of specific Core/Deep/REM stages, then greatest
  total asleep coverage, then a stable local tie-break. Source identity is used
  only on the phone and is never uploaded.
- Merge overlapping intervals from that source before calculating durations.
- `asleep_minutes` is the union of Core, Deep, REM, and unspecified-asleep
  intervals. Stage intervals are partitioned so one instant contributes to at
  most one stage total.
- `awake_minutes` and `in_bed_minutes` are independently unioned and therefore
  are not added to `asleep_minutes`.
- If the selected source has no in-bed or staged value, the corresponding field
  is null rather than borrowed from a second source.
- `wake_date` is derived from `end_at` in `data.time_zone`, as confirmed for the
  product.
- `nights` contains at most one record per wake date and at most seven records,
  sorted by wake date ascending.
- `start_at` is before `end_at`; both are UTC ISO 8601 instants. All duration
  fields are non-negative whole minutes or null.
- A primary episode may span at most 24 hours, and no individual duration field
  may exceed 1,440 minutes.

The single-source rule is intentionally conservative. It may omit a secondary
app's overlapping contribution, but it prevents an apparently precise total
that double counts the same sleep. It should be reviewed with the upstream
maintainer before implementation.

### Workout normalization and rules

- Include workouts whose `start_at`, converted into `data.time_zone`, falls in
  the inclusive seven-date window.
- Sort workouts by `start_at` ascending.
- The snapshot carries at most 100 workouts. If more exist, keep the 100 most
  recent, return them in ascending order, and set `items_truncated` to true.
- `id` is a 24-character lowercase hexadecimal publication ID generated from a
  per-instance random salt and the HealthKit workout UUID. The UUID and salt
  never leave the phone, and the same workout cannot be correlated across two
  Tesserae instances.
- `activity_type` is a canonical lowercase snake-case slug for
  `HKWorkoutActivityType`. The contract publishes the supported slug enum;
  future unrecognized HealthKit values map to `other` until the contract is
  extended. Localized display names are rendered by the widget, not uploaded.
- Start and end are preserved as UTC ISO 8601 instants. `duration_seconds` is
  HealthKit's active workout duration and can be shorter than wall-clock
  `end_at - start_at` because pauses are excluded.
- Each optional metric is derived only from its explicitly requested HealthKit
  quantity type. Distances remain separate by modality; the client never adds
  incomparable or partially authorized distance types into a misleading total.
- `segments` contains only meaningful multi-activity or interval details. A
  workout with one implicit activity uses an empty array.
- A segment contains an ordinal, activity type, start/end, duration, and the
  same nullable metric fields as the parent workout. It never contains a
  HealthKit activity UUID or metadata.
- A workout may carry at most 64 segments, and the full snapshot at most 256.
  If either limit would be exceeded, omit all segments for that workout and set
  `segments_truncated` to true; do not send a misleading partial interval list.
- Workout events, routes, metadata, raw samples, and all unlisted statistics
  are excluded even if HealthKit makes them available through the workout.
- Workout and segment wall-clock intervals may span at most seven days.
  `duration_seconds` is bounded by the wall-clock interval. Energy is bounded at
  100,000 kcal, each distance modality at 10,000,000 metres, and flights/strokes
  at 10,000,000. These deliberately generous maxima reject corrupt payloads
  without classifying ordinary athletic performance.

A segment uses this exact shape:

```json
{
  "ordinal": 0,
  "activity_type": "swimming",
  "start_at": "2026-08-14T02:00:00Z",
  "end_at": "2026-08-14T02:30:00Z",
  "duration_seconds": 1800,
  "active_energy_kcal": 214.3,
  "walking_running_distance_meters": null,
  "cycling_distance_meters": null,
  "swimming_distance_meters": 1200.0,
  "wheelchair_distance_meters": null,
  "flights_climbed": null,
  "swimming_stroke_count": 742
}
```

Ordinals are unique, zero-based, contiguous, and match chronological segment
order. Workout IDs are unique within the snapshot.

The first contract recognizes the following `activity_type` slugs. Deprecated
HealthKit enum cases remain mapped so older workouts are still representable:

```text
american_football
archery
australian_football
badminton
barre
baseball
basketball
bowling
boxing
cardio_dance
climbing
cooldown
core_training
cricket
cross_country_skiing
cross_training
curling
cycling
dance
dance_inspired_training
disc_sports
downhill_skiing
elliptical
equestrian_sports
fencing
fishing
fitness_gaming
flexibility
functional_strength_training
golf
gymnastics
hand_cycling
handball
high_intensity_interval_training
hiking
hockey
hunting
jump_rope
kickboxing
lacrosse
martial_arts
mind_and_body
mixed_cardio
mixed_metabolic_cardio_training
other
paddle_sports
pickleball
pilates
play
preparation_and_recovery
racquetball
rowing
rugby
running
sailing
skating_sports
snow_sports
snowboarding
soccer
social_dance
softball
squash
stair_climbing
stairs
step_training
surfing_sports
swim_bike_run
swimming
table_tennis
tai_chi
tennis
track_and_field
traditional_strength_training
transition
underwater_diving
volleyball
walking
water_fitness
water_polo
water_sports
wheelchair_run_pace
wheelchair_walk_pace
wrestling
yoga
```

## Client synchronization behavior

- Enabling the first section performs a full seven-day rebuild and force PUT.
- `Sync Now` always rebuilds and uploads the selected sections.
- Foreground activation performs a debounced rebuild when the source is
  enabled. The first successful activation sync on each instance-local date is
  mandatory even when the prior digest is unchanged.
- HealthKit observer notifications are best-effort triggers. They provide no
  changed values, so Companion rebuilds the bounded seven-day snapshot using
  ordinary HealthKit queries.
- Background delivery, when added, is registered only for selected HealthKit
  types. It is not described as real-time and must be validated on a physical
  device; Simulator background delivery is not evidence.
- When protected HealthKit data is unavailable while the device is locked, the
  client completes the observer callback, records a pending refresh, and retries
  after the app next becomes active. It does not replace the server snapshot
  with an empty one after a read failure.
- A SHA-256 digest is computed over normalized `data`, not the envelope. An
  unchanged digest plus a fresh server status may skip an automatic PUT, except
  for the mandatory first successful sync of a new instance-local date.
- Changing the Companion section selection forces an atomic replacement. A
  disabled section becomes null in the next snapshot.
- Disabling the last section issues DELETE and clears the locally stored health
  digest after server success. The per-instance publication salt remains until
  that Tesserae instance is disconnected or its local data is explicitly
  cleared, preserving stable workout IDs if sync is re-enabled.

## Server change and refresh semantics

- PUT validation and storage remain synchronous. A successful write returns
  200 independently of any render or device delivery result.
- Semantic comparison ignores `generated_at`, `expires_at`, ordering, and
  numeric representation after canonical normalization.
- Any Activity, Sleep, or Workout value change emits one source-wide
  `personal_data.health.summary` event. The first snapshot and DELETE also emit
  a source-wide event.
- A TTL-only identical republish renews freshness without emitting an event.
- Opted-in placements feed the existing page-refresh machinery. They do not
  choose an active Dashboard or create a second scheduler.
- The existing 10-second quiet debounce coalesces a burst of Health updates.
- A server scheduled refresh in the instance time zone remains necessary for
  date-bound widgets even when HealthKit content did not change.

Section-level selectors can be added later if real usage shows that a sleep
change needlessly refreshes many activity-only placements. Source-wide events
keep the first contract and first widget simpler.

## Privacy, retention, and disclosure

Raw HealthKit values flow only as follows:

```text
Apple Health / HealthKit
  -> on-device selection and aggregation
  -> paired, user-selected Tesserae Server
  -> explicitly configured health widget
  -> selected display
```

- The app developer operates no relay, analytics endpoint, advertising SDK, or
  health-data backend.
- Health summaries use the existing paired Companion connection and are sent
  directly to the user-selected Tesserae Server. This integration introduces
  no separate transport path. The server operator remains responsible for
  protecting the server, network connection, and access controls.
- The server stores only the latest expiring snapshot per paired publisher.
- Raw health snapshot values are excluded from ordinary logs, error responses,
  diagnostics, and backups.
- DELETE removes the latest raw snapshot immediately.
- Rendered output follows current Tesserae behavior: while a render remains in
  the live cache, History may show a thumbnail containing the health values that
  were displayed. Disabling sync or deleting the raw snapshot does not
  retroactively alter that thumbnail.
- E-ink is persistent. Deleting the snapshot also does not erase health values
  already visible on a physical display; another Dashboard must be rendered to
  replace them.
- The Health integration, requested types, user benefit, self-hosted transfer,
  retention, and thumbnail/display caveats must be clear in the authorization
  preflight, Apple Health settings page, privacy policy, App Store privacy
  answers, and App Review notes.
- Health data is never used for advertising, marketing, user profiling, data
  mining, or sale.

Proposed pre-authorization disclosure:

> Choose which Apple Health summaries Tesserae may read and send to your paired
> Tesserae Server. Activity includes daily steps, distance, Move, Exercise, and
> Stand values and goals. Sleep includes the primary sleep period and stage
> totals for each of the last seven wake dates. Workouts include type, start and
> end times, duration, energy, supported distances, flights, strokes, and
> multi-activity segments. Tesserae never sends routes, location, heart-rate
> samples, device/source details, HealthKit identifiers, or free-form metadata.
> Apple will ask you to confirm each Health data type next.

Proposed persistent server/cache disclosure:

> Your selected seven-day summaries are sent directly to this Tesserae Server,
> which keeps only the latest expiring snapshot. Health values rendered on a
> Dashboard may remain temporarily visible in Tesserae History thumbnails and
> on an e-ink display. Stopping sync deletes the raw server snapshot but does
> not retroactively clear those rendered images.

## Contract and implementation sequence

After upstream agreement:

1. Contract-only Companion PR: OpenAPI, synthetic fixtures, Swift models,
   transport mocks/tests, compatibility and privacy text. No HealthKit access.
2. Tesserae Server: capability, strict validation, latest-only storage, status,
   DELETE, semantic event, redaction, and tests.
3. Companion iOS: entitlement, purpose text, preflight selection, authorization,
   seven-day normalization, sync controls, foreground behavior, and tests.
4. Apple Health community widget: Summary, Activity, Sleep, and Workouts modes;
   fresh/stale/expired/missing states; scheduled and change-triggered refresh.
5. Best-effort HealthKit observer/background delivery and physical-device
   validation.

## Draft upstream follow-up

The text below is the canonical copy of the published follow-up comment.

### Follow-up proposal: opt-in Apple Health seven-day summary source

Building on the accepted personal-data bridge in Discussion #176 and the now working Apple Reminders source, I would like to request the separate HealthKit decision we deliberately deferred.

The proposed boundary remains the same:

```text
HealthKit
  → explicit on-device selection and aggregation
  → minimal, expiring seven-day snapshot
  → user's paired Tesserae Server
  → opt-in Apple Health widget
  → selected display
```

#### Contract shape

- Source: `health.summary`
- Capability advertisement: `personal_data.sources`
- Authorization scope: `personal_data:write`
- Envelope: `personal_data_bridge_v1`
- Endpoint family: `/api/app/v1/personal-data/{source_id}`

The existing latest-only atomic replacement, expiry, publisher isolation, status, ordering, and DELETE semantics remain unchanged.

#### Consent

The user separately enables Activity, Sleep, and Workouts in Companion. Before Apple's authorization sheet, Companion lists every HealthKit type requested and every value that may be uploaded.

Apple's sheet remains the final per-type read authorization. Companion requests no Health write access.

#### Seven-day content

The strict snapshot covers the active instance's latest seven calendar dates:

- Activity: daily steps, walking/running distance, Move/Exercise/Stand values, and their goals.
- Sleep: one primary night per wake date, including start/end, in-bed, asleep, awake, Core, Deep, REM, and unspecified-stage totals. Companion deduplicates overlapping samples locally and uploads no raw samples or source identity.
- Workouts: opaque per-instance ID, normalized activity type, start/end, active duration, active energy, explicitly authorized distance modalities, flights, swimming strokes, and bounded multi-activity segment summaries.

#### Explicit exclusions

The first version never uploads:

- routes or GPS coordinates;
- heart rate or heart-rate samples;
- raw HealthKit samples or UUIDs;
- device or source identities;
- workout events; or
- free-form metadata.

Missing or unreadable values are null, never false zeroes. Apple does not reveal individual read denials to the app.

#### Storage and refresh

- Ingestion: PUT stores the snapshot and returns 200 before any fire-and-forget refresh.
- Change source: `personal_data.health.summary`
- TTL-only renewal: no data-change event.
- Semantic health-data change: one source-wide event into the existing opted-in page-refresh machinery.
- Date boundaries: handled by scheduled refresh.

#### Privacy boundary

Raw values remain latest-only, expiring, deleted on disable, and excluded from logs, diagnostics, and backups.

An ordinary live History thumbnail may contain health values already rendered, and an e-ink panel retains its prior image until replaced. Companion discloses both facts before enablement and on the persistent Health settings page.

Health summaries use the existing paired Companion connection and are sent directly to the user-selected Tesserae Server. This proposal adds no developer-operated relay and no separate transport path. The server operator remains responsible for protecting the server, network connection, and access controls.

#### Questions

1. Is the direct source advertisement above sufficient for the separate Health capability decision?
2. Is one atomic source containing optional Activity, Sleep, and Workouts sections preferable to three independently expiring sources?
3. Are the bounded seven-day fields and explicit exclusions appropriate for the first contract?
4. Is source-wide refresh acceptable initially, with section selectors deferred?

If the direction fits, I will follow the established workflow: a contract-only Draft PR with OpenAPI, synthetic fixtures, Swift models, privacy text, and tests before any server, HealthKit, or widget implementation.

## Reference material

- Apple: Authorizing access to health data
  <https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data>
- Apple: Protecting user privacy
  <https://developer.apple.com/documentation/healthkit/protecting-user-privacy>
- Apple: Executing statistics collection queries
  <https://developer.apple.com/documentation/healthkit/executing-statistics-collection-queries>
- Apple: Executing observer queries
  <https://developer.apple.com/documentation/healthkit/executing-observer-queries>
- Apple: Sleep analysis values
  <https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis>
- Apple: `HKWorkout`
  <https://developer.apple.com/documentation/healthkit/hkworkout>
- Apple: Dividing a workout into activities
  <https://developer.apple.com/documentation/healthkit/dividing-a-healthkit-workout-into-activities>
- Apple: App Review Guidelines 5.1.3
  <https://developer.apple.com/app-store/review/guidelines/#health-and-health-research>
- Tesserae Discussion #176
  <https://github.com/dmellok/tesserae/discussions/176>
