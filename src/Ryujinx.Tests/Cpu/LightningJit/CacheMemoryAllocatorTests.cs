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
    }
}
