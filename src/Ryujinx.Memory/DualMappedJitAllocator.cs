using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using Ryujinx.Common.Logging;

namespace Ryujinx.Memory
{
    /// <summary>
    /// JIT26 (StikDebug/StikJIT universal breakpoint protocol): tri-state,
    /// mirroring Swift's TXMStatus exactly - "Unknown" is NOT "NotPresent".
    /// An unset/unrecognized HAS_TXM value (e.g. the env var never reaching
    /// this process at all) is also Unknown, never silently treated as
    /// NotPresent.
    /// </summary>
    public enum TxmStatus
    {
        NotPresent,
        Present,
        Unknown,
    }

    /// <summary>
    /// Thrown by <see cref="DualMappedJitAllocator"/> when the JIT26
    /// protocol is required (TxmStatus != NotPresent) but this process is
    /// not currently under CS_DEBUGGED - calling BreakGetJITMapping in that
    /// state would just hit MeloNX's own SIGTRAP-neutralizing handler
    /// (JIT26BreakpointHandler, installed specifically so an unattached brk
    /// does not crash the process) and return a null/garbage pointer. This
    /// distinct exception type lets callers tell "protocol not ready yet -
    /// retry once a debugger attaches" apart from "protocol attempted and
    /// genuinely failed".
    /// </summary>
    public class Jit26NotReadyException : Exception
    {
        public Jit26NotReadyException(string message) : base(message) { }
    }

    /// <summary>
    /// Class for JIT memory allocation on iOS.
    /// Intended to allocate memory with both r/x and r/w permissions,
    /// as a workaround for stricter W^X (Write XOR Execute) enforcement introduced in iOS 26.
    ///
    /// Specifically targets iOS 26, where the traditional method of reprotecting
    /// memory from writable to executable (RX) no longer works for JIT code.
    /// </summary>
    public class DualMappedJitAllocator : IDisposable
    {

        public IntPtr RwPtr { get; private set; }
        public IntPtr RxPtr { get; private set; }
        public ulong Size { get; private set; }

        [DllImport("BreakpointJIT.framework/BreakpointJIT", EntryPoint = "BreakGetJITMapping")]
        public static extern unsafe byte* BreakGetJITMappingPub(byte* addr, nuint bytes);

        [DllImport("BreakpointJIT.framework/BreakpointJIT", EntryPoint = "BreakMarkJITMapping")]
        public static extern unsafe byte* BreakMarkJITMapping(nuint bytes);

        [DllImport("BreakpointJIT.framework/BreakpointJIT", EntryPoint = "BreakJITDetach")]
        public static extern unsafe void BreakJITDetach();

        /// <summary>
        /// Parses the exact 3-value string MeloNXApp.swift's
        /// initializeEmulatorRuntime() sets ("1"/"0"/"unknown") - see
        /// TXMStatus's doc comment in IsJITEnabled.swift for why "unknown"
        /// must never collapse to NotPresent here either.
        /// </summary>
        public static TxmStatus TxmPresence
        {
            get
            {
                string value = Environment.GetEnvironmentVariable("HAS_TXM");
                return value switch
                {
                    "1" => TxmStatus.Present,
                    "0" => TxmStatus.NotPresent,
                    _ => TxmStatus.Unknown,
                };
            }
        }

        /// <summary>
        /// Compatibility shim for every existing `if (hasTXM)` call site in
        /// this codebase (AllocateDualMapping below, MemoryBlock.Detach,
        /// DualMappedNoWxCache's cache sizing) - Unknown collapses to true
        /// so the JIT26-protocol-compatible path is the SAFE default on
        /// iOS 26+ whenever TXM presence cannot be disproven, per this
        /// round's explicit requirement. This is the one place that
        /// decision is made; every other reader of this property inherits
        /// it automatically.
        /// </summary>
        static public bool hasTXM => TxmPresence != TxmStatus.NotPresent;

