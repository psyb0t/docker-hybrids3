"""Unit tests for app/lock.py — run with: python -m pytest tests/test_lock_unit.py"""

import asyncio
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "app"))

from lock import (  # noqa: E402
    LockHoldTimeout,
    LockManager,
    LockOverloaded,
    LockTimeout,
    _RWLock,
)


# ── _RWLock unit tests ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_multiple_readers_concurrent():
    lock = _RWLock()
    results = []

    async def reader(i):
        await lock.acquire("r", acquire_timeout=1.0, max_waiters=10)
        results.append(f"start-{i}")
        await asyncio.sleep(0.05)
        results.append(f"end-{i}")
        await lock.release("r")

    await asyncio.gather(reader(0), reader(1), reader(2))
    starts = [r for r in results if r.startswith("start-")]
    assert len(starts) == 3


@pytest.mark.asyncio
async def test_writer_exclusive():
    lock = _RWLock()
    order = []

    async def writer(label):
        await lock.acquire("w", acquire_timeout=2.0, max_waiters=10)
        order.append(f"start-{label}")
        await asyncio.sleep(0.05)
        order.append(f"end-{label}")
        await lock.release("w")

    await asyncio.gather(writer("a"), writer("b"))
    # one writer must finish before the other starts
    idx = lambda s: order.index(s)  # noqa: E731
    assert idx("end-a") < idx("start-b") or idx("end-b") < idx("start-a")


@pytest.mark.asyncio
async def test_readers_block_writer():
    lock = _RWLock()
    events = []

    async def reader():
        await lock.acquire("r", acquire_timeout=2.0, max_waiters=10)
        events.append("reader-in")
        await asyncio.sleep(0.1)
        events.append("reader-out")
        await lock.release("r")

    async def writer():
        await asyncio.sleep(0.02)  # let reader get in first
        await lock.acquire("w", acquire_timeout=2.0, max_waiters=10)
        events.append("writer-in")
        await lock.release("w")

    await asyncio.gather(reader(), writer())
    assert events.index("reader-out") < events.index("writer-in")


@pytest.mark.asyncio
async def test_writer_blocks_readers():
    lock = _RWLock()
    events = []

    async def writer():
        await lock.acquire("w", acquire_timeout=2.0, max_waiters=10)
        events.append("writer-in")
        await asyncio.sleep(0.1)
        events.append("writer-out")
        await lock.release("w")

    async def reader():
        await asyncio.sleep(0.02)  # let writer get in first
        await lock.acquire("r", acquire_timeout=2.0, max_waiters=10)
        events.append("reader-in")
        await lock.release("r")

    await asyncio.gather(writer(), reader())
    assert events.index("writer-out") < events.index("reader-in")


@pytest.mark.asyncio
async def test_acquire_timeout_raises():
    lock = _RWLock()
    await lock.acquire("w", acquire_timeout=2.0, max_waiters=10)

    with pytest.raises(LockTimeout):
        await lock.acquire("r", acquire_timeout=0.05, max_waiters=10)

    await lock.release("w")


@pytest.mark.asyncio
async def test_overloaded_raises_immediately():
    lock = _RWLock()
    await lock.acquire("w", acquire_timeout=2.0, max_waiters=2)
    # fill the queue
    t1 = asyncio.create_task(lock.acquire("r", acquire_timeout=2.0, max_waiters=2))
    t2 = asyncio.create_task(lock.acquire("r", acquire_timeout=2.0, max_waiters=2))
    await asyncio.sleep(0)  # yield so tasks enter queue

    with pytest.raises(LockOverloaded):
        await lock.acquire("r", acquire_timeout=2.0, max_waiters=2)

    t1.cancel()
    t2.cancel()
    await asyncio.gather(t1, t2, return_exceptions=True)
    await lock.release("w")


@pytest.mark.asyncio
async def test_idle_after_all_released():
    lock = _RWLock()
    assert lock.idle

    await lock.acquire("r", acquire_timeout=1.0, max_waiters=5)
    assert not lock.idle

    await lock.release("r")
    assert lock.idle


