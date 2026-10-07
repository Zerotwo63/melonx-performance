using ARMeilleure.Common;
using ARMeilleure.Memory;
using Ryujinx.Cpu.Jit;
using Ryujinx.Cpu.LightningJit.Cache;
using Ryujinx.Cpu.LightningJit.CodeGen.Arm64;
using Ryujinx.Cpu.LightningJit.State;
using Ryujinx.Cpu.Signal;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using Ryujinx.Common.Logging;

namespace Ryujinx.Cpu.LightningJit
{
    public class DualMappedTranslator {
        public static bool InitializeDualMapped() {
            return Translator.InitializeDualMapped();
        }
    }

    class Translator : IDisposable
    {
        // Should be enabled on platforms that enforce W^X.
        private static bool IsNoWxPlatform => OperatingSystem.IsIOS();


        private static readonly AddressTable<ulong>.Level[] _levels64Bit =
            new AddressTable<ulong>.Level[]
            {
                new(31, 17),
                new(23,  8),
                new(15,  8),
                new( 7,  8),
                new( 2,  5),
            };

        private static readonly AddressTable<ulong>.Level[] _levels32Bit =
            new AddressTable<ulong>.Level[]
            {
                new(23, 9),
                new(15, 8),
                new( 7, 8),
                new( 1, 6),
            };

        private readonly ConcurrentQueue<KeyValuePair<ulong, TranslatedFunction>> _oldFuncs;
        private readonly NoWxCache _noWxCache;
        public DualMappedNoWxCache _dualMappedCache;
        private bool _disposed;

        // Additive diagnostics counters only - do not affect behavior.
        // This is the REAL active translator for this build (see
        // ArmProcessContextFactory: arm64 host + MemoryManagerMode.
        // HostMapped/HostMappedUnsafe selects LightningJitEngine, not the
        // classic ARMeilleure.Translation.Translator). A previous round's
        // instrumentation of that other class never fired on real device
        // traces because it isn't on this build's actual execution path.
        private int _lookupCount;
        private int _translationAttempts;
        private int _realFunctionsCompiled;
        private int _nopFallbacks;
        private int _jitMemEvents;
        private static int s_sameMapProbeRun;

        private static DualMappedNoWxCache originalDualMappedCache;
        private static bool firstSet = false;

        // Lifecycle instrumentation only (Start A -> Stop A -> Start B
        // without restarting MeloNX): a process-wide counter, one
        // "session" per Translator constructed/disposed - i.e. roughly
        // one per game started/stopped. Never reset.
        private static int s_sessionId;
        private int _sessionId;

        static internal TranslatorCache<TranslatedFunction> Functions { get; set; }
        internal AddressTable<ulong> FunctionTable { get; }
        static internal TranslatorStubs Stubs { get; set; }
        internal IMemoryManager Memory { get; }

