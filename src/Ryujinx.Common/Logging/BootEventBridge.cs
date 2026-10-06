using System;

namespace Ryujinx.Common.Logging
{
    /// <summary>
    /// Deterministic boot-trace sink for projects (Ryujinx.Graphics.Vulkan)
    /// that cannot reference Ryujinx.Headless.SDL2.Program directly (reverse
    /// project dependency). Program.cs wires ReportEvent/ReportFailure to the
    /// real ReportBootEvent/ReportBootFailure bridge at managed-entry time;
    /// until wired (or if never wired), falls back to plain Console.WriteLine
    /// so nothing is silently lost either way.
    /// </summary>
    public static class BootEventBridge
    {
        public static Action<string, string> ReportEvent;
        public static Action<string, Exception> ReportFailure;

        public static void Report(string name, string value = null)
        {
            var sink = ReportEvent;
            if (sink != null)
            {
                sink(name, value);
            }
            else
            {
                Console.WriteLine(value == null ? $"[BOOT] {name}" : $"[BOOT] {name} = {value}");
            }
        }

        public static void ReportFail(string stage, Exception ex)
        {
            var sink = ReportFailure;
            if (sink != null)
            {
                sink(stage, ex);
            }
            else
            {
                Console.WriteLine($"[BOOT] {stage} FAILED (bridge not wired yet): {ex}");
            }
        }
    }
}