@pytest.mark.asyncio
async def test_idle_writer_released():
    lock = _RWLock()
    await lock.acquire("w", acquire_timeout=1.0, max_waiters=5)
    assert not lock.idle
    await lock.release("w")
    assert lock.idle


# ── LockManager context manager tests ────────────────────────────────────────


@pytest.mark.asyncio
async def test_manager_read_context():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=5.0, max_waiters=10)
    async with mgr.read("bucket", "key"):
        pass  # must not raise


@pytest.mark.asyncio
async def test_manager_write_context():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=5.0, max_waiters=10)
    async with mgr.write("bucket", "key"):
        pass  # must not raise


@pytest.mark.asyncio
async def test_manager_hold_timeout_raises():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=0.05, max_waiters=10)
    with pytest.raises(LockHoldTimeout):
        async with mgr.write("bucket", "key"):
            await asyncio.sleep(0.2)


@pytest.mark.asyncio
async def test_manager_lock_released_after_hold_timeout():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=0.05, max_waiters=10)
    try:
        async with mgr.write("bucket", "key"):
            await asyncio.sleep(0.2)
    except LockHoldTimeout:
        pass

    # lock must be released — next acquire should succeed
    async with mgr.write("bucket", "key"):
        pass


@pytest.mark.asyncio
async def test_manager_acquire_timeout_raises():
    mgr = LockManager(acquire_timeout=0.05, hold_timeout=5.0, max_waiters=10)

    async def hold():
        async with mgr.write("b", "k"):
            await asyncio.sleep(0.5)

    t = asyncio.create_task(hold())
    await asyncio.sleep(0.01)  # let hold acquire

    with pytest.raises(LockTimeout):
        async with mgr.read("b", "k"):
            pass

    await t


@pytest.mark.asyncio
async def test_manager_overloaded_raises():
    mgr = LockManager(acquire_timeout=5.0, hold_timeout=5.0, max_waiters=2)

    async def hold():
        async with mgr.write("b", "k"):
            await asyncio.sleep(1.0)

    t = asyncio.create_task(hold())
    await asyncio.sleep(0.01)

    waiters = [asyncio.create_task(mgr.read("b", "k").__aenter__()) for _ in range(2)]
    await asyncio.sleep(0)

    with pytest.raises(LockOverloaded):
        async with mgr.read("b", "k"):
            pass

    t.cancel()
    for w in waiters:
        w.cancel()
    await asyncio.gather(t, *waiters, return_exceptions=True)


@pytest.mark.asyncio
async def test_manager_different_keys_independent():
    mgr = LockManager(acquire_timeout=0.1, hold_timeout=5.0, max_waiters=10)

    async def write_key(k):
        async with mgr.write("b", k):
            await asyncio.sleep(0.05)

    # concurrent writes to DIFFERENT keys must not block each other
    start = time.monotonic()
    await asyncio.gather(write_key("k1"), write_key("k2"), write_key("k3"))
    elapsed = time.monotonic() - start

    # if locks were shared they'd serialize: 3 × 0.05s = 0.15s
    # independent: all 3 run at once, ~0.05s total
    assert elapsed < 0.12, f"different keys should not block each other, took {elapsed:.3f}s"


@pytest.mark.asyncio
async def test_manager_cleans_up_idle_locks():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=5.0, max_waiters=10)

    async with mgr.write("b", "k"):
        pass

    assert ("b", "k") not in mgr._locks, "idle lock not pruned from dict"


@pytest.mark.asyncio
async def test_concurrent_readers_dont_block_each_other():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=5.0, max_waiters=20)
    results = []

    async def reader(i):
        async with mgr.read("b", "k"):
            results.append(f"in-{i}")
            await asyncio.sleep(0.05)
            results.append(f"out-{i}")

    start = time.monotonic()
    await asyncio.gather(*[reader(i) for i in range(5)])
    elapsed = time.monotonic() - start

    # 5 concurrent readers × 0.05s each; if serialized → 0.25s
    assert elapsed < 0.15, f"readers should run concurrently, took {elapsed:.3f}s"
    assert len([r for r in results if r.startswith("in-")]) == 5
