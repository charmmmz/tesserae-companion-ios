# Connection and Cloud submission ownership

`ConnectionRuntime` owns saved connection identities, the selected connection,
credential envelopes and session epoch fences. `ConnectionHost` owns the visible
connection lifecycle. `AppModel` retains the local Companion workflows; Cloud
reads use `CloudBrowseModel`, and Cloud writes use `CloudSubmissionService`.
Share Extension and Intents remain on the local entry factory in this stage.

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
