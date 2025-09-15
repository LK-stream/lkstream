LKSTREAM — IMPLEMENTATION + ARCHITECTURE (end-to-end)

Purpose: provide a single, practical, unambiguous guide to implement LKSTREAM (the lightweight Kafka-like stream) end-to-end. This document describes exact designs, file formats, API, dev & prod setup, test plan, metrics, deployment recipes and migration path.

This is the canonical implementation blueprint. Build this first in Python for validation; once validated, reimplement the hot IO core in Go (same protocol + storage format).

Table of contents

Goals & constraints

System overview & runtime modes

Canonical wire protocol (Protobuf + gRPC)

Storage: segment & index format (binary spec)

Core components & responsibilities

Python reference implementation layout (files + major classes)

APIs: producer, consumer, admin, offsets (examples)

Persistence & durability policy (group-commit fsync design)

Observability & metrics (Prometheus + alerts)

Testing & acceptance criteria (benchmarks, crash tests)

Dev-to-prod working setup (local → docker → k8s)

Runbooks & ops checklist

Migration & scaling path (bridge to Kafka, Go core, cluster)

Roadmap & prioritized next steps

Appendices: sample proto, sample Dockerfile, example systemd unit, sample config

1. Goals & constraints

Primary goal: deliver a pragmatic, embeddable, file-backed event log with Kafka-like semantics for single-host deployments and local services:

Topics, partitions, offsets

Per-partition ordering

Append-only segment files with index

Durable commits via configurable fsync (group by default)

Consumer offsets persisted (file or lightweight K/V)

Batching APIs for throughput

Hot in-memory tail for low-latency reads

Simple integration: embedded library or gRPC daemon

Easy migration to Kafka/Redpanda later

Constraints:

Single-node initially (no replication).

Language-agnostic wire protocol (Protobuf/gRPC).

Default reference impl in Python; production core in Go later.

Target practical throughput: Python: 10k–50k msg/s; Go: 100k–500k msg/s.

2. System overview & runtime modes
Runtime modes

Embedded — library loaded in same process (fastest path, zero RPC).

Daemon (single node) — runs as a local service, accessible by gRPC (recommended for multi-process apps on same host).

Cluster (future) — leader/follower replication (Raft), multi-host durability.

High-level overview
Producers ---> LKSTREAM Broker (segments/index + hot tail) ---> Consumers
                             |
                         Kafka Bridge (optional)
                             |
                       Central Kafka/Archive (S3)

3. Canonical wire protocol (Protobuf + gRPC)

Why: cross-language, streaming support, auto-generated stubs.

Place proto/messaging.proto in repo (example in Appendix). Core RPCs:

Produce(ProduceRequest) -> ProduceResponse (batched)

Fetch(FetchRequest) -> FetchResponse (point fetch)

Subscribe(FetchRequest) -> stream Record (server streaming)

CommitOffset(CommitRequest) -> CommitResponse

Admin(AdminRequest) -> AdminResponse (topics, stats)

Heartbeat(HeartbeatRequest) -> HeartbeatResponse (consumer groups)

Design notes:

Producers send messages in batches (list of bytes). Broker returns list of per-message offsets.

Consumers use Subscribe streaming to hold a long-lived connection for low-latency push.

Implement protocol version check in handshake.

4. Storage: segment & index format (binary spec)

Directory layout (topic-partition):

{persist_dir}/topics/{topic}/part{pid}/
    ├── {base_offset}.seg    (binary segment)
    ├── {base_offset}.idx    (binary index)
    └── checkpoint.meta      (last closed segment base, last offset)
offsets/
    └── {group}__{topic}__part{pid}.offset


Segment file (.seg) format

Sequence of framed records.

Each record = [4B length][payload bytes] (big-endian 32-bit length).

Payload = opaque user bytes (broker does not parse).

Index file (.idx) format

Binary entries appended: [8B offset][8B pos] (both uint64 big-endian).

offset is message logical offset; pos is byte position within .seg file where that record frame starts (position of the 4B length header).

Index allows locating the record quickly.

Rotation

Create new segment when current segment file size + next write > segment_max_bytes (default 64MB).

Use base_offset equal to first message offset in that segment.

Keep segments ordered by base_offset.

On startup, scan segment files sorted by base_offset and rebuild in-memory mapping by loading .idx or scanning .seg if index missing.

5. Core components & responsibilities
Broker

Manage topics and partitions.

Route produces to partition (partitioner: key-hash or round-robin).

Keep per-partition locks and hot-tail buffer.

Partition

Append records to current segment; rotate when needed.

Maintain in-memory index cache for recent offsets.

Provide read_from(offset, max_msgs) method.

StorageEngine

Filesystem-backed default implementation (Segment + Index).

Optional plugin adapters (e.g., mmap-reader optimization).

Producer client

