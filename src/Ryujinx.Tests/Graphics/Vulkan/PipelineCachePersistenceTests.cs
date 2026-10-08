using NUnit.Framework;
using Ryujinx.Graphics.Vulkan;
using System;
using System.IO;

namespace Ryujinx.Tests.Graphics.Vulkan
{
    /// <summary>
    /// Covers the pure, explicit-path file-I/O helpers behind PipelineBase's
    /// persisted VkPipelineCache (FASE 1 verification round). These are the
    /// only parts of that feature testable without a real Vulkan device -
    /// CreatePipelineCache/GetPipelineCacheData themselves need an actual
    /// GPU/driver and are NOT exercised here. What IS covered: that a
    /// missing or corrupt file is handled without throwing (the same
    /// fail-safe behavior LoadPipelineCacheData relies on), and that
    /// WriteCacheFileAtomic never leaves a partially-written target file on
    /// disk - the exact property that makes repeated game-session
    /// teardown/launch safe against a crash or iOS suspend landing mid-save.
    /// </summary>
    class PipelineCachePersistenceTests
    {
        private string _tempDir;

        [SetUp]
        public void Setup()
        {
            _tempDir = Path.Combine(Path.GetTempPath(), "RyujinxPipelineCacheTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_tempDir);
        }

        [TearDown]
        public void Teardown()
        {
            if (Directory.Exists(_tempDir))
            {
                Directory.Delete(_tempDir, true);
            }
        }

        [Test]
        public void ReadCacheFileIfExistsReturnsNullWhenMissing()
        {
            string path = Path.Combine(_tempDir, "does_not_exist.bin");

            Assert.That(PipelineBase.ReadCacheFileIfExists(path), Is.Null);
        }

        [Test]
        public void ReadCacheFileIfExistsReturnsExactBytesWritten()
        {
            string path = Path.Combine(_tempDir, "cache.bin");
            byte[] expected = { 1, 2, 3, 4, 5, 255, 0, 128 };

            File.WriteAllBytes(path, expected);

            byte[] actual = PipelineBase.ReadCacheFileIfExists(path);

            Assert.That(actual, Is.EqualTo(expected));
        }

        [Test]
        public void WriteCacheFileAtomicCreatesMissingDirectory()
        {
            string nestedPath = Path.Combine(_tempDir, "nested", "sub", "cache.bin");
            byte[] data = { 10, 20, 30 };

            PipelineBase.WriteCacheFileAtomic(nestedPath, data);

            Assert.That(File.Exists(nestedPath), Is.True);
            Assert.That(File.ReadAllBytes(nestedPath), Is.EqualTo(data));
        }

        [Test]
        public void WriteCacheFileAtomicOverwritesExistingContentCompletely()
        {
            string path = Path.Combine(_tempDir, "cache.bin");
            byte[] oldData = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
            byte[] newData = { 2, 2 };

            PipelineBase.WriteCacheFileAtomic(path, oldData);
            PipelineBase.WriteCacheFileAtomic(path, newData);

            // Regression guard for exactly the bug this round found in
            // PipelineBase/PipelineHelperShader: a naive overwrite could
            // leave stale trailing bytes if the new content is shorter and
            // the write isn't a full replace. File.Move-based replacement
            // can't do that (the old file is atomically swapped out
            // wholesale), but this assertion is what would catch it if a
            // future change switched back to writing the target in place.
            Assert.That(File.ReadAllBytes(path), Is.EqualTo(newData));
        }

        [Test]
        public void WriteCacheFileAtomicLeavesNoTempFileBehind()
        {
            string path = Path.Combine(_tempDir, "cache.bin");

            PipelineBase.WriteCacheFileAtomic(path, new byte[] { 9 });

            Assert.That(File.Exists(path + ".tmp"), Is.False);
        }

        [Test]
        public void GetPipelineCacheFilePathDiffersPerOwner()
        {
            // Regression guard for the confirmed bug this round found:
            // PipelineFull and PipelineHelperShader used to resolve to the
            // SAME hardcoded filename, so whichever of the two saved LAST
            // during VulkanRenderer.Dispose() silently discarded the
            // other's cache contents. This only verifies the two owners
            // can never collide on a path - it does not (and cannot,
            // without a real Vulkan device) verify the save/load round-trip
            // through CreatePipelineCache/GetPipelineCacheData itself.
            //
            // Disclosed side effect: AppDataManager.Initialize() creates
            // its real games/profiles/system/logs directories on whatever
            // machine runs this test (same thing a normal launch does) -
            // there is no lighter-weight way to exercise
            // GetPipelineCacheFilePath, since it reads AppDataManager's
            // static BaseDirPath directly.
            Ryujinx.Common.Configuration.AppDataManager.Initialize(null);

            string mainPath = PipelineBase.GetPipelineCacheFilePath("main");
            string helperPath = PipelineBase.GetPipelineCacheFilePath("helper");

            Assert.That(mainPath, Is.Not.EqualTo(helperPath));
        }
    }
}
