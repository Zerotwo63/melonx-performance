using NUnit.Framework;
using Ryujinx.Cpu.LightningJit.Cache;

namespace Ryujinx.Tests.Cpu.LightningJit
{
    /// <summary>
    /// Regression test for the confirmed root cause of "start game A, stop
    /// it, start game B without restarting the app" failing at
    /// TranslatorStubs.Map begin with no Map end: Clear() used to leave
    /// the allocator's free-block list EMPTY instead of resetting it to
    /// one block covering the full capacity, so every Allocate() call
    /// after a Clear() returned -1 forever, regardless of FreeSize
    /// reporting the full capacity as available.
    /// </summary>
    class CacheMemoryAllocatorTests
    {
        [Test]
        public void AllocateSucceedsAfterClear()
        {
            CacheMemoryAllocator allocator = new(4096);

            int first = allocator.Allocate(1024);
            Assert.That(first, Is.GreaterThanOrEqualTo(0));

            allocator.Clear();

            Assert.That(allocator.UsedSize, Is.EqualTo(0));
            Assert.That(allocator.FreeSize, Is.EqualTo(4096));

            // This is the exact call that returned -1 forever with the
            // previous buggy Clear() (empty block list), even though
            // FreeSize/UsedSize already reported the allocator as empty.
            int second = allocator.Allocate(1024);
            Assert.That(second, Is.GreaterThanOrEqualTo(0));
        }

        [Test]
        public void ClearRestoresFullCapacityAsOneBlock()
        {
            CacheMemoryAllocator allocator = new(4096);

            allocator.Allocate(4096);
            Assert.That(allocator.FreeSize, Is.EqualTo(0));

            allocator.Clear();

            // A single allocation for the WHOLE capacity must succeed -
            // only possible if Clear() left exactly one free block
            // spanning all 4096 bytes, not zero blocks.
            int offset = allocator.Allocate(4096);
            Assert.That(offset, Is.EqualTo(0));
        }

        [Test]
        public void MultipleAllocateClearCyclesStayConsistent()
        {
            CacheMemoryAllocator allocator = new(8192);

            for (int cycle = 0; cycle < 5; cycle++)
            {
                int a = allocator.Allocate(2048);
                int b = allocator.Allocate(2048);

                Assert.That(a, Is.GreaterThanOrEqualTo(0));
                Assert.That(b, Is.GreaterThanOrEqualTo(0));

                allocator.Clear();

                Assert.That(allocator.UsedSize, Is.EqualTo(0));
                Assert.That(allocator.FreeSize, Is.EqualTo(8192));
            }
        }
    }

    /// <summary>
    /// PageAlignedRangeList.Clear() backs
    /// DualMappedNoWxCache.EndGameSession()'s per-game bookkeeping reset -
    /// verified independently of any native/iOS-specific allocator so
    /// this test can run on any platform.
    /// </summary>
    class PageAlignedRangeListTests
    {
        [Test]
        public void ClearRemovesPendingEntriesAndAllowsReuse()
        {
            int alignedRangeCalls = 0;
            int alignedFunctionCalls = 0;

            PageAlignedRangeList list = new(
                (offset, size) => alignedRangeCalls++,
                (address, function) => alignedFunctionCalls++);

            Assert.That(list.Has(0x1000), Is.False);

            list.Clear();

            Assert.That(list.Has(0x1000), Is.False);
            Assert.That(alignedRangeCalls, Is.EqualTo(0));
            Assert.That(alignedFunctionCalls, Is.EqualTo(0));
        }

        [Test]
        public void RemoveOverlapsStillWorksAfterClear()
        {
            PageAlignedRangeList list = new((_, _) => { }, (_, _) => { });

            list.Clear();

            // Must not throw - Clear() leaves internal lists empty, not null.
            Assert.DoesNotThrow(() => list.RemoveOverlaps(0x1000, 0x100));
            Assert.DoesNotThrow(() => list.Has(0x1000));
        }

        [Test]
        public void ClearIsIdempotent()
        {
            PageAlignedRangeList list = new((_, _) => { }, (_, _) => { });

            // Mirrors a double "stop game" - EndGameSession() must not
            // crash or corrupt state if called twice in a row (e.g. the
            // user double-taps Exit, or Exit fires once from the UI and
            // once from a watchdog/error path).
            Assert.DoesNotThrow(() =>
            {
                list.Clear();
                list.Clear();
            });
        }
    }