        public Translator(IMemoryManager memory, bool for64Bits)
        {
            Memory = memory;

            _sessionId = System.Threading.Interlocked.Increment(ref s_sessionId);
            BootEventBridge.Report($"GAME SESSION {_sessionId} start");

            _oldFuncs = new ConcurrentQueue<KeyValuePair<ulong, TranslatedFunction>>();

            if (IsNoWxPlatform)
            {
                string dualMapped = Environment.GetEnvironmentVariable("DUAL_MAPPED_JIT");
                if (dualMapped == "1") //(OperatingSystem.IsIOSVersionAtLeast(19) || OperatingSystem.IsIOSVersionAtLeast(26))
                {
                    Console.WriteLine($"Dual Mapped JIT enabled.");
                    if (DualMappedJitAllocator.hasTXM)
                    {
                        if (originalDualMappedCache == null) {
                            originalDualMappedCache = new(new JitMemoryAllocator(), CreateStackWalker());
                            Functions = new TranslatorCache<TranslatedFunction>();
                        }
                        _dualMappedCache = originalDualMappedCache;
                        _dualMappedCache.SetTranslator(this);
                        FunctionTable = new AddressTable<ulong>(for64Bits ? _levels64Bit : _levels32Bit);
                        Stubs = new TranslatorStubs(FunctionTable, _dualMappedCache); 
                    } 
                    else
                    {
                        if (originalDualMappedCache != null && !firstSet)
                        {
                            _dualMappedCache = originalDualMappedCache;
                            firstSet = true;
                        } else
                        {
                            _dualMappedCache = new(new JitMemoryAllocator(), CreateStackWalker());
                        }
                        _dualMappedCache.SetTranslator(this);
                        Functions = new TranslatorCache<TranslatedFunction>();
                        FunctionTable = new AddressTable<ulong>(for64Bits ? _levels64Bit : _levels32Bit);
                        Stubs = new TranslatorStubs(FunctionTable, _dualMappedCache); 
                    }
                }
                else
                {
                    if (_dualMappedCache != null) {
                        _dualMappedCache = null;
                    }
                    _noWxCache = new(new JitMemoryAllocator(), CreateStackWalker(), this);
                    Functions = new TranslatorCache<TranslatedFunction>();
                    FunctionTable = new AddressTable<ulong>(for64Bits ? _levels64Bit : _levels32Bit);
                    Stubs = new TranslatorStubs(FunctionTable, _noWxCache);
                }
            }
            else
            {
                JitCache.Initialize(new JitMemoryAllocator(forJit: true));
                Functions = new TranslatorCache<TranslatedFunction>();
                FunctionTable = new AddressTable<ulong>(for64Bits ? _levels64Bit : _levels32Bit);
                Stubs = new TranslatorStubs(FunctionTable, (NoWxCache)null);
            }

            FunctionTable.Fill = (ulong)Stubs.SlowDispatchStub;

            if (memory.Type.IsHostMappedOrTracked())
            {
                NativeSignalHandler.InitializeSignalHandler();
            }

        }

        // NOTE (instrumentation only, logic unchanged): this returns true
        // whenever DUAL_MAPPED_JIT != "1" too, since the whole dual-mapped
        // setup is simply skipped in that case - a `true` here does NOT by
        // itself prove dual-mapped JIT is active, only that this function
        // didn't hit a construction exception. Real readiness still has to
        // come from isJITEnabled() on the Swift side.
        public static bool InitializeDualMapped() {
            Console.WriteLine("[BOOT] initialize_dualmapped entered");
            if (IsNoWxPlatform)
            {
                string dualMapped = Environment.GetEnvironmentVariable("DUAL_MAPPED_JIT");
                bool dualMappedEnabled = dualMapped == "1";
                Console.WriteLine($"[BOOT] DUAL_MAPPED_JIT enabled = {dualMappedEnabled}");
                if (dualMappedEnabled) //(OperatingSystem.IsIOSVersionAtLeast(19) || OperatingSystem.IsIOSVersionAtLeast(26))
                {
                    Console.WriteLine($"Dual Mapped JIT enabled.");
                    try {
                        if (originalDualMappedCache == null) {
                            originalDualMappedCache = new(new JitMemoryAllocator(), CreateStackWalker());
                            Functions = new TranslatorCache<TranslatedFunction>();
                        }
                    } catch (Exception ex) {
                        Console.WriteLine($"[BOOT] initialize_dualmapped returned = false (exception: {ex.Message})");
                        return false;
                    }

                    NativeSignalHandler.InitializeSignalHandler();

                }

            }
            else
            {
                Console.WriteLine("[BOOT] DUAL_MAPPED_JIT enabled = false (not a NoWx platform)");
            }

            Console.WriteLine("[BOOT] initialize_dualmapped returned = true");
            return true;
        }

        private static IStackWalker CreateStackWalker()
        {
            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                return new StackWalker();
            }
            else
            {
                throw new PlatformNotSupportedException();
            }
        }

