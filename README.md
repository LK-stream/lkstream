# 🪁 LKSTREAM

**LKSTREAM** (Lightweight Kafka Stream) is a **lightweight, Kafka-like event streaming library and service**.  
It provides **topics, partitions, offsets, and persistence** — without the heavy ops of running a full Kafka cluster.  

LKSTREAM is designed for **trading systems, IoT gateways, and real-time apps** where you need **replayable event logs** but want **simplicity and low latency**.

---

## 📑 Table of Contents
- [Features](#-features)
- [Why LKSTREAM](#-why-lkstream)
- [Installation](#-installation)
- [Quick Start](#-quick-start)
- [Architecture](#-architecture)
- [Use Cases](#-use-cases)
- [Benchmarks](#-benchmarks)
- [Roadmap](#-roadmap)
- [FAQ](#-faq)
- [Contributing](#-contributing)
- [License](#-license)

---

## ✨ Features

- **Kafka-like semantics**  
  Topics, partitions, offsets, consumer groups.  

- **Lightweight**  
  Runs as an embedded Python library or single binary — no ZooKeeper, no multi-node cluster needed.  

- **Persistence**  
  Append-only **segment files** with rotation and retention policies.  

- **Replay & recovery**  
  Consumers restart from last committed offsets.  

- **Offset tracking**  
  Durable offset commits per consumer group.  

- **Low latency**  
  Async I/O and **hot in-memory tail** for recent events.  

- **Flexible use**  
  Use **in-process** (as a Python lib) or run as a **tiny standalone service**.  

- **Future-ready**  
  Optional **bridge to Kafka/Redpanda** for long-term durability and enterprise scaling.  

---

## ❓ Why LKSTREAM

Running Apache Kafka is **overkill for small/medium use cases**:
- Requires **clusters, ZooKeeper, ops team**.  
- Heavy on **infra, memory, and CPU**.  
- Steep **learning curve** for developers.  

**LKSTREAM** gives you the **same event streaming semantics** in a **single lightweight package**:
- Perfect for **solo developers, startups, edge computing**.  
- Drop it into your trading app or IoT pipeline in minutes.  
- Scale later → bridge to Kafka or Redpanda when you outgrow it.  

---

## ⚙ Installation

### From PyPI
```bash
pip install lkstream
