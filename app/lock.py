"""Per-key async RW lock manager.

Multiple concurrent readers are allowed. A writer gets exclusive access,
blocking all readers and other writers. Both acquire and hold are bounded
by timeouts; the waiter queue per key is capped to shed overload early.
"""

import asyncio
from contextlib import asynccontextmanager
from typing import Literal

# Defaults — tune via LockManager constructor.
ACQUIRE_TIMEOUT = 30.0   # seconds to wait for the lock before giving up
HOLD_TIMEOUT = 300.0     # seconds a lock may be held (generous for large uploads)
MAX_WAITERS = 100        # max goroutines queued per key before rejecting


class LockTimeout(Exception):
    """Lock could not be acquired within acquire_timeout."""


class LockHoldTimeout(Exception):
    """Operation held the lock longer than hold_timeout."""


class LockOverloaded(Exception):
    """Waiter queue for this key is full."""


class _RWLock:
    """Async RW lock: N readers OR 1 exclusive writer."""

    def __init__(self) -> None:
        self._cond: asyncio.Condition = asyncio.Condition()
        self._readers: int = 0
        self._writing: bool = False
        self._waiters: int = 0

    @property
    def idle(self) -> bool:
        return self._readers == 0 and not self._writing and self._waiters == 0

    # ── internal acquire coroutines ───────────────────────────────────────────

    async def _acquire_read(self) -> None:
        async with self._cond:
            while self._writing:
                await self._cond.wait()
            self._readers += 1

    async def _acquire_write(self) -> None:
        async with self._cond:
            while self._writing or self._readers > 0:
                await self._cond.wait()
            self._writing = True

    # ── public acquire / release ──────────────────────────────────────────────

    async def acquire(
        self,
        mode: Literal["r", "w"],
        acquire_timeout: float,
        max_waiters: int,
    ) -> None:
        if self._waiters >= max_waiters:
            raise LockOverloaded()
        self._waiters += 1
        try:
            coro = self._acquire_read() if mode == "r" else self._acquire_write()
            try:
                await asyncio.wait_for(coro, timeout=acquire_timeout)
            except asyncio.TimeoutError:
                raise LockTimeout()
        finally:
            self._waiters -= 1

    async def release(self, mode: Literal["r", "w"]) -> None:
        async with self._cond:
            if mode == "r":
                self._readers -= 1
            else:
                self._writing = False
            self._cond.notify_all()


class LockManager:
    """Per-(bucket, key) async RW lock manager."""

    def __init__(
        self,
        acquire_timeout: float = ACQUIRE_TIMEOUT,
        hold_timeout: float = HOLD_TIMEOUT,
        max_waiters: int = MAX_WAITERS,
    ) -> None:
        self._locks: dict[tuple[str, str], _RWLock] = {}
        self._mgr: asyncio.Lock = asyncio.Lock()
        self.acquire_timeout = acquire_timeout
        self.hold_timeout = hold_timeout
        self.max_waiters = max_waiters

    async def _get(self, bucket: str, key: str) -> _RWLock:
        k = (bucket, key)
        async with self._mgr:
            if k not in self._locks:
                self._locks[k] = _RWLock()
            return self._locks[k]

    async def _drop_if_idle(self, bucket: str, key: str) -> None:
        k = (bucket, key)
        async with self._mgr:
            lock = self._locks.get(k)
            if lock and lock.idle:
                del self._locks[k]

    @asynccontextmanager
    async def read(self, bucket: str, key: str):
        """Shared read lock — blocks writers, allows concurrent readers."""
        lock = await self._get(bucket, key)
        await lock.acquire("r", self.acquire_timeout, self.max_waiters)
        try:
            try:
                async with asyncio.timeout(self.hold_timeout):
                    yield
            except TimeoutError:
                raise LockHoldTimeout()
        finally:
            await lock.release("r")
            await self._drop_if_idle(bucket, key)

    @asynccontextmanager
    async def write(self, bucket: str, key: str):
        """Exclusive write lock — blocks all readers and writers."""
        lock = await self._get(bucket, key)
        await lock.acquire("w", self.acquire_timeout, self.max_waiters)
        try:
            try:
                async with asyncio.timeout(self.hold_timeout):
                    yield
            except TimeoutError:
                raise LockHoldTimeout()
        finally:
            await lock.release("w")
            await self._drop_if_idle(bucket, key)
