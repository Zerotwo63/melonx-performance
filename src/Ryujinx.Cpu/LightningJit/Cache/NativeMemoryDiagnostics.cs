using Ryujinx.Common.Logging;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Cpu.LightningJit.Cache
{
    /// <summary>
    /// Diagnóstico real #8 (FASES 8A-8G): pure diagnostic helpers isolating
    /// WHY a tiny ARM64 function, written through the dual-mapped RW alias
    /// and invoked through the RX alias, never returns. Every method here
    /// is read-only or additive logging - none of them change how
    /// DualMappedJitAllocator/DualMappedNoWxCache actually allocate, map,
    /// protect, or invalidate memory for real guest code.
    /// </summary>
    static partial class NativeMemoryDiagnostics
    {
        // ---- vm_prot_t bits (mach/vm_prot.h) ----
        private const int VM_PROT_NONE = 0x00;
        private const int VM_PROT_READ = 0x01;
        private const int VM_PROT_WRITE = 0x02;
        private const int VM_PROT_EXECUTE = 0x04;

        private const int VM_REGION_BASIC_INFO_64 = 9;
        private const uint VM_REGION_BASIC_INFO_COUNT_64 = 9; // natural_t (4-byte) words

        [DllImport("libc")]
        private static extern ulong mach_task_self();

        [DllImport("libc")]
        private static extern int mach_vm_region(
            ulong target_task,
            ref ulong address,
            ref ulong size,
            int flavor,
            byte[] info,
            ref uint count,
            ref uint objectName);

        [LibraryImport("libc", EntryPoint = "sys_dcache_flush", SetLastError = true)]
        private static partial void SysDcacheFlush(IntPtr start, IntPtr len);

        [DllImport("libc", EntryPoint = "sysctlbyname", SetLastError = true)]
        private static extern int SysctlByName(string name, ref int oldValue, ref nuint oldLenP, IntPtr newValue, nuint newLen);

        [DllImport("libc")]
        private static extern IntPtr dlsym(IntPtr handle, string symbol);

        private static readonly IntPtr RtldDefault = new(-2); // RTLD_DEFAULT

        /// <summary>
        /// Translates vm_prot_t bits into "READ,WRITE,EXECUTE" (or "NONE").
        /// </summary>
        public static string DescribeProtection(int prot)
        {
            if (prot == VM_PROT_NONE)
            {
                return "NONE";
            }

            var parts = new System.Collections.Generic.List<string>();
            if ((prot & VM_PROT_READ) != 0) parts.Add("READ");
            if ((prot & VM_PROT_WRITE) != 0) parts.Add("WRITE");
            if ((prot & VM_PROT_EXECUTE) != 0) parts.Add("EXECUTE");
            return string.Join(",", parts);
        }

        /// <summary>
        /// FASE 8B: queries the REAL current/max protection of the page
        /// containing <paramref name="address"/> via mach_vm_region - never
        /// assumed from whether a prior vm_protect/mmap call returned
        /// success. Returns (currentProtection, maxProtection) as raw
        /// vm_prot_t bits, or null if the query itself failed (reported).
        /// </summary>
        public static (int current, int max)? QueryProtection(IntPtr address, string label)
        {
            try
            {
                ulong addr = (ulong)address;
                ulong size = 0;
                byte[] info = new byte[64]; // more than the 9 natural_t words VM_REGION_BASIC_INFO_64 needs
                uint count = VM_REGION_BASIC_INFO_COUNT_64;
                uint objectName = 0;

                int result = mach_vm_region(mach_task_self(), ref addr, ref size, VM_REGION_BASIC_INFO_64, info, ref count, ref objectName);

                if (result != 0)
                {
                    BootEventBridge.Report($"NativeMemoryDiagnostics.QueryProtection {label} failed", $"krReturn={result}");
                    return null;
                }

                // vm_region_basic_info_64: first two fields are
                // vm_prot_t protection, vm_prot_t max_protection - both
                // plain 4-byte ints at offset 0/4 regardless of later
                // struct padding, so reading them directly out of the raw
                // buffer is safe without needing an exact [StructLayout].
                int protection = BitConverter.ToInt32(info, 0);
                int maxProtection = BitConverter.ToInt32(info, 4);

                BootEventBridge.Report(
                    $"NativeMemoryDiagnostics.QueryProtection {label}",
                    $"regionBase=0x{addr:X},regionSize=0x{size:X},current={DescribeProtection(protection)},max={DescribeProtection(maxProtection)}");

                return (protection, maxProtection);
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail($"NativeMemoryDiagnostics.QueryProtection {label}", ex);
                return null;
            }
        }

        /// <summary>
        /// FASE 8C: explicit, visible cache synchronization sequence -
        /// flushes the RW alias's data cache (if sys_dcache_flush exists)
        /// and invalidates the instruction cache on the RX alias
        /// specifically (never only on RW), reporting each step.
        /// </summary>
        public static bool SyncCaches(IntPtr rwAddress, IntPtr rxAddress, int size)
        {
            bool dcacheOk = true;
            bool icacheRwOk = true;
            bool icacheRxOk = true;

            BootEventBridge.Report("dispatchProbeDcacheFlushRwAttempted", "true");
            try
            {
                SysDcacheFlush(rwAddress, (IntPtr)size);
            }
            catch (Exception ex)
            {
                dcacheOk = false;
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.SysDcacheFlush RW", ex);
            }

            // Not requested by name, but cheap and harmless: also invalidate
            // on the RW alias, in case the two virtual aliases don't share
            // icache lines 1:1 on this hardware/OS and BOTH need treatment.
            BootEventBridge.Report("dispatchProbeIcacheInvalidateRwAttempted", "true");
            try
            {
                JitSupportDarwin.SysIcacheInvalidate(rwAddress, (IntPtr)size);
            }
            catch (Exception ex)
            {
                icacheRwOk = false;
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.SysIcacheInvalidate RW", ex);
            }

            BootEventBridge.Report("dispatchProbeIcacheInvalidateRxAttempted", "true");
            try
            {
                // THE important one per this round's hypothesis: invalidate
                // on the address we are actually about to jump to (RX), not
                // only on the address we wrote through (RW).
                JitSupportDarwin.SysIcacheInvalidate(rxAddress, (IntPtr)size);
            }
            catch (Exception ex)
            {
                icacheRxOk = false;
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.SysIcacheInvalidate RX", ex);
            }

            bool completed = dcacheOk && icacheRwOk && icacheRxOk;
            BootEventBridge.Report("dispatchProbeCacheSyncCompleted", completed.ToString());
            return completed;
        }

        /// <summary>
        /// FASE 8F: reports the real process CPU subtype (arm64 vs arm64e)
        /// via sysctlbyname("hw.cpusubtype", ...) - never assumed from
        /// RuntimeInformation.ProcessArchitecture, which only reports
        /// "Arm64" either way and cannot distinguish the two ABIs.
        /// </summary>
        public static void ReportArchitecture()
        {
            BootEventBridge.Report("processArchitecture", RuntimeInformation.ProcessArchitecture.ToString());

            try
            {
                int subtype = 0;
                nuint len = (nuint)sizeof(int);
                int result = SysctlByName("hw.cpusubtype", ref subtype, ref len, IntPtr.Zero, 0);

                if (result == 0)
                {
                    // CPU_SUBTYPE_ARM64E = 2 (mach/machine.h) - the low byte
                    // identifies arm64e specifically; some OS versions also
                    // set high-byte PAC/ptr-auth-ABI flag bits on top of it,
                    // so mask to the low byte before comparing.
                    bool isArm64e = (subtype & 0xff) == 2;
                    BootEventBridge.Report("isArm64e", isArm64e.ToString());
                    BootEventBridge.Report("pointerAuthenticationRelevant", isArm64e.ToString());
                    BootEventBridge.Report("NativeMemoryDiagnostics.cpusubtype raw", $"0x{subtype:X}");
                }
                else
                {
                    BootEventBridge.Report("isArm64e", "unknown");
                    BootEventBridge.Report("pointerAuthenticationRelevant", "unknown");
                    BootEventBridge.ReportFail("NativeMemoryDiagnostics.ReportArchitecture sysctlbyname", new Exception($"sysctlbyname returned {result}, errno={Marshal.GetLastWin32Error()}"));
                }
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.ReportArchitecture", ex);
            }
        }

        private delegate int GetPidDelegate();

        /// <summary>
        /// FASE 8D: calls libc's real getpid() - a trivially-verifiable,
        /// ALREADY-compiled-into-the-process native function with no JIT,
        /// no dual mapping, no remap involved at all - via the EXACT SAME
        /// Marshal.GetDelegateForFunctionPointer mechanism SameMapProbe
        /// uses to call its RX pointer. If this also hangs or returns the
        /// wrong value, the problem is in the managed call/delegate/ABI
        /// layer, not in DualMappedNoWxCache specifically.
        /// </summary>
        public static (IntPtr pointer, bool attempted, bool returned, int value, bool passed) RunNativeControl()
        {
            IntPtr ptr;

            try
            {
                ptr = dlsym(RtldDefault, "getpid");
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunNativeControl dlsym", ex);
                return (IntPtr.Zero, false, false, 0, false);
            }

            BootEventBridge.Report("nativeControlPointer", $"0x{ptr:X}");

            if (ptr == IntPtr.Zero)
            {
                BootEventBridge.Report("nativeControlCallAttempted", "false");
                return (ptr, false, false, 0, false);
            }

            BootEventBridge.Report("nativeControlCallAttempted", "true");

            try
            {
                GetPidDelegate getPid = Marshal.GetDelegateForFunctionPointer<GetPidDelegate>(ptr);
                int result = getPid();
                bool passed = result == Environment.ProcessId;

                BootEventBridge.Report("nativeControlReturned", "true");
                BootEventBridge.Report("nativeControlReturnValue", result.ToString());
                BootEventBridge.Report("nativeControlPassed", passed.ToString());

                return (ptr, true, true, result, passed);
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunNativeControl call", ex);
                BootEventBridge.Report("nativeControlReturned", "false");
                BootEventBridge.Report("nativeControlPassed", "false");
                return (ptr, true, false, 0, false);
            }
        }

        private const int PROT_READ = 1;
        private const int PROT_WRITE = 2;
        private const int PROT_EXEC = 4;
        private const int MAP_ANON = 0x1000;
        private const int MAP_PRIVATE = 0x2;
        private static readonly IntPtr MapFailed = new(-1);

        [DllImport("libc", SetLastError = true)]
        private static extern IntPtr mmap(IntPtr addr, UIntPtr len, int prot, int flags, int fd, long offset);

        [DllImport("libc", SetLastError = true)]
        private static extern int mprotect(IntPtr addr, UIntPtr len, int prot);

        [DllImport("libc", SetLastError = true)]
        private static extern int munmap(IntPtr addr, UIntPtr len);

        private delegate uint SingleMapProbeDelegate();

        /// <summary>
        /// FASE 8E: single-mapping control - the SAME 8 bytes, written and
        /// executed from the SAME single virtual address (classic mmap RW
        /// -> write -> mprotect RX -> icache invalidate -> call), with NO
        /// dual-alias remap involved at all. Uses the same
        /// Marshal.GetDelegateForFunctionPointer call mechanism as
        /// SameMapProbe. A page is allocated and never freed (diagnostic
        /// only, one-time, negligible) to avoid any risk of unmapping
        /// memory that might still be referenced.
        /// </summary>
        public static (IntPtr rwAddress, IntPtr execAddress, byte[] bytesReadBack, bool callAttempted, bool returned, uint returnValue, bool passed) RunSingleMapControl(byte[] code, uint expectedValue)
        {
            IntPtr page;

            try
            {
                UIntPtr pageSize = (UIntPtr)Environment.SystemPageSize;
                page = mmap(IntPtr.Zero, pageSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);

                if (page == MapFailed)
                {
                    BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunSingleMapControl mmap", new Exception($"mmap failed, errno={Marshal.GetLastWin32Error()}"));
                    return (IntPtr.Zero, IntPtr.Zero, Array.Empty<byte>(), false, false, 0, false);
                }

                Marshal.Copy(code, 0, page, code.Length);

                int protectResult = mprotect(page, pageSize, PROT_READ | PROT_EXEC);
                if (protectResult != 0)
                {
                    BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunSingleMapControl mprotect", new Exception($"mprotect failed, errno={Marshal.GetLastWin32Error()}"));
                    return (page, IntPtr.Zero, Array.Empty<byte>(), false, false, 0, false);
                }

                JitSupportDarwin.SysIcacheInvalidate(page, (IntPtr)code.Length);

                byte[] bytesReadBack = new byte[code.Length];
                Marshal.Copy(page, bytesReadBack, 0, code.Length);

                BootEventBridge.Report("singleMapRwAddress", $"0x{page:X}");
                BootEventBridge.Report("singleMapExecAddress", $"0x{page:X}");
                BootEventBridge.Report("singleMapBytesReadBack", Convert.ToHexString(bytesReadBack));
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunSingleMapControl map", ex);
                return (IntPtr.Zero, IntPtr.Zero, Array.Empty<byte>(), false, false, 0, false);
            }

            BootEventBridge.Report("singleMapCallAttempted", "true");

            try
            {
                SingleMapProbeDelegate probe = Marshal.GetDelegateForFunctionPointer<SingleMapProbeDelegate>(page);
                uint result = probe();
                bool passed = result == expectedValue;

                BootEventBridge.Report("singleMapReturned", "true");
                BootEventBridge.Report("singleMapReturnValue", $"0x{result:X}");
                BootEventBridge.Report("singleMapPassed", passed.ToString());

                return (page, page, Array.Empty<byte>(), true, true, result, passed);
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunSingleMapControl call", ex);
                BootEventBridge.Report("singleMapReturned", "false");
                BootEventBridge.Report("singleMapPassed", "false");
                return (page, page, Array.Empty<byte>(), true, false, 0, false);
            }
        }
    }
}