Exposes produce_many(topic, [(key, bytes), ...]) (async).

Applies backpressure if broker inflight bytes > config.

Consumer client

Subscribe to topic with group id.

Read via streaming RPC or consume() call.

Commit offsets periodically (auto-commit) or manually.

OffsetStore

Persist offsets per (group,topic,partition) with atomic write (tmp + rename).

Kafka Bridge

Consumes from LKSTREAM and writes to Kafka (aiokafka).

Acts as the archive/centralization mechanism.

6. Python reference implementation layout (recommended files)
lkstream/
  __init__.py
  broker.py          # Broker class + topic management
  partition.py       # Partition class, segment management
  storage.py         # Segment and index low-level file ops
  consumer.py        # Consumer class & commit logic
  producer.py        # Producer helper, produce_many
  offset_store.py    # persistent offsets
  grpc_server.py     # gRPC wrapper endpoints (uses Broker)
  metrics.py         # Prometheus exporter
  config.py          # load config YAML/env
  utils.py
examples/
  producer_example.py
  consumer_example.py
  kafka_bridge.py
benchmarks/
  bench_producer.py
  bench_consumer.py
docs/
  diagrams/


Key classes

Broker(persist_dir, fsync_mode, fsync_interval_ms, segment_max_bytes, partitions)

Partition(topic, pid) with methods append_many(records), read_from(offset, max_msgs), wait_for_offset(offset, timeout)

OffsetStore(base_dir) with commit(group, topic, pid, offset) and read_committed(...)

Consumer that uses Partition.read_from or Subscribe via gRPC.

7. API examples (usage)
Producer (Python async)
res = await broker.produce_many("market.ticks", [("AAPL", b'{"p":123}'), ("TSLA", b'{"p":456}')])
# returns [(partition_id, offset), ...]

Consumer (Python async)
consumer = Consumer(broker, group="strategy-v1", offset_store=OffsetStore(base_dir))
consumer.subscribe("market.ticks", from_committed=True)
await consumer.consume("market.ticks", handler)  # handler(pid, offset, record)

gRPC produce (client)
# ProduceRequest with repeated bytes values
stub.Produce(ProduceRequest(topic="market.ticks", key=b"AAPL", values=[b'...', b'...']))

8. Persistence & durability policy
Fsync strategy (group commit) — recommended default

Maintain a group commit buffer: new writes are appended to segment file (OS buffer). Periodically (every fsync_interval_ms or when buffered bytes >= threshold) call fsync() on affected segment file(s) and flush index entries.

Parameterize:

fsync_mode = { "sync", "group", "none" } (default: group)

fsync_interval_ms = 100

fsync_group_bytes = 128*1024 (128 KB)

Tradeoff:

Lower interval / group bytes → stronger durability but lower throughput.

Higher interval → greater throughput but window of data at risk.

Index durability

Write index entry after segment append. Flush index file on rotation or periodically with group commit.

If index missing during restart, rebuild by scanning segment bytes (slower but safe).

Offset commit

Write offset file atomically:

Write to tmp file, fsync() file, os.replace(tmp, final).

Offset commit is authoritative for consumers; on restart, consumer starts from committed offset.

9. Observability & metrics

Expose HTTP /metrics and /healthz endpoints.

Essential Prometheus metrics

lk_produced_total{topic,partition} (counter)

lk_consumed_total{topic,group,partition} (counter)

lk_partition_next_offset{topic,partition} (gauge)

lk_partition_committed_offset{topic,group,partition} (gauge)

lk_consumer_lag_seconds{...} (gauge derived)

lk_segment_size_bytes{topic,partition} (gauge)

lk_inflight_bytes (gauge)

lk_fsync_latency_seconds (histogram)

Alerts

Consumer lag > 60s (configurable)

Disk space < 20% free

fsync latency p99 > 1s

10. Testing & acceptance criteria
Unit & integration tests

Append/read correctness, rotation correctness, index integrity.

Offset commit & resume behavior.

Crash & recovery tests

Produce 1M messages, kill process mid-run, restart, verify:

No corrupted segment (detect partial frames).

Messages up to last fsync are present.

Offsets restore to committed positions.

Performance benchmarks (example plan)

On VM: 4 vCPU, 8GB, NVMe.

Message sizes: 200B, 1KB tests.

Goal (Python): sustain 10k–50k msg/s with p50 < 10ms, p99 < 50ms using batch size 100 and fsync=100ms.

Goal (Go core): sustain 100k–500k msg/s with p50 < 1ms, p99 < 10ms.

Acceptance criteria to call it "prod-ready single-node"

24-hour soak test at expected target throughput (no memory growth).

Crash/recovery test passes 3 times.

Prometheus metrics and alerts working.

Basic health & admin APIs functional.

Backpressure enforced (producer rejected when inflight bytes exceed limit).

