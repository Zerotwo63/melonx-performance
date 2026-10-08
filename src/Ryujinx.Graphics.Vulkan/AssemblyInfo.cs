using System.Runtime.CompilerServices;

// Grants Ryujinx.Tests access to the internal, pure file-I/O helpers in
// PipelineBase.cs (GetPipelineCacheFilePath/LoadPipelineCacheData/
// WriteCacheFileAtomic) so the Vulkan pipeline cache persistence logic can
// have a real test without needing a Vulkan device, without widening
// PipelineBase's public API surface.
[assembly: InternalsVisibleTo("Ryujinx.Tests")]