        // ---- CS_DEBUGGED (JIT26): same mechanism as Swift's
        // checkDebugged() in IsJITEnabled.swift (csops(pid, CS_OPS_STATUS,
        // &flags, sizeof(flags)), then flags & CS_DEBUGGED) - duplicated
        // here rather than called cross-language so this C# library has no
        // new dependency on Swift/Obj-C interop for a single syscall. ----
        private const int CS_OPS_STATUS = 0;
        private const int CS_DEBUGGED = 0x10000000;

        [DllImport("libc", SetLastError = true)]
        private static extern int csops(int pid, int ops, ref int useraddr, nuint usersize);

        [DllImport("libc")]
        private static extern int getpid();

        public static bool IsCsDebugged()
        {
            int flags = 0;
            int result = csops(getpid(), CS_OPS_STATUS, ref flags, (nuint)sizeof(int));
            return result == 0 && (flags & CS_DEBUGGED) != 0;
        }

        // Additive diagnostics counters only - do not affect allocation
        // behavior. Reported directly via BootEventBridge below, consumed
        // by BootDiagnostics.swift's JIT26 PROTOCOL report section.
        private static int s_regionIndex;
        public static int PrepareCalls;
        public static int PrepareSuccesses;

        private IntPtr _mmapPtr;

        public DualMappedJitAllocator(ulong size)
        {
            var stackTrace = new StackTrace(1, false); // Skip *this* frame
            var callingMethod = stackTrace.GetFrame(0)?.GetMethod();

            Logger.Info?.Print(LogClass.Cpu,
                $"Allocating dual-mapped JIT memory of size {size} bytes, called by {callingMethod?.DeclaringType?.FullName}.{callingMethod?.Name}");
            Size = size;
            AllocateDualMapping();
        }

        IntPtr BreakGetJITMapping(nuint bytes)
        {
            unsafe
            {
                byte* ptr = BreakMarkJITMapping(bytes);
                Logger.Info?.Print(LogClass.Cpu, $"testing for BreakGetJITMapping, got {(ulong)ptr}");
                if (ptr == null || ptr == (byte*)0 || ptr == (byte*)-1 || ptr == (byte*)14757395257293275360 || ptr == (byte*)1761607904)
                {
                    ptr = BreakGetJITMappingPub(null, bytes);
                    Logger.Info?.Print(LogClass.Cpu, $"testing for BreakGetJITMapping Again, got {(ulong)ptr}");
                    if (ptr == null || ptr == (byte*)0 || ptr == (byte*)-1)
                    {
                        Logger.Info?.Print(LogClass.Cpu, "Failed to get JIT mapping from BreakGetJITMapping.");
                        throw new Exception("Failed to get JIT, Are you using StikDebug and Picture in Picture is enabled?");
                    }
                }

                return (IntPtr)ptr;
            }
        }

