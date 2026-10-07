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
        private static IntPtr AllocateAndMapSingle(byte[] code, string label)
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
                return IntPtr.Zero;
            }

            Marshal.Copy(code, 0, page, code.Length);

            var before = QueryProtectionRaw(page);
            ReportBoth("CurrentProtectionBefore", before.HasValue ? DescribeProtection(before.Value.current) : "unknown");
            ReportBoth("MaxProtectionBefore", before.HasValue ? DescribeProtection(before.Value.max) : "unknown");

            int protectResult = mprotect(page, pageSize, PROT_READ | PROT_EXEC);
            int protectErrno = protectResult != 0 ? Marshal.GetLastWin32Error() : 0;
            ReportBoth("MprotectResult", protectResult.ToString());
            ReportBoth("MprotectErrno", protectErrno.ToString());

            if (protectResult != 0)
            {
                BootEventBridge.ReportFail($"NativeMemoryDiagnostics.AllocateAndMapSingle {label} mprotect", new Exception($"mprotect failed, errno={protectErrno}"));
                return IntPtr.Zero;
            }

            // THE important check per this round: confirm via the kernel's
            // own VM bookkeeping that EXECUTE is really set now - never
            // assumed just because mprotect() returned 0.
            var after = QueryProtectionRaw(page);
            ReportBoth("CurrentProtectionAfter", after.HasValue ? DescribeProtection(after.Value.current) : "unknown");
            ReportBoth("MaxProtectionAfter", after.HasValue ? DescribeProtection(after.Value.max) : "unknown");

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

            return page;
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
        /// FASE 8E/9C: single-mapping control, Test A ("plain") - the SAME
        /// 8 bytes, written and executed from the SAME single virtual
        /// address (classic mmap RW -> write -> mprotect RX -> icache
        /// invalidate -> call), with NO dual-alias remap involved at all.
        /// Uses the same Marshal.GetDelegateForFunctionPointer call
        /// mechanism as SameMapProbe. Pages are allocated and never freed
        /// (diagnostic only, one-time, negligible) to avoid any risk of
        /// unmapping memory that might still be referenced.
        /// </summary>
        public static (IntPtr rwAddress, IntPtr execAddress, byte[] bytesReadBack, bool callAttempted, bool returned, uint returnValue, bool passed) RunSingleMapControl(byte[] code, uint expectedValue)
        {
            IntPtr page = AllocateAndMapSingle(code, "Plain");

            if (page == IntPtr.Zero)
            {
                BootEventBridge.Report("singleMapPlainAttempted", "false");
                BootEventBridge.Report("singleMapCallAttempted", "false");
                return (IntPtr.Zero, IntPtr.Zero, Array.Empty<byte>(), false, false, 0, false);
            }

            BootEventBridge.Report("singleMapPlainAttempted", "true");
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

                return (page, page, Array.Empty<byte>(), true, true, result, passed);
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunSingleMapControl call", ex);
                BootEventBridge.Report("singleMapPlainReturned", "false");
                BootEventBridge.Report("singleMapReturned", "false");
                BootEventBridge.Report("singleMapPassed", "false");
                return (page, page, Array.Empty<byte>(), true, false, 0, false);
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
            IntPtr page = AllocateAndMapSingle(code, "Bti");

            if (page == IntPtr.Zero)
            {
                BootEventBridge.Report("singleMapBtiAttempted", "false");
                return (false, false, 0, false);
            }

            BootEventBridge.Report("singleMapBtiAttempted", "true");

            try
            {
                SingleMapProbeDelegate probe = Marshal.GetDelegateForFunctionPointer<SingleMapProbeDelegate>(page);
                uint result = probe();
                bool passed = result == expectedValue;

                BootEventBridge.Report("singleMapBtiReturned", "true");
                BootEventBridge.Report("singleMapBtiReturnValue", $"0x{result:X}");
                return (true, true, result, passed);
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("NativeMemoryDiagnostics.RunSingleMapBtiControl call", ex);
                BootEventBridge.Report("singleMapBtiReturned", "false");
                return (true, false, 0, false);
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
            IntPtr page = AllocateAndMapSingle(code, "StageProbe");

            if (page == IntPtr.Zero)
            {
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
