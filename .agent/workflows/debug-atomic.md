---
description: Run a systematic, atomic debugging process for integration tests
---

# Atomic Debugging Protocol

Use this workflow when facing complex integration test failures (Timeouts, hangs, "Channel not found"). Do not guess at fixes. Verify each layer sequentially.

## 1. Environment Verification

**Goal**: Ensure the infrastructure is healthy.

- Run `setup_test_env.ps1`.
- Check Docker usage: `docker stats --no-stream`.
- Check Ports: `Test-NetConnection -ComputerName 127.0.0.1 -Port 5672`.

## 2. Operations Verification

**Goal**: Isolate the point of failure.

### Step 2.1: Topology (Setup)

- **Check**: Are Exchanges/Queues created?
- **Action**: Enable `TopologyProvider` logs. Look for `DeclareExchangeAsync`, `DeclareQueueAsync`.
- **Validation**:
  - [ ] Exchange Exists
  - [ ] Queue Exists (check Name: generated vs explicit)

### Step 2.2: Binding (Wiring)

- **Check**: Is the Queue bound to the Exchange?
- **Action**: Enable `QueueBindMiddleware` logs.
- **Validation**:
  - [ ] `BindQueueAsync` called with correct (Exchange, Queue, RoutingKey).
  - [ ] No "Skipping binding" logs.

### Step 2.3: Publication (Send)

- **Check**: Did the message leave the client?
- **Action**: Enable `BasicPublishMiddleware` logs.
- **Validation**:
  - [ ] `BasicPublishAsync` called.
  - [ ] `ReplyTo` header is set correctly (String vs URI).
  - [ ] `CorrelationId` is present.

### Step 2.4: Consumption (Receive)

- **Check**: Did the consumer pick it up?
- **Action**: Enable `BaiscConsumeMiddleware` / `ConsumerFactory`.
- **Validation**:
  - [ ] `BasicConsumeAsync` called for the correct Queue.
  - [ ] Message handler invoked.

## 3. Atomic Fix Rule

- **Rule**: Fix ONE layer at a time.
- **Anti-Pattern**: Changing `ReplyTo` AND `QueueBind` logic simultaneously.
- **Protocol**:
    1. Verify Layer N.
    2. If Layer N fails, Fix Layer N.
    3. Verify Layer N passed.
    4. Move to Layer N+1.
