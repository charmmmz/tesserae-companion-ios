# Connection and Cloud submission ownership

`ConnectionRuntime` owns saved connection identities, the selected connection,
credential envelopes and session epoch fences. `ConnectionHost` owns the visible
connection lifecycle. `AppModel` retains the local Companion workflows; Cloud
reads use `CloudBrowseModel`, and Cloud writes use `CloudSubmissionService`.
Share Extension and Intents use the same runtime. Local submissions retain the
existing idempotent queue; fixed Cloud operations enter `CloudSystemEntry`.

A view submits only through Host with its captured opaque Cloud presentation
context. Network/auth preparation happens outside the existing Host lifecycle
gate. Host then verifies that context and performs the short durable start.
Every connection switch, Demo selection, logout or grant replacement seals the
old service before activation. A local connection prepares outside the gate,
commits its selected identity inside it, and finishes initial reads/queues under
the committed revision outside it. Late old reads cannot replace a newer
connection's queue, fence or presentation.

`CloudSubmissionStore` uses one atomic ledger per full Cloud identity. A short
metadata file lock protects acceptance, claims, source revision reservations and
closed receipts. A separate per-batch owner descriptor is acquired before
publication and held by the executing process. Network calls hold neither lock.
Observers never wait for the owner or take over sending: an abandoned claim
becomes unknown, and unclaimed tasks become not attempted. Stop and claim use
the same ledger lock, so a winning claim remains an original-target in-flight
attempt; stopping does not claim remote cancellation.

Read-access restriction hides saved private media/results and seals execution.
A later verified read recovery can create a new service for new decisions but
never resumes old work. A send-scope refusal alone does not invalidate read
access. Old history cannot adjudicate current authorization; a newly completed
execution may request one safe GET recheck. UI callbacks still require the
captured presentation context after every await.

See [Cloud submission semantics](../Contracts/cloud-app-submission.md) for
response uncertainty, explicit resend and fixed retention. The local idempotent
queue and its retry rules are unchanged.

## System inputs and explicit recovery

`CloudSystemEntry` owns durable intake, current authorization, bounded platform
raster preparation and the existing once-only submission service. Share passes
its committed still and per-aspect recipe. Shortcuts resolves every original
entity identifier to its saved connection and resource kind before admitting an
operation; changing the selected connection cannot redirect a saved action.
Legacy raw IDs resolve only through the unique recorded local binding. Query
results preserve the requested original identifier within that resolved group.

An explicit system operation persists one input before online preparation. The
same ledger record becomes an accepted batch or a minimal closed receipt.
Repeating the initial call observes the record; it cannot resume a retained
input. Only an explicit App Continue may reacquire unsubmitted input. A dead
owner can make an accepted claim unknown, but observers never acquire dispatch
authority. Each host stops only its own execution, and completion waits for a
durable outcome rather than relying on work after extension dismissal.

Private pending content requires a fresh same-identity read context. Continue
rechecks permissions and write scope. Review reuses the existing composer;
closing the old input and publishing its replacement is one fenced ledger CAS,
with the original absolute expiry. Unavailable original targets stay selected
and block the whole send until explicitly removed. Pending detail and Review
hide their media and actions at expiry, including late decoding. Presentation
IDs prevent an old completion from dismissing a newer pending item. Accepted
results return to the existing result view and keep their separate result clock.

System actions have a 30-second client execution budget, including auth and IO,
plus bounded completion-only cleanup that cannot dispatch. This grants no iOS
background lifetime. The system raster profile checks source metadata before
decode and bounds source/canvas work. Once intake has persisted an input,
raster budget or preparation refusals leave it pending rather than changing
crop, geometry or quality silently. Unsupported links, Intent options and invalid
targets rejected before admission do not create pending work. Explicit App review
uses the existing main-App preparation profile.

A shared token renewal can outlive the host process that started it. If iOS
suspends that owner beyond the persisted pending deadline, another authorized
consumer closes the ambiguous rotation; foregrounding the original host does not
replay it. A client timeout cannot promise extension execution time. System-host
verification must distinguish actual authorization joins from URL dispatch,
background accessibility queries and later sequential requests.
