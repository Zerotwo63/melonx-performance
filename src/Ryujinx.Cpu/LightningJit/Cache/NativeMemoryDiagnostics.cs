using Ryujinx.Common.Logging;
using Ryujinx.Cpu.LightningJit.CodeGen;
using Ryujinx.Cpu.LightningJit.CodeGen.Arm64;
using Ryujinx.Memory;
using System;
using System.Runtime.InteropServices;
using System.Threading;

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

        // FASE 10B: a SECOND, independent Darwin query mechanism
        // (mach_vm_region_recurse, the API vmmap/task_info-style tools use
        // under the hood) to cross-check mach_vm_region's own answer -
        // never trusting a single query path when the whole point is to
        // find out whether protection reporting itself can be trusted.
        // Unlike mach_vm_region, this call takes no explicit "flavor" -
        // the kernel always fills a vm_region_submap_info_64 (the info/
        // infoCnt pair is purely an input capacity / output actual-size,
        // not a flavor selector). That struct's trailing fields have
        // grown across SDK revisions, but its FIRST TWO fields -
        // protection, max_protection - are each a stable 4-byte vm_prot_t
        // at offset 0/4 in every revision that has ever shipped (same
        // guarantee already relied on for VM_REGION_BASIC_INFO_64 above),
        // so over-provisioning the buffer/count comfortably larger than
        // any known revision and reading only offset 0/4 avoids needing
        // the exact trailing layout to be right.
        [DllImport("libc")]
        private static extern int mach_vm_region_recurse(
            ulong target_task,
            ref ulong address,
            ref ulong size,
            ref uint nestingDepth,
            byte[] info,
            ref uint infoCnt);

        [LibraryImport("libc", EntryPoint = "sys_dcache_flush", SetLastError = true)]
        private static partial void SysDcacheFlush(IntPtr start, IntPtr len);

        [DllImport("libc", EntryPoint = "sysctlbyname", SetLastError = true)]
        private static extern int SysctlByName(string name, ref int oldValue, ref nuint oldLenP, IntPtr newValue, nuint newLen);

        [DllImport("libc")]
        private static extern IntPtr dlsym(IntPtr handle, string symbol);

        private static readonly IntPtr RtldDefault = new(-2); // RTLD_DEFAULT

        /// <summary>
        /// Diagnóstico real #9 (FASE 9A, bug real encontrado): translates
        /// vm_prot_t bits into "READ+WRITE+EXECUTE" (or "NONE"). Previously
        /// joined with "," - but the caller embeds this string as one VALUE
        /// inside a comma-separated "key=value,key=value" payload, so a
        /// multi-flag protection value (e.g. "READ,WRITE") got truncated at
        /// its OWN internal comma by the naive split-on-comma parser on the
        /// Swift side, which is why "current=READ,WRITE" was read back as
        /// just "READ". "+" never collides with the outer payload format.
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
            return string.Join("+", parts);
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
        /// <summary>
        /// Diagnóstico real #9: this device is an Apple A19 Pro (confirmed
        /// from the physical-device name reported earlier this session) -
        /// Apple's newest SoCs ship with a Trusted Execution Monitor (TXM)
        /// that, per this fork's OWN existing code
        /// (DualMappedJitAllocator.hasTXM / BreakGetJITMapping /
        /// BreakpointJIT.framework), requires a separate, already-
        /// established workaround to get genuinely EXECUTABLE memory -
        /// plain mmap+mprotect reporting success is not sufficient proof
        /// that TXM actually blessed the page for execution. This logs
        /// both the env var the Swift side sets AND the real file-presence
        /// check so we have a cross-check instead of a guess:
        /// RunSingleMapControl's plain mmap/mprotect path never goes
        /// through BreakGetJITMapping at all, so if TXM enforcement is
        /// what's blocking execution, THIS test hanging while
        /// hasTXMEnvVar=true/hasTXMDetected=true would be direct,
        /// corroborating evidence - not proof by itself, but a real signal
        /// worth comparing against the dual-mapped probe's own result
        /// (which DOES go through BreakGetJITMapping when hasTXM is true).
        /// </summary>
        public static void ReportTxmStatus()
        {
            try
            {
                string envVar = Environment.GetEnvironmentVariable("HAS_TXM") ?? "unset";
                bool detected = DualMappedJitAllocator.hasTXM;

                BootEventBridge.Report("hasTXMEnvVar", envVar);
                BootEventBridge.Report("hasTXMDetected", detected.ToString());
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.ReportTxmStatus", ex);
            }
        }

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
        /// FASE 9C: allocates one page via plain mmap(MAP_ANON|MAP_PRIVATE,
        /// PROT_READ|PROT_WRITE), writes <paramref name="code"/>, queries
        /// its REAL protection via mach_vm_region BEFORE mprotect (should
        /// be RW, not yet RX), calls mprotect(PROT_READ|PROT_EXEC),
        /// reports the real mprotect() return code AND errno (never
        /// assuming success), queries protection again AFTER (should now
        /// show EXECUTE - confirmed via the kernel's own VM bookkeeping,
        /// not assumed from mprotect's return value), then does an
        /// explicit sys_icache_invalidate on the EXEC address specifically
        /// (there is no separate RW alias here - exec IS rw here, by
        /// design, unlike the dual-mapped case) before reading the bytes
        /// back once more. Returns IntPtr.Zero on failure.
        /// </summary>
        private static (IntPtr page, bool actualExecutePermission, bool protectionQueryDisagreement) AllocateAndMapSingle(byte[] code, string label)
        {
            // FASE 9C asked for the primary ("Plain") test's fields using
            // the EXACT bare names (e.g. "singleMapCurrentProtectionBefore",
            // no "Plain" infix). The "Bti" and "StageProbe" variants are
            // additions beyond the literal FASE 9C/9D/9H spec, so they keep
            // a distinguishing suffix to avoid colliding with each other.
            string suffix = label == "Plain" ? "" : label;
            void ReportBoth(string bareName, string value) => BootEventBridge.Report($"singleMap{suffix}{bareName}", value);

            UIntPtr pageSize = (UIntPtr)Environment.SystemPageSize;
            ReportBoth("AllocationAPI", "mmap");
            ReportBoth("MmapFlags", "MAP_ANON|MAP_PRIVATE,PROT_READ|PROT_WRITE");

            IntPtr page = mmap(IntPtr.Zero, pageSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);

            if (page == MapFailed)
            {
                BootEventBridge.ReportFail($"NativeMemoryDiagnostics.AllocateAndMapSingle {label} mmap", new Exception($"mmap failed, errno={Marshal.GetLastWin32Error()}"));
                return (IntPtr.Zero, false, false);
            }

            Marshal.Copy(code, 0, page, code.Length);

            var before = QueryProtectionRaw(page);
            ReportBoth("CurrentProtectionBefore", before.HasValue ? DescribeProtection(before.Value.current) : "unknown");
            ReportBoth("MaxProtectionBefore", before.HasValue ? DescribeProtection(before.Value.max) : "unknown");

            // FASE 10A: register the EXACT flags sent to the syscall - not
            // deduced afterwards from what we meant to send. If a future
            // edit accidentally changes this to PROT_READ alone, this
            // field catches it directly instead of only showing up as a
            // downstream "not executable" symptom.
            const int requestedProt = PROT_READ | PROT_EXEC;
            ReportBoth("MprotectAddress", $"0x{page:X}");
            ReportBoth("MprotectLength", pageSize.ToString());
            ReportBoth("MprotectRequestedProtNumeric", requestedProt.ToString());
            ReportBoth("MprotectRequestedRead", ((requestedProt & PROT_READ) != 0).ToString());
            ReportBoth("MprotectRequestedWrite", ((requestedProt & PROT_WRITE) != 0).ToString());
            ReportBoth("MprotectRequestedExecute", ((requestedProt & PROT_EXEC) != 0).ToString());

            int protectResult = mprotect(page, pageSize, requestedProt);
            int protectErrno = protectResult != 0 ? Marshal.GetLastWin32Error() : 0;
            ReportBoth("MprotectResult", protectResult.ToString());
            ReportBoth("MprotectErrno", protectErrno.ToString());

            if (protectResult != 0)
            {
                BootEventBridge.ReportFail($"NativeMemoryDiagnostics.AllocateAndMapSingle {label} mprotect", new Exception($"mprotect failed, errno={protectErrno}"));
                return (IntPtr.Zero, false, false);
            }

            // THE important check per this round: confirm via the kernel's
            // own VM bookkeeping that EXECUTE is really set now - never
            // assumed just because mprotect() returned 0.
            var after = QueryProtectionRaw(page);
            ReportBoth("CurrentProtectionAfter", after.HasValue ? DescribeProtection(after.Value.current) : "unknown");
            ReportBoth("MaxProtectionAfter", after.HasValue ? DescribeProtection(after.Value.max) : "unknown");

            // FASE 10B: cross-check mach_vm_region's answer against a
            // SECOND, independent Darwin query (mach_vm_region_recurse).
            // If the two mechanisms disagree, the query itself cannot be
            // trusted, so treat the page as non-executable rather than
            // believing whichever answer happens to say EXECUTE.
            var afterRecurse = QueryProtectionViaRecurse(page);
            ReportBoth("MachCurrentProtectionNumeric", after.HasValue ? after.Value.current.ToString() : "unknown");
            ReportBoth("MachMaxProtectionNumeric", after.HasValue ? after.Value.max.ToString() : "unknown");

            bool basicR = after.HasValue && (after.Value.current & VM_PROT_READ) != 0;
            bool basicW = after.HasValue && (after.Value.current & VM_PROT_WRITE) != 0;
            bool basicX = after.HasValue && (after.Value.current & VM_PROT_EXECUTE) != 0;
            ReportBoth("MachCurrentR", basicR.ToString());
            ReportBoth("MachCurrentW", basicW.ToString());
            ReportBoth("MachCurrentX", basicX.ToString());

            bool recurseQueryFailed = !afterRecurse.HasValue;
            ReportBoth("MachRecurseQueryFailed", recurseQueryFailed.ToString());

            bool disagreement = after.HasValue && afterRecurse.HasValue && after.Value.current != afterRecurse.Value.current;
            ReportBoth("ProtectionQueryDisagreement", disagreement.ToString());
            if (disagreement)
            {
                BootEventBridge.Report(
                    $"NativeMemoryDiagnostics.AllocateAndMapSingle {label} protection query disagreement",
                    $"mach_vm_region={DescribeProtection(after.Value.current)},mach_vm_region_recurse={DescribeProtection(afterRecurse.Value.current)}");
            }

            // Conservative by design: if the two independent query
            // mechanisms disagree, neither answer is trustworthy, so treat
            // the page as non-executable (and let the FASE 10F
            // classification surface PROTECTION_QUERY_BUG) rather than
            // trusting whichever one happened to say EXECUTE.
            bool actualExecutePermission = basicX && !disagreement;
            ReportBoth("ActualExecutePermission", actualExecutePermission.ToString());

            ReportBoth("DcacheFlushAttempted", "true");
            try { SysDcacheFlush(page, (IntPtr)code.Length); }
            catch (Exception ex) { BootEventBridge.ReportFail($"NativeMemoryDiagnostics.AllocateAndMapSingle {label} dcache flush", ex); }

            ReportBoth("IcacheInvalidateAttempted", "true");
            bool cacheSyncOk = true;
            try { JitSupportDarwin.SysIcacheInvalidate(page, (IntPtr)code.Length); }
            catch (Exception ex) { cacheSyncOk = false; BootEventBridge.ReportFail($"NativeMemoryDiagnostics.AllocateAndMapSingle {label} icache invalidate", ex); }
            ReportBoth("CacheSyncCompleted", cacheSyncOk.ToString());

            byte[] bytesReadBack = new byte[code.Length];
            Marshal.Copy(page, bytesReadBack, 0, code.Length);

            ReportBoth("RwAddress", $"0x{page:X}");
            ReportBoth("ExecAddress", $"0x{page:X}");
            ReportBoth("BytesReadBack", Convert.ToHexString(bytesReadBack));

            return (page, actualExecutePermission, disagreement);
        }

        /// <summary>
        /// Same mach_vm_region query as <see cref="QueryProtection"/>, but
        /// returns the raw (current, max) vm_prot_t bits without logging -
        /// used internally by AllocateAndMapSingle, which needs its own
        /// field names (singleMap*Before/After) rather than the generic
        /// "NativeMemoryDiagnostics.QueryProtection RW/RX" event FASE 8B uses.
        /// </summary>
        private static (int current, int max)? QueryProtectionRaw(IntPtr address)
        {
            try
            {
                ulong addr = (ulong)address;
                ulong size = 0;
                byte[] info = new byte[64];
                uint count = VM_REGION_BASIC_INFO_COUNT_64;
                uint objectName = 0;

                int result = mach_vm_region(mach_task_self(), ref addr, ref size, VM_REGION_BASIC_INFO_64, info, ref count, ref objectName);
                if (result != 0)
                {
                    return null;
                }

                return (BitConverter.ToInt32(info, 0), BitConverter.ToInt32(info, 4));
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// FASE 10B: see the doc comment on the mach_vm_region_recurse
        /// P/Invoke declaration above for why this is a safe, independent
        /// cross-check despite the exact struct size not being pinned
        /// down. Returns null (reported) if the recurse call itself
        /// fails - a clean failure here is itself useful information
        /// (never silently treated as "protection unknown == not
        /// executable" vs "protection unknown == query itself broken").
        /// </summary>
        private static (int current, int max)? QueryProtectionViaRecurse(IntPtr address)
        {
            try
            {
                ulong addr = (ulong)address;
                ulong size = 0;
                uint nestingDepth = 0;
                byte[] info = new byte[256]; // 64 natural_t words - see P/Invoke doc comment
                uint infoCnt = 64;

                int result = mach_vm_region_recurse(mach_task_self(), ref addr, ref size, ref nestingDepth, info, ref infoCnt);
                if (result != 0)
                {
                    BootEventBridge.Report("NativeMemoryDiagnostics.QueryProtectionViaRecurse failed", $"krReturn={result}");
                    return null;
                }

                return (BitConverter.ToInt32(info, 0), BitConverter.ToInt32(info, 4));
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.QueryProtectionViaRecurse", ex);
                return null;
            }
        }

        /// <summary>
        /// FASE 8E/9C: single-mapping control, Test A ("plain") - the SAME
        /// 8 bytes, written and executed from the SAME single virtual
        /// address (classic mmap RW -> write -> mprotect RX -> icache
        /// invalidate -> call), with NO dual-alias remap involved at all.
        /// Uses the same Marshal.GetDelegateForFunctionPointer call
        /// mechanism as SameMapProbe. Pages are allocated and never freed
        /// (diagnostic only, one-time, negligible) to avoid any risk of
        /// unmapping memory that might still be referenced.
        /// </summary>
        public static (IntPtr rwAddress, IntPtr execAddress, byte[] bytesReadBack, bool callAttempted, bool returned, uint returnValue, bool passed, bool executable, bool protectionQueryDisagreement) RunSingleMapControl(byte[] code, uint expectedValue)
        {
            (IntPtr page, bool executable, bool disagreement) = AllocateAndMapSingle(code, "Plain");

            if (page == IntPtr.Zero)
            {
                BootEventBridge.Report("singleMapPlainAttempted", "false");
                BootEventBridge.Report("singleMapCallAttempted", "false");
                return (IntPtr.Zero, IntPtr.Zero, Array.Empty<byte>(), false, false, 0, false, false, disagreement);
            }

            BootEventBridge.Report("singleMapPlainAttempted", "true");

            // FASE 10C: never issue the call unless the cross-checked
            // protection query actually confirms EXECUTE - this is exactly
            // what used to leave the diagnostic itself hanging forever
            // when the page turned out to be READ-only despite mprotect()
            // reporting success.
            if (!executable)
            {
                BootEventBridge.Report("singleMapCallSkippedBecauseNotExecutable", "true");
                BootEventBridge.Report("singleMapCallAttempted", "false");
                BootEventBridge.Report("singleMapPlainReturned", "false");
                BootEventBridge.Report("singleMapReturned", "false");
                return (page, page, Array.Empty<byte>(), false, false, 0, false, false, disagreement);
            }

            BootEventBridge.Report("singleMapCallSkippedBecauseNotExecutable", "false");
            BootEventBridge.Report("singleMapCallAttempted", "true");

            try
            {
                SingleMapProbeDelegate probe = Marshal.GetDelegateForFunctionPointer<SingleMapProbeDelegate>(page);
                uint result = probe();
                bool passed = result == expectedValue;

                BootEventBridge.Report("singleMapPlainReturned", "true");
                BootEventBridge.Report("singleMapReturned", "true");
                BootEventBridge.Report("singleMapReturnValue", $"0x{result:X}");
                BootEventBridge.Report("singleMapPassed", passed.ToString());

                return (page, page, Array.Empty<byte>(), true, true, result, passed, true, disagreement);
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunSingleMapControl call", ex);
                BootEventBridge.Report("singleMapPlainReturned", "false");
                BootEventBridge.Report("singleMapReturned", "false");
                BootEventBridge.Report("singleMapPassed", "false");
                return (page, page, Array.Empty<byte>(), true, false, 0, false, true, disagreement);
            }
        }

        private static Operand Reg(int register, OperandType type = OperandType.I64) => new(register, RegisterType.Integer, type);

        /// <summary>
        /// FASE 9D: Test B - `bti c; mov w0,#0x5678; ret`, mapped/called
        /// through the exact same AllocateAndMapSingle path as Test A
        /// (plain). BTI C encoding verified by hand from the ARMv8-A HINT
        /// instruction bit layout (not copied from memory unchecked):
        /// HINT #imm encodes as bits[31:12]=0xD5032, bits[11:8]=CRm,
        /// bits[7:5]=op2, bits[4:0]=0b11111. BTI variants use CRm=0b0100
        /// (4); "C" (allows indirect calls, i.e. BLR/BLRAx landing pads)
        /// is op2=0b010 (2) -> hint number 4*8+2=34. Assembling bit-by-bit:
        /// [31:28]=1101 [27:24]=0101 [23:20]=0000 [19:16]=0011 [15:12]=0010
        /// [11:8]=0100(CRm) [7:4]={op2=010,bit4 of the trailing 11111}=0101
        /// [3:0]=1111(rest of 11111) -> 0xD5 03 24 5F = 0xD503245F.
        /// If Test B succeeds while Test A does not, that is direct
        /// evidence of a BTI landing-pad requirement on indirect branches
        /// into JIT memory on this device/OS.
        /// </summary>
        public static (bool attempted, bool returned, uint returnValue, bool passed) RunSingleMapBtiControl(uint expectedValue)
        {
            const uint BtiC = 0xD503245F;

            CodeWriter writer = new();
            writer.WriteInstruction(BtiC);

            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                Assembler asm = new(writer);
                asm.Mov(Reg(0, OperandType.I32), unchecked((int)expectedValue));
                asm.Ret();
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            byte[] code = writer.AsByteSpan().ToArray();
            (IntPtr page, bool executable, _) = AllocateAndMapSingle(code, "Bti");

            if (page == IntPtr.Zero)
            {
                BootEventBridge.Report("singleMapBtiAttempted", "false");
                BootEventBridge.Report("btiCallAttempted", "false");
                return (false, false, 0, false);
            }

            BootEventBridge.Report("singleMapBtiAttempted", "true");

            // FASE 10C/10E: same never-call-if-not-executable discipline
            // as the plain test, applied here too.
            if (!executable)
            {
                BootEventBridge.Report("singleMapBtiCallSkippedBecauseNotExecutable", "true");
                BootEventBridge.Report("singleMapBtiReturned", "false");
                BootEventBridge.Report("btiCallAttempted", "false");
                return (true, false, 0, false);
            }

            BootEventBridge.Report("singleMapBtiCallSkippedBecauseNotExecutable", "false");
            BootEventBridge.Report("btiCallAttempted", "true");

            try
            {
                SingleMapProbeDelegate probe = Marshal.GetDelegateForFunctionPointer<SingleMapProbeDelegate>(page);
                uint result = probe();
                bool passed = result == expectedValue;

                BootEventBridge.Report("singleMapBtiReturned", "true");
                BootEventBridge.Report("singleMapBtiReturnValue", $"0x{result:X}");
                BootEventBridge.Report("btiCallReturned", "true");
                BootEventBridge.Report("btiCallReturnValue", $"0x{result:X}");
                return (true, true, result, passed);
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunSingleMapBtiControl call", ex);
                BootEventBridge.Report("singleMapBtiReturned", "false");
                BootEventBridge.Report("btiCallReturned", "false");
                return (true, false, 0, false);
            }
        }

        private delegate uint RawBranchTrampolineDelegate();

        /// <summary>
        /// FASE 10D Test 1 ("raw branch shim"): the literal request was a
        /// natively-compiled Obj-C/C/C++ shim taking a raw uintptr_t and
        /// doing an unauthenticated BLR - confirmed infeasible in this
        /// environment (see RunSingleMapDeepDive's doc comment: the
        /// native .dylib in this repo is never rebuilt by the iOS CI, and
        /// there is no Mac/Xcode available locally either). This is the
        /// closest achievable equivalent with the tools actually
        /// available: a SECOND JIT-mapped page (the "trampoline") whose
        /// own generated code loads the FIRST JIT-mapped page's ("target")
        /// address as a plain 64-bit immediate (Assembler.Mov(Operand,
        /// ulong) - ordinary MOVZ/MOVK, no ptrauth instructions at all)
        /// and performs BLR to it directly. The outer call INTO the
        /// trampoline still goes through .NET's normal
        /// Marshal.GetDelegateForFunctionPointer/delegate-invoke ABI (same
        /// as every other test here), but the INNER branch from trampoline
        /// to target happens entirely inside already-executing JIT code,
        /// with zero CLR/ABI involvement for that specific jump - which is
        /// exactly the same shape of indirect call DispatchLoop itself
        /// needs to make between JIT-compiled guest functions. An entry
        /// marker (same 1-word native-memory-write pattern as
        /// EmitStageMarker) is written immediately on entering the
        /// trampoline, before the BLR, so "entered the trampoline but the
        /// BLR itself never came back" is distinguishable from "never
        /// even got into the trampoline".
        /// </summary>
        public static (bool attempted, bool entered, bool returned, uint returnValue) RunRawBranchTest(byte[] targetProbeCode)
        {
            (IntPtr targetPage, bool targetExecutable, _) = AllocateAndMapSingle(targetProbeCode, "RawTarget");

            if (targetPage == IntPtr.Zero || !targetExecutable)
            {
                BootEventBridge.Report("rawBranchAttempted", "false");
                BootEventBridge.Report("rawBranchSkippedReason", targetPage == IntPtr.Zero ? "target mapping failed" : "target page not confirmed executable");
                return (false, false, false, 0);
            }

            if (RuntimeInformation.ProcessArchitecture != Architecture.Arm64)
            {
                BootEventBridge.Report("rawBranchAttempted", "false");
                BootEventBridge.Report("rawBranchSkippedReason", "not arm64");
                return (false, false, false, 0);
            }

            IntPtr markers = Marshal.AllocHGlobal(4);
            Marshal.WriteInt32(markers, 0, 0);

            CodeWriter writer = new();
            Assembler asm = new(writer);
            EmitStageMarker(ref asm, markers, 0, 1);
            asm.Mov(Reg(0), (ulong)(long)targetPage);
            asm.Blr(Reg(0));
            asm.Ret();

            byte[] trampolineCode = writer.AsByteSpan().ToArray();
            (IntPtr trampolinePage, bool trampolineExecutable, _) = AllocateAndMapSingle(trampolineCode, "RawTrampoline");

            if (trampolinePage == IntPtr.Zero || !trampolineExecutable)
            {
                BootEventBridge.Report("rawBranchAttempted", "false");
                BootEventBridge.Report("rawBranchSkippedReason", trampolinePage == IntPtr.Zero ? "trampoline mapping failed" : "trampoline page not confirmed executable");
                Marshal.FreeHGlobal(markers);
                return (false, false, false, 0);
            }

            BootEventBridge.Report("rawBranchAttempted", "true");

            try
            {
                RawBranchTrampolineDelegate call = Marshal.GetDelegateForFunctionPointer<RawBranchTrampolineDelegate>(trampolinePage);
                uint result = call();
                bool entered = Marshal.ReadInt32(markers, 0) != 0;

                BootEventBridge.Report("rawBranchEntered", entered.ToString());
                BootEventBridge.Report("rawBranchReturned", "true");
                BootEventBridge.Report("rawBranchReturnValue", $"0x{result:X}");
                return (true, entered, true, result);
            }
            catch (Exception ex)
            {
                bool entered = Marshal.ReadInt32(markers, 0) != 0;
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunRawBranchTest call", ex);
                BootEventBridge.Report("rawBranchEntered", entered.ToString());
                BootEventBridge.Report("rawBranchReturned", "false");
                return (true, entered, false, 0);
            }
            finally
            {
                Marshal.FreeHGlobal(markers);
            }
        }

        /// <summary>
        /// FASE 10D Test 2 ("PAC function pointer"): the literal request
        /// was ptrauth_sign_unauthenticated + ptrauth_key_function_pointer
        /// + ptrauth_function_pointer_type_discriminator from &lt;ptrauth.h&gt;.
        /// Those are C/Clang compiler builtins with no C#/.NET equivalent -
        /// not something this managed code can call at all - and the one
        /// way to actually use them (a natively-compiled C/Obj-C shim) is
        /// confirmed infeasible in this repo's iOS CI (see
        /// RunSingleMapDeepDive's doc comment). The other option
        /// considered was hand-assembling the PACIA/PACIZA sign
        /// instructions directly, the same way BTI C was hand-derived
        /// last round - but PACIA/PACIZA live in the much more involved
        /// "Data-processing (1 source)" encoding group (multiple
        /// interacting opcode/key/zero-modifier fields), unlike BTI's
        /// single documented HINT-space immediate, and getting ONE bit
        /// wrong there is architecturally a silent-wrong-signature or a
        /// trap - either way indistinguishable from the open-ended "hang"
        /// this entire investigation exists to eliminate, with no signal/
        /// exception handler installed to catch it safely (FASE 9G was
        /// deferred for the identical reason). Rather than fabricate a
        /// result or risk reintroducing an unverifiable hang, this is
        /// reported as explicitly NOT attempted, with the reason on record.
        /// </summary>
        public static void ReportPacTestNotImplemented()
        {
            BootEventBridge.Report("pacCallAttempted", "false");
            BootEventBridge.Report("pacPointerRaw", "n/a");
            BootEventBridge.Report("pacPointerSigned", "n/a");
            BootEventBridge.Report("pacCallReturned", "false");
            BootEventBridge.Report(
                "pacCallSkippedReason",
                "ptrauth.h has no C#/.NET equivalent and requires a natively-compiled shim, which this repo's iOS CI does not build; hand-assembling PACIA/PACIZA was rejected for insufficient encoding-verification confidence (unlike BTI C's single documented HINT immediate)");
        }

        /// <summary>
        /// FASE 10F: folds every FASE 10A-10E signal collected this round
        /// into exactly one of the requested terminal classifications.
        /// Pure read of already-reported values plus the parameters
        /// passed in - no new measurement happens here.
        /// </summary>
        public static string ClassifySingleMapExecution(
            bool protectionQueryDisagreement,
            bool actualExecutePermission,
            bool callSkippedBecauseNotExecutable,
            bool rawBranchReturned,
            bool pacCallReturned,
            bool btiCallReturned)
        {
            string classification;

            if (protectionQueryDisagreement)
            {
                classification = "PROTECTION_QUERY_BUG";
            }
            else if (!actualExecutePermission || callSkippedBecauseNotExecutable)
            {
                classification = "NON_EXECUTABLE_MAPPING";
            }
            else if (rawBranchReturned)
            {
                classification = "RAW_EXECUTION_WORKS";
            }
            else if (pacCallReturned)
            {
                classification = "PAC_REQUIRED";
            }
            else if (btiCallReturned)
            {
                classification = "BTI_REQUIRED";
            }
            else
            {
                classification = "UNKNOWN_EXECUTION_FAILURE";
            }

            BootEventBridge.Report("classification", classification);
            return classification;
        }

        /// <summary>
        /// FASE 10 orchestrator: runs the Plain single-map control (10A-
        /// 10C instrumented), then - ONLY if that page was confirmed
        /// really executable - the raw-branch test (10D Test 1), the PAC
        /// not-implemented marker (10D Test 2), and finally the BTI test
        /// (10E, deliberately run LAST, never before the raw/PAC
        /// classification), then reports the FASE 10F classification.
        /// Replaces the previous round's three separate call sites
        /// (RunSingleMapControl / RunSingleMapBtiControl /
        /// RunSingleMapStageProbe) with a single, correctly-ordered entry
        /// point so TranslatorStubs.cs does not need to encode this
        /// ordering itself.
        ///
        /// Infeasibility note (applies to every "native shim" mention in
        /// this file): libarmeilleure-jitsupport.dylib / support.c exist
        /// in this repo but are referenced ONLY by
        /// distribution/macos/create_macos_build_*.sh - never by
        /// MeloNX.xcodeproj or the iOS CI workflow - so a real native C
        /// shim compiled fresh into the iOS IPA is not achievable without
        /// a Mac/Xcode, neither of which is available in this environment.
        /// </summary>
        public static void RunSingleMapDeepDive(byte[] code, uint expectedValue)
        {
            var plain = RunSingleMapControl(code, expectedValue);

            bool rawBranchReturned = false;
            bool btiCallReturned = false;

            if (plain.executable)
            {
                var raw = RunRawBranchTest(code);
                rawBranchReturned = raw.returned;

                ReportPacTestNotImplemented();

                // FASE 10E: BTI only after raw/PAC are classified, never before.
                var bti = RunSingleMapBtiControl(expectedValue);
                btiCallReturned = bti.returned;
            }
            else
            {
                // Still report the skip explicitly for each test this
                // round would otherwise have run, so the report never
                // shows blank/missing fields without an explanation.
                BootEventBridge.Report("rawBranchAttempted", "false");
                BootEventBridge.Report("rawBranchSkippedReason", "single-map plain page not confirmed executable");
                ReportPacTestNotImplemented();
                BootEventBridge.Report("singleMapBtiAttempted", "false");
                BootEventBridge.Report("btiCallAttempted", "false");
            }

            // singleMapProtectionQueryDisagreement / ActualExecutePermission
            // were already reported per-call (bare names, "Plain" label)
            // by AllocateAndMapSingle - re-use the same authoritative
            // values here, never by re-querying.
            ClassifySingleMapExecution(
                protectionQueryDisagreement: plain.protectionQueryDisagreement,
                actualExecutePermission: plain.executable,
                callSkippedBecauseNotExecutable: !plain.executable,
                rawBranchReturned: rawBranchReturned,
                pacCallReturned: false,
                btiCallReturned: btiCallReturned);

            // Only run the background stage-marker probe when the plain
            // page was confirmed executable - it is gated identically
            // inside RunSingleMapStageProbe itself (its own
            // AllocateAndMapSingle call re-checks independently), this
            // call site just avoids spawning threads for a page we
            // already know will be skipped.
            if (plain.executable)
            {
                RunSingleMapStageProbe();
            }
        }

        /// <summary>
        /// FASE 9H: a THIRD, separate variant (never mixed into Test A/B
        /// above) that writes known values into a small dedicated native
        /// memory block at entry and right before RET, using the exact
        /// same X16/X17-only scratch-register discipline as
        /// TranslatorStubs.EmitDiagMarker. Run on its own background
        /// thread (fire-and-forget) so a hang here is still observable
        /// (via a dedicated poller) without blocking the calling thread.
        /// 0 = never entered, 1 = entered but never reached the pre-RET
        /// marker, 2 = reached the pre-RET marker (RET itself, or the
        /// return path back to managed code, is what's left unverified).
        /// </summary>
        public static void RunSingleMapStageProbe()
        {
            IntPtr markers = Marshal.AllocHGlobal(8);
            Marshal.WriteInt32(markers, 0, 0);
            Marshal.WriteInt32(markers, 4, 0);

            CodeWriter writer = new();

            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                Assembler asm = new(writer);
                EmitStageMarker(ref asm, markers, 0, 1);
                EmitStageMarker(ref asm, markers, 4, 2);
                asm.Ret();
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            byte[] code = writer.AsByteSpan().ToArray();
            (IntPtr page, bool executable, _) = AllocateAndMapSingle(code, "StageProbe");

            if (page == IntPtr.Zero)
            {
                Marshal.FreeHGlobal(markers);
                return;
            }

            if (!executable)
            {
                BootEventBridge.Report("singleMapStageProbeCallSkippedBecauseNotExecutable", "true");
                Marshal.FreeHGlobal(markers);
                return;
            }

            Thread callThread = new(() =>
            {
                try
                {
                    BootEventBridge.Report("LightningJit.SingleMapStageProbe call begin", $"exec=0x{page:X}");
                    SingleMapProbeDelegate probe = Marshal.GetDelegateForFunctionPointer<SingleMapProbeDelegate>(page);
                    probe();
                    BootEventBridge.Report("LightningJit.SingleMapStageProbe call returned");
                }
                catch (Exception ex)
                {
                    BootEventBridge.ReportFail("LightningJit.SingleMapStageProbe call", ex);
                }
            })
            {
                IsBackground = true,
                Name = "LightningJit.SingleMapStageProbe",
            };
            callThread.Start();

            Thread pollThread = new(() =>
            {
                int lastEntry = -1, lastBeforeRet = -1;
                for (int i = 0; i < 50; i++)
                {
                    int entry = Marshal.ReadInt32(markers, 0);
                    int beforeRet = Marshal.ReadInt32(markers, 4);

                    if (entry != lastEntry)
                    {
                        BootEventBridge.Report("singleMapNativeEntryStage", entry.ToString());
                        lastEntry = entry;
                    }

                    if (beforeRet != lastBeforeRet)
                    {
                        BootEventBridge.Report("singleMapNativeBeforeRetStage", beforeRet.ToString());
                        lastBeforeRet = beforeRet;
                    }

                    if (beforeRet != 0)
                    {
                        break;
                    }

                    Thread.Sleep(200);
                }
            })
            {
                IsBackground = true,
                Name = "LightningJit.SingleMapStageProbe.Poll",
            };
            pollThread.Start();
        }

        /// <summary>
        /// Same X16/X17-only, nothing-else-touched discipline as
        /// TranslatorStubs.EmitDiagMarker - see that method's doc comment
        /// for why these two registers specifically are always safe to
        /// clobber (ARM64 IP0/IP1, never callee-saved under AAPCS64). This
        /// standalone probe function has no other live register state to
        /// preserve at all (no guest context, no arguments used), so no
        /// re-materialization is needed here, unlike the real DispatchLoop/
        /// DispatchStub call sites.
        /// </summary>
        private static void EmitStageMarker(ref Assembler asm, IntPtr markersBase, int offset, int value)
        {
            IntPtr addr = markersBase + offset;
            asm.Mov(Reg(16), (ulong)(long)addr);
            asm.Mov(Reg(17, OperandType.I32), value);
            asm.StrRiUn(Reg(17, OperandType.I32), Reg(16), 0);
        }
    }
}