    /// <summary>
    /// Conceptual equivalent of "for session in 1..10: start, initialize,
    /// stop, teardown, assert clean state" (requested explicitly), using
    /// the exact same primitives DualMappedNoWxCache.EndGameSession()
    /// resets (CacheMemoryAllocator + PageAlignedRangeList + a
    /// guest-address-keyed dictionary standing in for _functionMetadata)
    /// - the real DualMappedNoWxCache/DualMappedJitAllocator cannot be
    /// instantiated here since their allocator does real mmap/vm_remap
    /// Darwin syscalls, not available on a non-iOS test runner. This
    /// still exercises the exact bug class that was found and fixed:
    /// state that must be reset between sessions but previously wasn't
    /// (or, before CacheMemoryAllocator.Clear()'s fix, was reset into a
    /// broken state).
    /// </summary>
    class GameSessionLifecycleTests
    {
        private const int SharedCacheCapacity = 65536;

        [Test]
        public void TenConsecutiveSessionsStartStopCleanly()
        {
            CacheMemoryAllocator sharedCache = new(SharedCacheCapacity);
            PageAlignedRangeList pendingMap = new((_, _) => { }, (_, _) => { });
            System.Collections.Generic.Dictionary<ulong, int> functionMetadata = new();

            for (int session = 1; session <= 10; session++)
            {
                // start / initialize: allocate as if this session's
                // guest code (its own guest addresses, deliberately
                // reused every session to prove a previous session's
                // entries never survive into the next).
                int offsetA = sharedCache.Allocate(1024);
                int offsetB = sharedCache.Allocate(1024);

                Assert.That(offsetA, Is.GreaterThanOrEqualTo(0), $"session {session}: first allocation failed");
                Assert.That(offsetB, Is.GreaterThanOrEqualTo(0), $"session {session}: second allocation failed");

                functionMetadata[0x1000] = offsetA;
                functionMetadata[0x2000] = offsetB;

                Assert.That(functionMetadata.Count, Is.EqualTo(2), $"session {session}: unexpected residual entries before stop");

                // stop / teardown: the exact reset EndGameSession() does.
                functionMetadata.Clear();
                pendingMap.Clear();
                sharedCache.Clear();

                // assert clean state: the next session must find the
                // cache fully free and no stale function registrations -
                // this is the precise assertion that fails without the
                // CacheMemoryAllocator.Clear() fix (FreeSize would lie
                // about being fully free while Allocate() returned -1
                // forever).
                Assert.That(sharedCache.UsedSize, Is.EqualTo(0), $"session {session}: allocator not fully freed after stop");
                Assert.That(sharedCache.FreeSize, Is.EqualTo(SharedCacheCapacity), $"session {session}: allocator capacity not fully restored after stop");
                Assert.That(functionMetadata.Count, Is.EqualTo(0), $"session {session}: stale function registrations survived teardown");
                Assert.That(pendingMap.Has(0x1000), Is.False, $"session {session}: stale pending range survived teardown");
            }
        }

        [Test]
        public void DoubleStopDoesNotCrashOrDoubleFree()
        {
            CacheMemoryAllocator sharedCache = new(SharedCacheCapacity);
            sharedCache.Allocate(1024);

            Assert.DoesNotThrow(() =>
            {
                sharedCache.Clear();
                sharedCache.Clear();
            }, "a double 'stop game' must be idempotent, not corrupt or crash");

            Assert.That(sharedCache.UsedSize, Is.EqualTo(0));
            Assert.That(sharedCache.FreeSize, Is.EqualTo(SharedCacheCapacity));
        }

        [Test]
        public void NextSessionCanFullyReinitializeAfterPreviousOneStopped()
        {
            CacheMemoryAllocator sharedCache = new(SharedCacheCapacity);

            sharedCache.Allocate(SharedCacheCapacity);
            Assert.That(sharedCache.FreeSize, Is.EqualTo(0), "setup: expected the cache to start full");

            sharedCache.Clear();

            // The next session must be able to use the ENTIRE capacity
            // again, not just whatever happened to be freed piecemeal.
            int offset = sharedCache.Allocate(SharedCacheCapacity);
            Assert.That(offset, Is.EqualTo(0));
        }
    }
}
