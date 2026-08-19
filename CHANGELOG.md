# Changelog

## 0.2.0 - Robustness

Hardening release. The headline fix is that a reconnecting Envoy could crash its
own ADS stream, but the same audit turned up a number of ways a single
misbehaving node, adapter, or snapshot could take down more than itself.

### Fixed

- **A reconnecting node could tear down its ADS stream, repeatedly.**
  `ExControlPlane.Stream` classified discovery requests by doing arithmetic on
  the `version_info` the node reports. That value is opaque to the node and
  survives reconnects, so after a control plane redeploy a node replays a
  version the new instance never issued, while its per-stream counter restarts
  at 0. The `case` had no clause for that and raised `CaseClauseError`, which
  exited the caller - the GRPC stream handler - dropping the session and
  starting the cycle again. Requests are now classified by `response_nonce`, as
  the xDS protocol defines: empty nonce means initial request (new *or*
  reconnected), our latest nonce means ACK/NACK, anything else is a superseded
  response. `version_info` is never parsed.
- **Redundant config push to every reconnected node.** `push_resources/1` did
  not record the hash of what it sent, so the first resource change after a
  reconnect pushed a new version for byte-identical resources.
- **`load_events/4` reported `:ok` when config generation failed.** An adapter
  that raised was caught and logged, but the result was discarded and the call
  still reported success and wrote a snapshot. It now returns
  `{:error, :failed_generating_configuration}`, or
  `{:error, :invalid_cluster_config}` when the adapter returns a non-`ClusterConfig`.
- **One slow or broken node could stall config distribution for everyone.**
  Pushes ran serially inside the `ConfigCache` GenServer with a 5s call timeout,
  and the write to the GRPC stream happened on that critical path. A dead pid or
  a node stuck on HTTP/2 flow control crashed or blocked `ConfigCache`. Pushes
  are now concurrent and fault-isolated, and each stream marks itself out of
  sync, replies, and writes to its GRPC stream afterwards.
- **`load_events/4` blocked the `ConfigCache` GenServer** for the whole
  synchronicity wait, so unrelated clusters queued behind a lagging dataplane.
  The wait now runs outside the GenServer; a waiter that dies still replies.
- **A malformed resource killed the stream.** The `DiscoveryResponse` encode was
  an unguarded match. Encoding and send failures are now logged, leave version
  and hash unadvanced so the next notification retries, and keep the stream out
  of sync.
- **A bad snapshot could prevent start-up permanently.** A payload without
  version or checksum information raised inside `handle_continue`, and the
  restart re-read the same object. Snapshot validation is total and loading is
  best-effort.
- **`Snapshot` with snapshots disabled.** `init/1` stored `:no_snapshot_config`
  while the disabled-state clause matched `:snapshots_disabled`, so that clause
  was dead - and it returned `{:ok, reply, state}`, which is not a valid
  GenServer reply. `force_persist/0` raised `FunctionClauseError`.
- **Non-exhaustive error handling** in `ensure_registred/3` (`WithClauseError`
  on any unexpected `start_child` result) and `event/4` (`MatchError`).

### Changed

- `ExControlPlane.Stream.event/4` takes a map
  (`%{version_info:, nonce:, error:}`) instead of a `{version, error}` tuple, and
  never raises - it returns `{:error, reason}` so a failure cannot take the
  node's ADS session with it.
- Stream children are `:temporary` instead of `:transient`. A restarted stream
  only re-registers against a connection the node has to re-establish anyway,
  while spending the supervisor's restart budget.
- The node identifier is remembered per GRPC stream. xDS only requires `node` on
  the first request of a stream; previously a request without it raised
  `FunctionClauseError`. (Envoy sends it on every request, this matters for
  other spec-conformant xDS clients.)
- `wait_until_in_sync` no longer treats "no node connected" as evidence the
  config is good. `load_events/4` still returns `:ok` in that case for
  compatibility, but logs a warning.

### Added

- `ExControlPlane.Stream.sync_status/1` returning `:in_sync`, `:out_of_sync`, or
  `:no_connected_nodes`. `in_sync/1` cannot distinguish the last two - it
  reports `true` when nothing is connected.
- `ExControlPlane.ConfigCache.checksum/1` is public, so a stream can record what
  it was actually sent using the same function the notification path uses.
- Config options: `:stream_push_timeout` (default 10s) bounds a push to a single
  stream; `:max_concurrent_streams` (default `:infinity`) bounds how many
  discovery streams are accepted.

### Known limitations

- Detecting that a node is gone is a transport concern and takes tens of seconds
  (~50s observed against Envoy 1.34.2). A node that dies mid-push leaves an
  out-of-sync stream for that long, during which `load_events/4` for its cluster
  returns `{:error, :no_sync_state_reached}`.
