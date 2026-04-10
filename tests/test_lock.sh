#!/bin/bash
# tests/test_lock.sh - Unit tests for the RW lock (app/lock.py)
# These run on the host against the local source, no server needed.

LOCK_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/app"

run_lock_test() {
    python3 - "$LOCK_PY" <<EOF
import sys, asyncio
sys.path.insert(0, sys.argv[1])
from lock import _RWLock, LockManager, LockTimeout, LockHoldTimeout, LockOverloaded

$1
asyncio.run(main())
EOF
}

# ── _RWLock ───────────────────────────────────────────────────────────────────

test_lock_multiple_readers() {
    local out
    out=$(run_lock_test '
async def main():
    lock = _RWLock()
    order = []
    async def reader(n):
        await lock.acquire("r", 1.0, 10)
        order.append(f"in{n}")
        await asyncio.sleep(0.02)
        order.append(f"out{n}")
        await lock.release("r")
    await asyncio.gather(reader(1), reader(2), reader(3))
    # all 3 must have been inside before any exited
    first_out = min(order.index(f"out{n}") for n in (1,2,3))
    last_in  = max(order.index(f"in{n}")  for n in (1,2,3))
    print("ok" if last_in < first_out else "fail:" + str(order))
')
    assert_eq "$out" "ok" "multiple readers hold simultaneously"
}
ALL_TESTS+=(test_lock_multiple_readers)

test_lock_writer_exclusive() {
    local out
    out=$(run_lock_test '
async def main():
    lock = _RWLock()
    log = []
    async def writer():
        await lock.acquire("w", 1.0, 10)
        log.append("w_in")
        await asyncio.sleep(0.05)
        log.append("w_out")
        await lock.release("w")
    async def reader():
        await asyncio.sleep(0.01)
        await lock.acquire("r", 1.0, 10)
        log.append("r_in")
        await lock.release("r")
    await asyncio.gather(writer(), reader())
    print("ok" if log.index("w_out") < log.index("r_in") else "fail:" + str(log))
')
    assert_eq "$out" "ok" "writer blocks reader until released"
}
ALL_TESTS+=(test_lock_writer_exclusive)

test_lock_readers_block_writer() {
    local out
    out=$(run_lock_test '
async def main():
    lock = _RWLock()
    log = []
    async def slow_reader():
        await lock.acquire("r", 1.0, 10)
        log.append("r_in")
        await asyncio.sleep(0.05)
        log.append("r_out")
        await lock.release("r")
    async def writer():
        await asyncio.sleep(0.01)
        await lock.acquire("w", 1.0, 10)
        log.append("w_in")
        await lock.release("w")
    await asyncio.gather(slow_reader(), writer())
    print("ok" if log.index("r_out") < log.index("w_in") else "fail:" + str(log))
')
    assert_eq "$out" "ok" "readers block writer until released"
}
ALL_TESTS+=(test_lock_readers_block_writer)

test_lock_acquire_timeout() {
    local out
    out=$(run_lock_test '
async def main():
    lock = _RWLock()
    async def hold():
        await lock.acquire("w", 1.0, 10)
        await asyncio.sleep(0.2)
        await lock.release("w")
    async def try_read():
        await asyncio.sleep(0.01)
        try:
            await lock.acquire("r", 0.05, 10)
            await lock.release("r")
            print("fail:no timeout")
        except LockTimeout:
            print("ok")
    await asyncio.gather(hold(), try_read())
')
    assert_eq "$out" "ok" "acquire timeout fires when lock held"
}
ALL_TESTS+=(test_lock_acquire_timeout)

test_lock_overloaded() {
    local out
    out=$(run_lock_test '
async def main():
    lock = _RWLock()
    await lock.acquire("w", 1.0, 10)
    got_overload = False
    async def try_r():
        nonlocal got_overload
        try:
            await lock.acquire("r", 5.0, max_waiters=2)
            await lock.release("r")
        except LockOverloaded:
            got_overload = True
        except LockTimeout:
            pass
    tasks = [asyncio.create_task(try_r()) for _ in range(4)]
    await asyncio.sleep(0.05)
    for t in tasks:
        if not t.done():
            t.cancel()
    await lock.release("w")
    await asyncio.gather(*tasks, return_exceptions=True)
    print("ok" if got_overload else "fail:no overload raised")
')
    assert_eq "$out" "ok" "LockOverloaded raised when queue full"
}
ALL_TESTS+=(test_lock_overloaded)

test_lock_idle_after_release() {
    local out
    out=$(run_lock_test '
async def main():
    lock = _RWLock()
    await lock.acquire("w", 1.0, 10)
    await lock.release("w")
    print("ok" if lock.idle else "fail:not idle")
')
    assert_eq "$out" "ok" "lock idle after all released"
}
ALL_TESTS+=(test_lock_idle_after_release)

# ── LockManager ───────────────────────────────────────────────────────────────

test_lock_manager_hold_timeout() {
    local out
    out=$(run_lock_test '
async def main():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=0.05, max_waiters=10)
    try:
        async with mgr.write("b", "k"):
            await asyncio.sleep(0.2)
        print("fail:no exception")
    except LockHoldTimeout:
        print("ok")
')
    assert_eq "$out" "ok" "hold timeout raises LockHoldTimeout"
}
ALL_TESTS+=(test_lock_manager_hold_timeout)

test_lock_manager_released_after_hold_timeout() {
    local out
    out=$(run_lock_test '
async def main():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=0.05, max_waiters=10)
    try:
        async with mgr.write("b", "k"):
            await asyncio.sleep(0.2)
    except LockHoldTimeout:
        pass
    async with mgr.write("b", "k"):
        print("ok")
')
    assert_eq "$out" "ok" "lock released after hold timeout"
}
ALL_TESTS+=(test_lock_manager_released_after_hold_timeout)

test_lock_manager_different_keys_independent() {
    local out
    out=$(run_lock_test '
async def main():
    mgr = LockManager(acquire_timeout=0.1, hold_timeout=5.0, max_waiters=10)
    log = []
    async def write_key(k):
        async with mgr.write("b", k):
            log.append(f"{k}_in")
            await asyncio.sleep(0.03)
            log.append(f"{k}_out")
    await asyncio.gather(write_key("k1"), write_key("k2"), write_key("k3"))
    # all 3 should overlap (ran concurrently) — last_in < first_out
    keys = ("k1","k2","k3")
    first_out = min(log.index(f"{k}_out") for k in keys)
    last_in   = max(log.index(f"{k}_in")  for k in keys)
    print("ok" if last_in < first_out else "fail:serialized:" + str(log))
')
    assert_eq "$out" "ok" "different keys acquire independently"
}
ALL_TESTS+=(test_lock_manager_different_keys_independent)

test_lock_manager_cleanup() {
    local out
    out=$(run_lock_test '
async def main():
    mgr = LockManager(acquire_timeout=1.0, hold_timeout=1.0, max_waiters=10)
    async with mgr.write("b", "gone"):
        pass
    print("ok" if ("b","gone") not in mgr._locks else "fail:lock not removed")
')
    assert_eq "$out" "ok" "idle lock removed from manager after release"
}
ALL_TESTS+=(test_lock_manager_cleanup)