        /// <summary>
        /// Diagnóstico real #7 (FASE 3): reports TranslatorStubs' native
        /// stage markers (written directly by generated ARM64 code, see
        /// TranslatorStubs.EmitDiagMarker) via the boot-event bridge
        /// whenever they change, while the real DispatchLoop call is in
        /// flight. Read-only, zero effect on the real dispatch - just a
        /// cheap periodic poll (3 int reads) from a background thread.
        /// </summary>
        private void PollDiagMarkers(CancellationToken token)
        {
            int lastDispatchLoop = -1, lastDispatchStub = -1, lastSlowDispatchStub = -1;

            while (!token.IsCancellationRequested)
            {
                int dispatchLoop = Stubs.DiagDispatchLoopStage;
                int dispatchStub = Stubs.DiagDispatchStubStage;
                int slowDispatchStub = Stubs.DiagSlowDispatchStubStage;

                if (dispatchLoop != lastDispatchLoop)
                {
                    BootEventBridge.Report("LightningJit.dispatchLoopNativeStage", dispatchLoop.ToString());
                    lastDispatchLoop = dispatchLoop;
                }

                if (dispatchStub != lastDispatchStub)
                {
                    BootEventBridge.Report("LightningJit.dispatchStubStage", dispatchStub.ToString());
                    lastDispatchStub = dispatchStub;
                }

                if (slowDispatchStub != lastSlowDispatchStub)
                {
                    BootEventBridge.Report("LightningJit.slowDispatchStubStage", slowDispatchStub.ToString());
                    lastSlowDispatchStub = slowDispatchStub;
                }

                token.WaitHandle.WaitOne(200);
            }
        }

        public void Execute(State.ExecutionContext context, ulong address)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            BootEventBridge.Report("LightningJit.Translator.Execute entered", $"pc=0x{address:X},threadId={Environment.CurrentManagedThreadId}");

