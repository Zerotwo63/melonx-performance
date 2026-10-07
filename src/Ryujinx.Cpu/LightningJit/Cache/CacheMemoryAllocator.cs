using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;

namespace Ryujinx.Cpu.LightningJit.Cache
{
    class CacheMemoryAllocator
    {
        private readonly struct MemoryBlock : IComparable<MemoryBlock>
        {
            public int Offset { get; }
            public int Size { get; }

            public MemoryBlock(int offset, int size)
            {
                Offset = offset;
                Size = size;
            }

            public int CompareTo([AllowNull] MemoryBlock other)
            {
                return Offset.CompareTo(other.Offset);
            }
        }

        private readonly List<MemoryBlock> _blocks = new();
        private readonly int _capacity;
        private int _usedSize;

        public int UsedSize => _usedSize;
        public int Capacity => _capacity;
        public int FreeSize => _capacity - _usedSize;

        public CacheMemoryAllocator(int capacity)
        {
            _capacity = capacity;
            _usedSize = 0;
            _blocks.Add(new MemoryBlock(0, capacity));
        }

        public int Allocate(int size)
        {
            for (int i = 0; i < _blocks.Count; i++)
            {
                MemoryBlock block = _blocks[i];

                if (block.Size > size)
                {
                    _blocks[i] = new(block.Offset + size, block.Size - size);
                    _usedSize += size;
                    return block.Offset;
                }
                else if (block.Size == size)
                {
                    _blocks.RemoveAt(i);
                    _usedSize += size;
                    return block.Offset;
                }
            }

            // We don't have enough free memory to perform the allocation.
            return -1;
        }

        public void ForceAllocation(int offset, int size)
        {
            int index = _blocks.BinarySearch(new(offset, size));

            if (index < 0)
            {
                index = ~index;
            }

            int endOffset = offset + size;
            MemoryBlock block = _blocks[index];

            Debug.Assert(block.Offset <= offset && block.Offset + block.Size >= endOffset);

            if (offset > block.Offset && endOffset < block.Offset + block.Size)
            {
                _blocks[index] = new(block.Offset, offset - block.Offset);
                _blocks.Insert(index + 1, new(endOffset, (block.Offset + block.Size) - endOffset));
            }
            else if (offset > block.Offset)
            {
                _blocks[index] = new(block.Offset, offset - block.Offset);
            }
            else if (endOffset < block.Offset + block.Size)
            {
                _blocks[index] = new(endOffset, (block.Offset + block.Size) - endOffset);
            }
            else
            {
                _blocks.RemoveAt(index);
            }

            _usedSize += size;
        }

        public void Free(int offset, int size)
        {
            Insert(new MemoryBlock(offset, size));
            _usedSize -= size;
        }

        private void Insert(MemoryBlock block)
        {
            int index = _blocks.BinarySearch(block);

            if (index < 0)
            {
                index = ~index;
            }

            if (index < _blocks.Count)
            {
                MemoryBlock next = _blocks[index];
                int endOffs = block.Offset + block.Size;

                if (next.Offset == endOffs)
                {
                    block = new MemoryBlock(block.Offset, block.Size + next.Size);
                    _blocks.RemoveAt(index);
                }
            }

            if (index > 0)
            {
                MemoryBlock prev = _blocks[index - 1];

                if (prev.Offset + prev.Size == block.Offset)
                {
                    block = new MemoryBlock(block.Offset - prev.Size, block.Size + prev.Size);
                    _blocks.RemoveAt(--index);
                }
            }

            _blocks.Insert(index, block);
        }

        /// <summary>
        /// Resets the allocator back to its construction-time state: one
        /// single free block covering the entire capacity. The previous
        /// implementation only did `_blocks.Clear()`, leaving ZERO free
        /// blocks - every subsequent <see cref="Allocate(int)"/> call then
        /// fell through the "no block big enough" loop immediately and
        /// returned -1 (interpreted by callers as permanent
        /// out-of-memory), regardless of <see cref="FreeSize"/> reporting
        /// the full capacity as available. This is the confirmed root
        /// cause of the second-game-after-first-game-closes failure: this
        /// allocator backs the dual-mapped shared/local JIT caches, which
        /// are process-wide singletons reused across game sessions -
        /// disposing the first game's <c>Translator</c> called this
        /// buggy <c>Clear()</c> on the SAME allocator instance the second
        /// game then tried to allocate from.
        /// </summary>
        public void Clear()
        {
            _blocks.Clear();
            _blocks.Add(new MemoryBlock(0, _capacity));
            _usedSize = 0;
        }
    }
}