11. Working setup: local → docker → Kubernetes
Local dev

Create a Python venv.

pip install -r requirements.txt (aiokafka, grpcio, prometheus_client, pytest)

Start broker in embedded mode: python -m lkstream.grpc_server --config conf/local.yml

Run examples/producer_example.py and examples/consumer_example.py

Dockerfile (example)
FROM python:3.11-slim
WORKDIR /app
COPY . /app
RUN pip install -r requirements.txt
EXPOSE 8080 9090
CMD ["python", "-m", "lkstream.grpc_server", "--config", "/etc/lkstream/config.yml"]


Build & run:

docker build -t lkstream:dev .
docker run -v /data/lkstream:/data -p 8080:8080 -p 9090:9090 lkstream:dev

Kubernetes (single-node / small cluster)

Use a Deployment with replicas: 1 and a PersistentVolumeClaim for /data.

livenessProbe -> /healthz, readinessProbe -> /ready.

Prometheus scrape config for /metrics.

Provide ConfigMap for config.yaml.

Example deployment.yaml snippet:

apiVersion: apps/v1
kind: Deployment
metadata: { name: lkstream }
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: lkstream
        image: lkstream:latest
        ports: [{containerPort:8080},{containerPort:9090}]
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: lkstream-pvc

12. Runbooks & ops checklist

Startup

Verify disk mounted and owned by process user.

Ensure config has correct persist_dir, fsync_mode, segment_max_bytes.

Backup

Daily snapshot of topics/*/*.seg to S3 (older segments preferred).

Backup offsets dir nightly.

Restore

Restore segment files and index (or rebuild). Place offsets into offsets/ and start broker.

Scaling

If consumer lag grows persistently > 1 minute or throughput > 100k msg/s consider:

Move hot-path to Go core and/or

Add Kafka bridge and centralize heavy consumers.

13. Migration & scaling path

Embedded Python (validate) → 2. Daemon Python + Kafka bridge (local archive) → 3. Go core daemon (single-node production) → 4. Clustered mode (Raft) or full Kafka migration.

Bridge to Kafka (when durability/scale needed):

Kafka bridge consumes topics from LKSTREAM and produces to Kafka.

For safe migration, run both systems in parallel; gradually move consumers to read from Kafka.

14. Roadmap & prioritized next steps (practical)

Phase 0 (this week) — Harden Python ref:

group-commit fsync

offset auto-commit thread

Prometheus metrics

Dockerfile + examples + benchmark scripts

Phase 1 (2–6 weeks) — Validation:

Run benchmarks; iterate.

Run pilot in your trading app.

Phase 2 (1–3 months) — Production core (Go):

Implement Go core with same segment/index format and gRPC API.

Provide Python client to talk to Go server.

Phase 3 (later) — Cluster & enterprise:

Add Raft replication or hybrid approach

Management UI, security, multi-tenant features

15. Appendices
Appendix A — sample proto/messaging.proto (abbreviated)
syntax = "proto3";
package lkstream;

message ProduceRequest {
  string topic = 1;
  bytes key = 2;
  repeated bytes values = 3;
}

message ProduceResponse {
  uint32 partition = 1;
  repeated uint64 offsets = 2;
}

message FetchRequest {
  string topic = 1;
  uint32 partition = 2;
  uint64 offset = 3;
  uint32 max_bytes = 4;
}

message Record {
  uint64 offset = 1;
  bytes key = 2;
  bytes value = 3;
  uint64 ts = 4;
}

service Broker {
  rpc Produce(ProduceRequest) returns (ProduceResponse);
  rpc Fetch(FetchRequest) returns (FetchResponse);
  rpc Subscribe(FetchRequest) returns (stream Record);
  rpc CommitOffset(CommitRequest) returns (CommitResponse);
  rpc Admin(AdminRequest) returns (AdminResponse);
}

Appendix B — sample systemd unit
[Unit]
Description=LKSTREAM Broker
After=network.target

[Service]
User=lkstream
Group=lkstream
ExecStart=/usr/bin/python -m lkstream.grpc_server --config /etc/lkstream/config.yml
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target

Appendix C — sample acceptance tests list

Durability test: produce 1M msgs, kill process 3x at random times, restart, verify up to committed offset consistent.

Replay test: produce 1 hour of ticks and replay from 0; verify order/value for a sample selection.

Load test: sustained run at desired throughput for 24 hours.

Final honest notes

This is a practical, incremental plan. Start with Python to validate the API and product fit. Only invest in Go/Rust if you hit real performance/scale limits or paying customers require it.

Single-node vs cluster: LKSTREAM is intentionally single-node initially. That is its value proposition: minimal ops and simpler life for many use-cases. Don’t over-engineer clustering until you have real need.

Measure early, often. The single most important confirmation is running realistic load and crash tests on target hardware.
