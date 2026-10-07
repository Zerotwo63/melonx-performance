using System.Runtime.CompilerServices;

// Grants Ryujinx.Tests access to internal LightningJit types
// (Ryujinx.Cpu.LightningJit.Cache.CacheMemoryAllocator, etc.) so the
// second-game-session lifecycle fix can have a real regression test
// without widening those types' public API surface.
[assembly: InternalsVisibleTo("Ryujinx.Tests")]