            try
            {
                NativeInterface.RegisterThread(context, Memory, this);

                // NativeInterface.SetPageTablePointer();

                // Diagnóstico real #7 (FASE 2): run the same-map probe exactly
                // once (first guest thread only, across ALL Translator
                // instances - Stubs is shared static) before the real
                // DispatchLoop ever runs. Never skips or alters the real
                // dispatch below regardless of the probe's outcome - it is
                // purely informational.
                if (Interlocked.CompareExchange(ref s_sameMapProbeRun, 1, 0) == 0)
                {
                    try
                    {
                        Stubs.RunSameMapProbe();
                    }
                    catch (Exception ex)
                    {
                        BootEventBridge.ReportFail("LightningJit.SameMapProbe", ex);
                    }
                }

                BootEventBridge.Report("LightningJit.Translator.Execute before DispatchLoop", $"pc=0x{address:X}");

                // Diagnóstico real #7 (FASE 1): split what used to be a single
                // `Stubs.DispatchLoop(...)` expression into its real steps -
                // resolving the Lazy<DispatcherFunction> (which triggers native
                // ARM64 codegen for the dispatch loop/stub/slow-dispatch-stub on
                // first access, see TranslatorStubs.cs), obtaining its real raw
                // function pointer (for visibility only - the call below still
                // goes through the delegate, unchanged), and the call itself.
                BootEventBridge.Report("LightningJit.DispatchLoop resolve begin");
                DispatcherFunction dispatchLoopDelegate = Stubs.DispatchLoop;
                BootEventBridge.Report("LightningJit.DispatchLoop resolve end");

                IntPtr dispatchLoopPtr = Marshal.GetFunctionPointerForDelegate(dispatchLoopDelegate);
                BootEventBridge.Report("LightningJit.DispatchLoop pointer", $"0x{dispatchLoopPtr:X}");

                // Diagnóstico real #7 (FASE 6): safe to read Base/Fill now -
                // resolving Stubs.DispatchLoop just above already triggered
                // GenerateDispatchLoop/GenerateDispatchStub, which already
                // accessed _functionTable.Base/.Fill for real codegen - this
                // is a read of already-allocated state, not a new allocation.
                try
                {
                    Stubs.LogFunctionTableLookup(address);
                }
                catch (Exception ex)
                {
                    BootEventBridge.ReportFail("LightningJit.FunctionTable lookup", ex);
                }

                // Diagnóstico real #7 (FASE 4): OFF unless
                // LIGHTNINGJIT_DIAG_DIRECT_DISPATCH=1 is explicitly set (see
                // RunDirectDispatchProbe) - never runs in a normal boot.
                // framePointer=IntPtr.Zero here is a synthetic placeholder:
                // there is no real native stack frame at this call site
                // (unlike the real DispatchStub, which passes its actual
                // X29), since this call originates from plain managed code,
                // not from within generated dispatch code.
                try
                {
                    Stubs.RunDirectDispatchProbe(IntPtr.Zero, address);
                }
                catch (Exception ex)
                {
                    BootEventBridge.ReportFail("LightningJit.DirectDispatchProbe", ex);
                }

                // Diagnóstico real #7 (FASE 3): the stage markers above live
                // in plain native memory that the GENERATED ARM64 code
                // writes to directly - nothing manages pushes them into the
                // boot-event stream on its own. Poll them from a background
                // thread (cheap: 3 int reads every ~200ms) and report only
                // on change, so BootDiagnostics/the watchdog can show real
                // progress through DispatchLoop/DispatchStub/SlowDispatchStub
                // while the blocking call below is in flight.
                using CancellationTokenSource markerPollCts = new();
                Thread markerPollThread = new(() => PollDiagMarkers(markerPollCts.Token))
                {
                    IsBackground = true,
                    Name = "LightningJit.DiagMarkerPoll",
                };
                markerPollThread.Start();

                // This call blocks until the guest thread itself stops running
                // (same "runs forever on this thread" pattern as the render
                // loop) - CALL BEGIN appearing without CALL RETURNED is expected
                // while the guest keeps executing; what matters is confirming
                // control actually reached the call.
                BootEventBridge.Report("LightningJit.DispatchLoop CALL BEGIN", $"pc=0x{address:X}");
                try
                {
                    dispatchLoopDelegate(context.NativeContextPtr, address);
                }
                finally
                {
                    markerPollCts.Cancel();
                }
                BootEventBridge.Report("LightningJit.DispatchLoop CALL RETURNED", $"pc=0x{address:X}");

                BootEventBridge.Report("LightningJit.Translator.Execute after DispatchLoop", $"pc=0x{address:X}");

                NativeInterface.UnregisterThread();
                _noWxCache?.ClearEntireThreadLocalCache();
                _dualMappedCache?.ClearEntireThreadLocalCache();
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("LightningJit.Translator.Execute", ex);
                throw;
            }
        }


        internal IntPtr GetOrTranslatePointer(IntPtr framePointer, ulong address, ExecutionMode mode)
        {
            int lookupCount = Interlocked.Increment(ref _lookupCount);
            bool verbose = lookupCount <= 10 || lookupCount % 50 == 0;

            if (verbose)
            {
                BootEventBridge.Report("LightningJit translate lookup begin", $"pc=0x{address:X},count={lookupCount}");
            }

            int guestCodeLength = 0;
            try
            {
                if (_noWxCache != null)
                {
                    if (_noWxCache.TryGetThreadLocalFunction(address, out IntPtr funcPtr))
                    {
                        if (verbose)
                        {
                            BootEventBridge.Report("LightningJit translate lookup hit", $"pc=0x{address:X}");
                        }
                        return funcPtr;
                    }

                    int translationAttempts = Interlocked.Increment(ref _translationAttempts);
                    if (verbose)
                    {
                        BootEventBridge.Report("LightningJit translate begin", $"pc=0x{address:X},count={translationAttempts}");
                    }

                    CompiledFunction func = Compile(address, mode);
                    guestCodeLength = func.Code.Length;
                    int realFunctionsCompiled = Interlocked.Increment(ref _realFunctionsCompiled);
                    if (verbose)
                    {
                        BootEventBridge.Report("LightningJit translate compiled", $"pc=0x{address:X},hostCodeLength={func.Code.Length},count={realFunctionsCompiled}");
                    }

                    IntPtr mappedPtr = _noWxCache.Map(framePointer, func.Code, address, (ulong)func.GuestCodeLength);
                    if (verbose)
                    {
                        BootEventBridge.Report("LightningJit translate mapped", $"pc=0x{address:X},funcPtr=0x{mappedPtr:X}");
                    }
                    return mappedPtr;
                }
                else if (_dualMappedCache != null)
                {
                    if (_dualMappedCache.TryGetThreadLocalFunction(address, out IntPtr funcPtr))
                    {
                        if (verbose)
                        {
                            BootEventBridge.Report("LightningJit translate lookup hit", $"pc=0x{address:X}");
                        }
                        return funcPtr;
                    }

                    int translationAttempts = Interlocked.Increment(ref _translationAttempts);
                    if (verbose)
                    {
                        BootEventBridge.Report("LightningJit translate begin", $"pc=0x{address:X},count={translationAttempts}");
                    }

                    CompiledFunction func = Compile(address, mode);
                    guestCodeLength = func.Code.Length;
                    int realFunctionsCompiled = Interlocked.Increment(ref _realFunctionsCompiled);
                    if (verbose)
                    {
                        BootEventBridge.Report("LightningJit translate compiled", $"pc=0x{address:X},hostCodeLength={func.Code.Length},count={realFunctionsCompiled}");
                    }

                    IntPtr mappedPtr = _dualMappedCache.Map(framePointer, func.Code, address, (ulong)func.GuestCodeLength);
                    if (verbose)
                    {
                        BootEventBridge.Report("LightningJit translate mapped", $"pc=0x{address:X},funcPtr=0x{mappedPtr:X}");
                    }
                    return mappedPtr;
                }
            }
            catch (Exception ex)
            {
                // thank you @BXYMartin for helping with this diagnostic info.
                string dualMappedEnv = Environment.GetEnvironmentVariable("DUAL_MAPPED_JIT");
                string diagnosticInfo = $"GetOrTranslatePointer failed for address 0x{address:X16}:\n" +
                    $"  framePointer: 0x{framePointer:X}\n" +
                    $"  mode: {mode}\n" +
                    $"  IsNoWxPlatform: {IsNoWxPlatform}\n" +
                    $"  DUAL_MAPPED_JIT env: '{dualMappedEnv}'\n" +
                    $"  DualMappedJitAllocator.hasTXM: {DualMappedJitAllocator.hasTXM}\n" +
                    $"  _noWxCache: {(_noWxCache != null ? "NOT NULL" : "NULL")}\n" +
                    $"  _dualMappedCache: {(_dualMappedCache != null ? "NOT NULL" : "NULL")}\n" +
                    $"  originalDualMappedCache: {(originalDualMappedCache != null ? "NOT NULL" : "NULL")}\n" +
                    $"  firstSet: {firstSet}\n" +
                    $"  Exception: {ex.GetType().Name}: {ex.Message}\n" +
                    $"  Stack trace: {ex.StackTrace}";


                Logger.Info?.Print(LogClass.Cpu, diagnosticInfo);

                // Additive diagnostics only - the fallback behavior below
                // (return a synthetic NOP+RET "function" instead of
                // propagating) is unchanged and pre-existing. Without this,
                // a guest thread can look alive and keep "looking up"
                // addresses forever while never running any real
                // translated code, with zero trace in the boot report -
                // this makes that distinction visible.
                int nopFallbacks = Interlocked.Increment(ref _nopFallbacks);
                BootEventBridge.ReportFail("LightningJit.GetOrTranslatePointer", ex);
                BootEventBridge.Report("LightningJit translate NOP fallback", $"pc=0x{address:X},exceptionType={ex.GetType().FullName},count={nopFallbacks}");

                int nopLength = guestCodeLength > 0 ? guestCodeLength : 4;
                return CreateNopFunction(framePointer, address, mode, nopLength);
            }

            return GetOrTranslate(address, mode).FuncPointer;
        }

        private IntPtr CreateNopFunction(IntPtr framePointer, ulong address, ExecutionMode mode, int guestCodeLength)
        {
            byte[] nopInstruction;
            byte[] retInstruction;
            int instructionSize;
            
            if (mode == ExecutionMode.Aarch64)
            {
                nopInstruction = new byte[] { 0x1F, 0x20, 0x03, 0xD5 };
                retInstruction = new byte[] { 0xC0, 0x03, 0x5F, 0xD6 };
                instructionSize = 4;
            }
            else
            {
                nopInstruction = new byte[] { 0x90 };
                retInstruction = new byte[] { 0xC3 };
                instructionSize = 1;
            }
            
            int totalSize = Math.Max(guestCodeLength, instructionSize);
            byte[] nopCode = new byte[totalSize];
            
            for (int i = 0; i < totalSize - instructionSize; i++)
            {
                nopCode[i] = nopInstruction[i % instructionSize];
            }
            
            for (int i = 0; i < instructionSize; i++)
            {
                nopCode[totalSize - instructionSize + i] = retInstruction[i];
            }
            
            try
            {
                if (_noWxCache != null)
                {
                    return _noWxCache.Map(framePointer, nopCode, address, (ulong)totalSize); 
                }
                else if (_dualMappedCache != null)
                {
                    return _dualMappedCache.Map(framePointer, nopCode, address, (ulong)totalSize);
                }
            }
            catch (Exception nopEx)
            {
                Logger.Warning?.Print(LogClass.Cpu, $"Failed to create NOP function for 0x{address:X16}: {nopEx.Message}");
            }
            return IntPtr.Zero;
        }

        private TranslatedFunction GetOrTranslate(ulong address, ExecutionMode mode)
        {
            if (!Functions.TryGetValue(address, out TranslatedFunction func))
            {
                func = Translate(address, mode);

                TranslatedFunction oldFunc = Functions.GetOrAdd(address, func.GuestSize, func);

                if (oldFunc != func)
                {
                    JitCache.Unmap(func.FuncPointer);
                    func = oldFunc;
                }

                RegisterFunction(address, func);
            }

            return func;
        }

        internal void RegisterFunction(ulong guestAddress, TranslatedFunction func)
        {
            if (FunctionTable.IsValid(guestAddress))
            {
                Volatile.Write(ref FunctionTable.GetValue(guestAddress), (ulong)func.FuncPointer);
            }
        }

        private TranslatedFunction Translate(ulong address, ExecutionMode mode)
        {
            CompiledFunction func = Compile(address, mode);
            IntPtr funcPointer = JitCache.Map(func.Code);

            return new TranslatedFunction(funcPointer, (ulong)func.GuestCodeLength);
        }

        public CompiledFunction Compile(ulong address, ExecutionMode mode)
        {
            return AarchCompiler.Compile(CpuPresets.CortexA57, Memory, address, FunctionTable, Stubs.DispatchStub, mode, RuntimeInformation.ProcessArchitecture);
        }

        public void InvalidateJitCacheRegion(ulong address, ulong size)
        {
            ulong[] overlapAddresses = Array.Empty<ulong>();

            int overlapsCount = Functions.GetOverlaps(address, size, ref overlapAddresses);

            for (int index = 0; index < overlapsCount; index++)
            {
                ulong overlapAddress = overlapAddresses[index];

                if (Functions.TryGetValue(overlapAddress, out TranslatedFunction overlap))
                {
                    Functions.Remove(overlapAddress);
                    Volatile.Write(ref FunctionTable.GetValue(overlapAddress), FunctionTable.Fill);
                    EnqueueForDeletion(overlapAddress, overlap);
                }
            }

            // TODO: Remove overlapping functions from the JitCache aswell.
            // This should be done safely, with a mechanism to ensure the function is not being executed.
        }

        private void EnqueueForDeletion(ulong guestAddress, TranslatedFunction func)
        {
            _oldFuncs.Enqueue(new(guestAddress, func));
        }

        private void ClearJitCache()
        {
            List<TranslatedFunction> functions = Functions.AsList();

            foreach (var func in functions)
            {
                JitCache.Unmap(func.FuncPointer);
            }

            Functions.Clear();

            while (_oldFuncs.TryDequeue(out var kv))
            {
                JitCache.Unmap(kv.Value.FuncPointer);
            }
        }

        protected virtual void Dispose(bool disposing)
        {
            if (!_disposed)
            {
                if (disposing)
                {
                    BootEventBridge.Report($"GAME SESSION {_sessionId} shutdown begin");

                    // "threads stopped": this Dispose() runs from
                    // LightningJitCpuContext.Dispose(), itself only
                    // reached once Ryujinx's own HOS/Horizon process
                    // teardown has already torn down every guest thread
                    // for this title (a CPU context cannot safely be
                    // disposed while a guest thread might still execute
                    // through it) - this marker confirms ORDERING, not an
                    // independently-measured live thread count (no public
                    // counter is exposed by KProcess for that without
                    // modifying Ryujinx.HLE's kernel layer, out of scope
                    // here).
                    BootEventBridge.Report($"GAME SESSION {_sessionId} threads stopped");

                    BootEventBridge.Report("jitDisposeAttempted", "true");

                    if (_noWxCache != null)
                    {
                        _noWxCache.Dispose();
                        BootEventBridge.Report("jitMappingsReleased", "n/a (NoWxCache is per-session, fully disposed)");
                    }
                    else if (_dualMappedCache != null)
                    {
                        // PROCESS JIT STATE vs GAME SESSION JIT STATE: when
                        // _dualMappedCache IS the shared process-wide
                        // singleton (originalDualMappedCache - the normal
                        // case once TXM/JIT26 preparation has happened
                        // once), its underlying RW/RX mapping must survive
                        // for the life of the process - JIT26-prepared
                        // regions cannot be re-prepared after the external
                        // debugger/script detaches. Disposing it here (the
                        // previous behavior) called the real allocator's
                        // Dispose() AND CacheMemoryAllocator.Clear(), the
                        // latter of which had a real bug (see
                        // CacheMemoryAllocator.Clear's doc comment) that
                        // left the shared allocator permanently unable to
                        // satisfy any further Allocate() call - exactly
                        // "TranslatorStubs.Map begin" with no "Map end" on
                        // the very next game. EndGameSession() clears only
                        // the per-game bookkeeping and leaves the mapping
                        // itself untouched. A genuinely per-session,
                        // non-shared instance (the non-TXM, not-yet-
                        // firstSet construction path) is still safe to
                        // fully Dispose().
                        if (ReferenceEquals(_dualMappedCache, originalDualMappedCache))
                        {
                            _dualMappedCache.EndGameSession();
                        }
                        else
                        {
                            _dualMappedCache.Dispose();
                            BootEventBridge.Report("jitMappingsReleased", "n/a (per-session dual-mapped instance, fully disposed)");
                        }
                    }
                    else
                    {
                        ClearJitCache();
                    }

                    BootEventBridge.Report("jitStateReset", "true");

                    // Functions is a process-wide static cache keyed by
                    // GUEST address - a different game's guest addresses
                    // can and do collide with this one's, so a stale
                    // TranslatedFunction here would silently execute THIS
                    // game's code at an address the NEXT game thinks is
                    // its own. Reset unconditionally, every path.
                    Functions = new TranslatorCache<TranslatedFunction>();
                    BootEventBridge.Report("threadLocalCachesReset", "true");

                    Stubs.Dispose();
                    FunctionTable.Dispose();
                    BootEventBridge.Report("dispatchStubReset", "true");
                    BootEventBridge.Report($"GAME SESSION {_sessionId} JIT dispose");
                    BootEventBridge.Report($"GAME SESSION {_sessionId} mappings released");

                    BootEventBridge.Report("translatorDisposed", "true");
                    BootEventBridge.Report($"GAME SESSION {_sessionId} translator disposed");

                    BootEventBridge.Report($"GAME SESSION {_sessionId} shutdown complete");
                }

                _disposed = true;
            }
        }

        public void Dispose()
        {
            Dispose(disposing: true);
            GC.SuppressFinalize(this);
        }
    }
}