        private void AllocateDualMapping()
        {
            IntPtr _mmapPtr;

            int regionIndex = System.Threading.Interlocked.Increment(ref s_regionIndex);
            TxmStatus txmPresence = TxmPresence;
            BootEventBridge.Report("jit26ProtocolRequired", (txmPresence != TxmStatus.NotPresent).ToString());

            if (hasTXM)
            {
                bool csDebugged = IsCsDebugged();
                BootEventBridge.Report("csDebugged", csDebugged.ToString());
                System.Threading.Interlocked.Increment(ref PrepareCalls);
                BootEventBridge.Report("jit26PrepareCalls", PrepareCalls.ToString());
                BootEventBridge.Report("jit26RegionIndex", regionIndex.ToString());
                BootEventBridge.Report("jit26RegionOriginalAddress", "0x0");
                BootEventBridge.Report("jit26RegionLength", Size.ToString());

                if (!csDebugged)
                {
                    // Never execute the brk unless something is actually
                    // attached to service it - this is a graceful,
                    // distinctly-typed failure a caller can retry on
                    // (JITCoordinator's poll loop already re-invokes this
                    // whole path every ~0.5s via isJITEnabled() ->
                    // initialize_dualmapped(), so the very next poll after
                    // a debugger attaches retries automatically).
                    BootEventBridge.Report("jit26RegionPrepareReturned", "false");
                    throw new Jit26NotReadyException(
                        "TXM/SPTM protocol required (TxmPresence != NotPresent) but this process is not under CS_DEBUGGED yet - refusing to execute the JIT26 breakpoint until a debugger/script is attached.");
                }

                BootEventBridge.Report("jit26ScriptConnected", "true");

                _mmapPtr = BreakGetJITMapping((nuint)Size);

                System.Threading.Interlocked.Increment(ref PrepareSuccesses);
                BootEventBridge.Report("jit26PrepareSuccesses", PrepareSuccesses.ToString());
                BootEventBridge.Report("jit26RegionPreparedAddress", $"0x{(ulong)_mmapPtr:X}");
                BootEventBridge.Report("jit26RegionPrepareReturned", "true");
            }
            else
            {
                BootEventBridge.Report("csDebugged", IsCsDebugged().ToString());
                _mmapPtr = mmap(IntPtr.Zero, (UIntPtr)Size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);

                if (_mmapPtr == MAP_FAILED)
                    throw new Exception("Failed to mmap memory");
            }

            var bufRX = (ulong)_mmapPtr;
            ulong bufRW = 0;
            uint curProt = 0, maxProt = 0;

            int remapResult = vm_remap(mach_task_self(), ref bufRW, Size, 0, VM_FLAGS_ANYWHERE,
                                      mach_task_self(), bufRX, 0, ref curProt, ref maxProt, VM_INHERIT_NONE);
            if (remapResult != KERN_SUCCESS)
                throw new Exception($"Failed to remap RX region: {remapResult}");

            int protectRWResult = vm_protect(mach_task_self(), bufRW, Size, 0, VM_PROT_READ | VM_PROT_WRITE);
            if (protectRWResult != KERN_SUCCESS)
                throw new Exception($"Failed to set RW protection: {protectRWResult}");

            RwPtr = (IntPtr)bufRW;
            RxPtr = (IntPtr)bufRX;
        }

        public void Dispose()
        {
            if (_mmapPtr != IntPtr.Zero)
            {
                munmap(_mmapPtr, (UIntPtr)Size);
                _mmapPtr = IntPtr.Zero;

                munmap(RwPtr, (UIntPtr)Size);
                RwPtr = IntPtr.Zero;
            }
        }

        private const int PROT_READ = 1;
        private const int PROT_EXEC = 4;
        private const int MAP_ANON = 0x1000;
        private const int MAP_PRIVATE = 0x2;
        private static readonly IntPtr MAP_FAILED = new IntPtr(-1);

        private const int VM_FLAGS_ANYWHERE = 1 << 0;
        private const int VM_INHERIT_NONE = 2;
        private const int KERN_SUCCESS = 0;
        private const int VM_PROT_READ = 1;
        private const int VM_PROT_WRITE = 2;

        [DllImport("libc", SetLastError = true)]
        private static extern IntPtr mmap(IntPtr addr, UIntPtr len, int prot, int flags, int fd, long offset);

        [DllImport("libc", SetLastError = true)]
        private static extern int munmap(IntPtr addr, UIntPtr len);

        [DllImport("libc")]
        private static extern ulong mach_task_self();

        [DllImport("libc")]
        private static extern int vm_remap(
            ulong target_task,
            ref ulong target_address,
            ulong size,
            ulong mask,
            int anywhere,
            ulong src_task,
            ulong src_address,
            int copy,
            ref uint cur_protection,
            ref uint max_protection,
            int inheritance
        );

        [DllImport("libc")]
        private static extern int vm_protect(
            ulong task,
            ulong address,
            ulong size,
            int set_maximum,
            int new_protection
        );
    }
}
