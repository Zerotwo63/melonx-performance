using ARMeilleure.Common;
using Ryujinx.Cpu.LightningJit.Cache;
using Ryujinx.Cpu.LightningJit.CodeGen;
using Ryujinx.Cpu.LightningJit.CodeGen.Arm64;
using Ryujinx.Cpu.LightningJit.State;
using Ryujinx.Common.Logging;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Cpu.LightningJit
{
    delegate void DispatcherFunction(IntPtr nativeContext, ulong startAddress);

    /// <summary>
    /// Diagnóstico real #7 (FASE 2): signature for the same-map probe - a
    /// tiny generated function taking no arguments and returning a known
    /// constant, used to verify the exact same cache/Map path DispatchLoop
    /// uses can actually produce code that executes and returns correctly.
    /// </summary>
    delegate uint ProbeDelegate();

    /// <summary>
    /// Diagnóstico real #7 (FASE 4): signature matching GetFunctionAddressDelegate
    /// exactly (framePointer, guest address) -> host function pointer. Used by
    /// the direct-dispatch probe, which tail-calls straight into
    /// _getFunctionAddress via the same BLR/native-call mechanism DispatchStub
    /// uses, skipping the FunctionTable lookup entirely.
    /// </summary>
    delegate ulong DirectDispatchProbeDelegate(IntPtr framePointer, ulong address);

    /// <summary>
    /// Represents a stub manager.
    /// </summary>
    class TranslatorStubs : IDisposable
    {
        private delegate ulong GetFunctionAddressDelegate(IntPtr framePointer, ulong address);

        private readonly Lazy<IntPtr> _slowDispatchStub;

        private bool _disposed;

        private readonly AddressTable<ulong> _functionTable;
        private readonly NoWxCache _noWxCache;
        private readonly DualMappedNoWxCache _dualMappedCache;

        private readonly GetFunctionAddressDelegate _getFunctionAddressRef;
        private readonly IntPtr _getFunctionAddress;
        private readonly Lazy<IntPtr> _dispatchStub;
        private readonly Lazy<DispatcherFunction> _dispatchLoop;

        // Diagnóstico real #7 (FASE 3): small, fixed, native memory block that
        // the GENERATED ARM64 code itself writes known stage markers into via
        // plain str instructions - a managed Console.WriteLine is impossible
        // once control transfers into generated code via Blr. Allocated once,
        // before any Generate* method runs, so its address is a stable
        // constant that can be embedded directly into the assembled code.
        // Offsets: 0 = DispatchLoop stage, 4 = DispatchStub stage, 8 = SlowDispatchStub stage,
        // 12 = FASE 8G same-map stage-probe entry stage, 16 = same-map stage-probe before-RET stage.
        private readonly IntPtr _diagMarkers;

        public int DiagDispatchLoopStage => Marshal.ReadInt32(_diagMarkers, 0);
        public int DiagDispatchStubStage => Marshal.ReadInt32(_diagMarkers, 4);
        public int DiagSlowDispatchStubStage => Marshal.ReadInt32(_diagMarkers, 8);
        public int DiagSameMapEntryStage => Marshal.ReadInt32(_diagMarkers, 12);
        public int DiagSameMapBeforeRetStage => Marshal.ReadInt32(_diagMarkers, 16);

        /// <summary>
        /// Gets the dispatch stub.
        /// </summary>
        /// <exception cref="ObjectDisposedException"><see cref="TranslatorStubs"/> instance was disposed</exception>
        public IntPtr DispatchStub
        {
            get
            {
                ObjectDisposedException.ThrowIf(_disposed, this);

                return _dispatchStub.Value;
            }
        }

        /// <summary>
        /// Gets the slow dispatch stub.
        /// </summary>
        /// <exception cref="ObjectDisposedException"><see cref="TranslatorStubs"/> instance was disposed</exception>
        public IntPtr SlowDispatchStub
        {
            get
            {
                ObjectDisposedException.ThrowIf(_disposed, this);

                return _slowDispatchStub.Value;
            }
        }

        /// <summary>
        /// Gets the dispatch loop function.
        /// </summary>
        /// <exception cref="ObjectDisposedException"><see cref="TranslatorStubs"/> instance was disposed</exception>
        public DispatcherFunction DispatchLoop
        {
            get
            {
                ObjectDisposedException.ThrowIf(_disposed, this);

                return _dispatchLoop.Value;
            }
        }

        /// <summary>
        /// Initializes a new instance of the <see cref="TranslatorStubs"/> class with the specified
        /// <see cref="Translator"/> instance.
        /// </summary>
        /// <param name="functionTable">Function table used to store pointers to the functions that the guest code will call</param>
        /// <param name="noWxCache">Cache used on platforms that enforce W^X, otherwise should be null</param>
        /// <exception cref="ArgumentNullException"><paramref name="translator"/> is null</exception>
        public TranslatorStubs(AddressTable<ulong> functionTable, NoWxCache noWxCache)
        {
            ArgumentNullException.ThrowIfNull(functionTable);

            _functionTable = functionTable;
            _noWxCache = noWxCache;
            _getFunctionAddressRef = NativeInterface.GetFunctionAddress;
            _getFunctionAddress = Marshal.GetFunctionPointerForDelegate(_getFunctionAddressRef);
            _diagMarkers = Marshal.AllocHGlobal(20);
            Marshal.WriteInt32(_diagMarkers, 0, 0);
            Marshal.WriteInt32(_diagMarkers, 4, 0);
            Marshal.WriteInt32(_diagMarkers, 8, 0);
            Marshal.WriteInt32(_diagMarkers, 12, 0);
            Marshal.WriteInt32(_diagMarkers, 16, 0);
            _slowDispatchStub = new(GenerateSlowDispatchStub, isThreadSafe: true);
            _dispatchStub = new(GenerateDispatchStub, isThreadSafe: true);
            _dispatchLoop = new(GenerateDispatchLoop, isThreadSafe: true);
        }

        /// <summary>
        /// Initializes a new instance of the <see cref="TranslatorStubs"/> class with the specified
        /// <see cref="Translator"/> instance.
        /// </summary>
        /// <param name="functionTable">Function table used to store pointers to the functions that the guest code will call</param>
        /// <param name="writeZeroCache">Cache used on iOS versions that need a debugger to make a debug map</param>
        /// <exception cref="ArgumentNullException"><paramref name="translator"/> is null</exception>
        public TranslatorStubs(AddressTable<ulong> functionTable, DualMappedNoWxCache dualMappedCache)
        {
            ArgumentNullException.ThrowIfNull(functionTable);

            _functionTable = functionTable;
            _dualMappedCache = dualMappedCache;
            _getFunctionAddressRef = NativeInterface.GetFunctionAddress;
            _getFunctionAddress = Marshal.GetFunctionPointerForDelegate(_getFunctionAddressRef);
            _diagMarkers = Marshal.AllocHGlobal(20);
            Marshal.WriteInt32(_diagMarkers, 0, 0);
            Marshal.WriteInt32(_diagMarkers, 4, 0);
            Marshal.WriteInt32(_diagMarkers, 8, 0);
            Marshal.WriteInt32(_diagMarkers, 12, 0);
            Marshal.WriteInt32(_diagMarkers, 16, 0);
            _slowDispatchStub = new(GenerateSlowDispatchStub, isThreadSafe: true);
            _dispatchStub = new(GenerateDispatchStub, isThreadSafe: true);
            _dispatchLoop = new(GenerateDispatchLoop, isThreadSafe: true);
        }

                /// <summary>
        /// Initializes a new instance of the <see cref="TranslatorStubs"/> class with the specified
        /// <see cref="Translator"/> instance.
        /// </summary>
        /// <param name="functionTable">Function table used to store pointers to the functions that the guest code will call</param>
        public TranslatorStubs(AddressTable<ulong> functionTable)
        {
            ArgumentNullException.ThrowIfNull(functionTable);

            _functionTable = functionTable;
            _getFunctionAddressRef = NativeInterface.GetFunctionAddress;
            _getFunctionAddress = Marshal.GetFunctionPointerForDelegate(_getFunctionAddressRef);
            _diagMarkers = Marshal.AllocHGlobal(20);
            Marshal.WriteInt32(_diagMarkers, 0, 0);
            Marshal.WriteInt32(_diagMarkers, 4, 0);
            Marshal.WriteInt32(_diagMarkers, 8, 0);
            Marshal.WriteInt32(_diagMarkers, 12, 0);
            Marshal.WriteInt32(_diagMarkers, 16, 0);
            _slowDispatchStub = new(GenerateSlowDispatchStub, isThreadSafe: true);
            _dispatchStub = new(GenerateDispatchStub, isThreadSafe: true);
            _dispatchLoop = new(GenerateDispatchLoop, isThreadSafe: true);
        }

        /// <summary>
        /// Releases all resources used by the <see cref="TranslatorStubs"/> instance.
        /// </summary>
        public void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }

        /// <summary>
        /// Releases all unmanaged and optionally managed resources used by the <see cref="TranslatorStubs"/> instance.
        /// </summary>
        /// <param name="disposing"><see langword="true"/> to dispose managed resources also; otherwise just unmanaged resouces</param>
        protected virtual void Dispose(bool disposing)
        {
            if (!_disposed)
            {
                if (_noWxCache == null && _dualMappedCache == null)
                {
                    if (_dispatchStub.IsValueCreated)
                    {
                        JitCache.Unmap(_dispatchStub.Value);
                    }

                    if (_dispatchLoop.IsValueCreated)
                    {
                        JitCache.Unmap(Marshal.GetFunctionPointerForDelegate(_dispatchLoop.Value));
                    }
                }

                Marshal.FreeHGlobal(_diagMarkers);

                _disposed = true;
            }
        }

        /// <summary>
        /// Frees resources used by the <see cref="TranslatorStubs"/> instance.
        /// </summary>
        ~TranslatorStubs()
        {
            Dispose(false);
        }

        /// <summary>
        /// Generates a <see cref="DispatchStub"/>.
        /// </summary>
        /// <returns>Generated <see cref="DispatchStub"/></returns>
        private IntPtr GenerateDispatchStub()
        {
            BootEventBridge.Report("TranslatorStubs.GenerateDispatchStub begin");
            List<int> branchToFallbackOffsets = new();

            CodeWriter writer = new();

            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                Assembler asm = new(writer);
                RegisterSaveRestore rsr = new((1u << 19) | (1u << 21) | (1u << 22), hasCall: true);

                rsr.WritePrologue(ref asm);

                Operand context = Register(19);
                asm.Mov(context, Register(0));

                EmitDiagMarker(ref asm, 4, 10); // dispatchStubStage = 10: entró al DispatchStub

                // Load the target guest address from the native context.
                Operand guestAddress = Register(16);

                asm.LdrRiUn(guestAddress, context, NativeContext.GetDispatchAddressOffset());

                EmitDiagMarker(ref asm, 4, 11); // dispatchStubStage = 11: guest address leído
                asm.LdrRiUn(guestAddress, context, NativeContext.GetDispatchAddressOffset()); // re-materialize X16 - EmitDiagMarker clobbered it

                // Check if guest address is within range of the AddressTable.
                asm.And(Register(17), guestAddress, Const(~_functionTable.Mask));

                branchToFallbackOffsets.Add(writer.InstructionPointer);

                asm.Cbnz(Register(17), 0);

                EmitDiagMarker(ref asm, 4, 12); // dispatchStubStage = 12: comenzó lookup de FunctionTable
                asm.LdrRiUn(guestAddress, context, NativeContext.GetDispatchAddressOffset()); // re-materialize X16 (guestAddress) for the level-walking loop below

                Operand page = Register(17);
                Operand index = Register(21);
                Operand mask = Register(22);

                asm.Mov(page, (ulong)_functionTable.Base);

                for (int i = 0; i < _functionTable.Levels.Length; i++)
                {
                    ref var level = ref _functionTable.Levels[i];

                    asm.Mov(mask, level.Mask >> level.Index);
                    asm.And(index, mask, guestAddress, ArmShiftType.Lsr, level.Index);

                    if (i < _functionTable.Levels.Length - 1)
                    {
                        asm.LdrRr(page, page, index, ArmExtensionType.Uxtx, true);

                        branchToFallbackOffsets.Add(writer.InstructionPointer);

                        asm.Cbz(page, 0);
                    }
                }

                asm.LdrRr(page, page, index, ArmExtensionType.Uxtx, true);

                rsr.WriteEpilogue(ref asm);

                asm.Br(page);

                foreach (int branchOffset in branchToFallbackOffsets)
                {
                    uint branchInst = writer.ReadInstructionAt(branchOffset);
                    Debug.Assert(writer.InstructionPointer > branchOffset);
                    writer.WriteInstructionAt(branchOffset, branchInst | ((uint)(writer.InstructionPointer - branchOffset) << 5));
                }

                // Fallback.
                EmitDiagMarker(ref asm, 4, 13); // dispatchStubStage = 13: tomó fallback
                asm.LdrRiUn(guestAddress, context, NativeContext.GetDispatchAddressOffset()); // re-materialize X16 - every branch into this fallback label leaves guestAddress valid in X16, but EmitDiagMarker just clobbered it

                asm.Mov(Register(0), Register(29));
                asm.Mov(Register(1), guestAddress);
                asm.Mov(Register(16), (ulong)_getFunctionAddress);

                EmitDiagMarker(ref asm, 4, 14); // dispatchStubStage = 14: inmediatamente antes de BLR _getFunctionAddress
                asm.Mov(Register(16), (ulong)_getFunctionAddress); // re-materialize X16 (call target) - X0/X1 untouched by the marker

                asm.Blr(Register(16));

                EmitDiagMarker(ref asm, 4, 15); // dispatchStubStage = 15: inmediatamente después de BLR _getFunctionAddress - X0 (return value) untouched by the marker, no reload needed

                asm.Mov(Register(16), Register(0));

                EmitDiagMarker(ref asm, 4, 16); // dispatchStubStage = 16: antes de BR al translated function
                asm.Mov(Register(16), Register(0)); // re-materialize X16 (result) - X0 still holds it at this exact point, before the next line overwrites X0 with context

                asm.Mov(Register(0), Register(19));

                rsr.WriteEpilogue(ref asm);

                asm.Br(Register(16));
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            IntPtr dispatchStubPtr = Map(writer.AsByteSpan());
            BootEventBridge.Report("TranslatorStubs.GenerateDispatchStub end", $"ptr=0x{dispatchStubPtr:X}");
            return dispatchStubPtr;
        }

        /// <summary>
        /// Generates a <see cref="SlowDispatchStub"/>.
        /// </summary>
        /// <returns>Generated <see cref="SlowDispatchStub"/></returns>
        private IntPtr GenerateSlowDispatchStub()
        {
            BootEventBridge.Report("TranslatorStubs.GenerateSlowDispatchStub begin");
            CodeWriter writer = new();

            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                Assembler asm = new(writer);
                RegisterSaveRestore rsr = new(1u << 19, hasCall: true);

                rsr.WritePrologue(ref asm);

                Operand context = Register(19);
                asm.Mov(context, Register(0));

                EmitDiagMarker(ref asm, 8, 20); // slowDispatchStubStage = 20: entró

                // Load the target guest address from the native context.
                asm.Mov(Register(0), Register(29));
                asm.LdrRiUn(Register(1), context, NativeContext.GetDispatchAddressOffset());
                asm.Mov(Register(16), (ulong)_getFunctionAddress);

                EmitDiagMarker(ref asm, 8, 21); // slowDispatchStubStage = 21: antes de BLR _getFunctionAddress
                asm.Mov(Register(16), (ulong)_getFunctionAddress); // re-materialize X16 (call target) - X0/X1 untouched by the marker

                asm.Blr(Register(16));

                EmitDiagMarker(ref asm, 8, 22); // slowDispatchStubStage = 22: después de BLR _getFunctionAddress - X0 (return value) untouched, no reload needed

                asm.Mov(Register(16), Register(0));

                EmitDiagMarker(ref asm, 8, 23); // slowDispatchStubStage = 23: antes de BR translated function
                asm.Mov(Register(16), Register(0)); // re-materialize X16 (result) - X0 still holds it here, before the next line overwrites X0 with context

                asm.Mov(Register(0), Register(19));

                rsr.WriteEpilogue(ref asm);

                asm.Br(Register(16));
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            IntPtr slowDispatchStubPtr = Map(writer.AsByteSpan());
            BootEventBridge.Report("TranslatorStubs.GenerateSlowDispatchStub end", $"ptr=0x{slowDispatchStubPtr:X}");
            return slowDispatchStubPtr;
        }

        /// <summary>
        /// Emits code that syncs FP state before executing guest code, or returns it to normal.
        /// </summary>
        /// <param name="asm">Assembler</param>
        /// <param name="context">Pointer to the native context</param>
        /// <param name="tempRegister">First temporary register</param>
        /// <param name="tempRegister2">Second temporary register</param>
        /// <param name="enter">True if entering guest code, false otherwise</param>
        private static void EmitSyncFpContext(ref Assembler asm, Operand context, Operand tempRegister, Operand tempRegister2, bool enter)
        {
            if (enter)
            {
                EmitSwapFpFlags(ref asm, context, tempRegister, tempRegister2, NativeContext.GetFpFlagsOffset(), NativeContext.GetHostFpFlagsOffset());
            }
            else
            {
                EmitSwapFpFlags(ref asm, context, tempRegister, tempRegister2, NativeContext.GetHostFpFlagsOffset(), NativeContext.GetFpFlagsOffset());
            }
        }

        /// <summary>
        /// Swaps the FPCR and FPSR values with values stored in the native context.
        /// </summary>
        /// <param name="asm">Assembler</param>
        /// <param name="context">Pointer to the native context</param>
        /// <param name="tempRegister">First temporary register</param>
        /// <param name="tempRegister2">Second temporary register</param>
        /// <param name="loadOffset">Offset of the new flags that will be loaded</param>
        /// <param name="storeOffset">Offset where the current flags should be saved</param>
        private static void EmitSwapFpFlags(ref Assembler asm, Operand context, Operand tempRegister, Operand tempRegister2, int loadOffset, int storeOffset)
        {
            asm.MrsFpcr(tempRegister);
            asm.MrsFpsr(tempRegister2);
            asm.Orr(tempRegister, tempRegister, tempRegister2);

            asm.StrRiUn(tempRegister, context, storeOffset);

            asm.LdrRiUn(tempRegister, context, loadOffset);
            asm.MsrFpcr(tempRegister);
            asm.MsrFpsr(tempRegister2);
        }

        /// <summary>
        /// Generates a <see cref="DispatchLoop"/> function.
        /// </summary>
        /// <returns><see cref="DispatchLoop"/> function</returns>
        private DispatcherFunction GenerateDispatchLoop()
        {
            BootEventBridge.Report("TranslatorStubs.GenerateDispatchLoop begin");
            CodeWriter writer = new();

            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                Assembler asm = new(writer);
                RegisterSaveRestore rsr = new(1u << 19, hasCall: true);

                rsr.WritePrologue(ref asm);

                Operand context = Register(19);
                asm.Mov(context, Register(0));

                EmitDiagMarker(ref asm, 0, 1); // dispatchLoopStage = 1: entró al DispatchLoop

                EmitSyncFpContext(ref asm, context, Register(16, OperandType.I32), Register(17, OperandType.I32), true);

                EmitDiagMarker(ref asm, 0, 2); // dispatchLoopStage = 2: terminó EmitSyncFpContext inicial

                // Load the target guest address from the native context.
                Operand guestAddress = Register(16);

                asm.Mov(guestAddress, Register(1));

                int loopStartIndex = writer.InstructionPointer;

                asm.StrRiUn(guestAddress, context, NativeContext.GetDispatchAddressOffset());

                // Marks 3/4/5 are safe to insert here: Cbz(guestAddress, 16) and
                // Cbz(Register(17), 8) below encode their branch target as a
                // fixed byte offset relative to THEIR OWN instruction address,
                // not relative to loopStartIndex - nothing is inserted between
                // either Cbz and its target (EmitSyncFpContext(false) below), so
                // those literal 16/8 immediates remain correct however many
                // instructions these markers add before them. The backward
                // branch further down recomputes its own offset dynamically via
                // writer.InstructionPointer, so it self-adjusts too.
                EmitDiagMarker(ref asm, 0, 3); // dispatchLoopStage = 3: escribió DispatchAddress

                asm.Mov(Register(0), context);
                asm.Mov(Register(17), (ulong)DispatchStub);

                EmitDiagMarker(ref asm, 0, 4); // dispatchLoopStage = 4: inmediatamente antes de BLR DispatchStub
                asm.Mov(Register(17), (ulong)DispatchStub); // re-materialize X17 (call target) - X0 (context arg) untouched by the marker

                asm.Blr(Register(17));

                EmitDiagMarker(ref asm, 0, 5); // dispatchLoopStage = 5: inmediatamente después de regresar de DispatchStub - X0 (next guest PC) untouched, no reload needed

                asm.Mov(guestAddress, Register(0));
                asm.Cbz(guestAddress, 16);
                asm.LdrRiUn(Register(17), context, NativeContext.GetRunningOffset());
                asm.Cbz(Register(17), 8);
                asm.B((loopStartIndex - writer.InstructionPointer) * 4);

                EmitSyncFpContext(ref asm, context, Register(16, OperandType.I32), Register(17, OperandType.I32), false);

                rsr.WriteEpilogue(ref asm);

                asm.Ret();
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            IntPtr pointer = Map(writer.AsByteSpan());
            BootEventBridge.Report("TranslatorStubs.GenerateDispatchLoop end", $"ptr=0x{pointer:X}");

            return Marshal.GetDelegateForFunctionPointer<DispatcherFunction>(pointer);
        }

        private IntPtr Map(ReadOnlySpan<byte> code)
        {
            BootEventBridge.Report("TranslatorStubs.Map begin", $"size={code.Length}");

            IntPtr result;
            if (_noWxCache != null)
            {
                result = _noWxCache.MapPageAligned(code);
            }
            else if (_dualMappedCache != null)
            {
                result = _dualMappedCache.MapPageAligned(code);
            }
            else
            {
                result = JitCache.Map(code);
            }

            BootEventBridge.Report("TranslatorStubs.Map end", $"ptr=0x{result:X}");
            return result;
        }

        private static Operand Register(int register, OperandType type = OperandType.I64)
        {
            return new Operand(register, RegisterType.Integer, type);
        }

        private static Operand Const(ulong value)
        {
            return new(OperandKind.Constant, OperandType.I64, value);
        }

        /// <summary>
        /// Diagnóstico real #7 (FASE 6): read-only inspection of the real
        /// FunctionTable state for a given guest address. Deliberately does
        /// NOT call AddressTable.GetValue/.Base's page-walking internals for
        /// anything beyond what codegen has ALREADY forced to exist by the
        /// time this runs (Base/Fill are only read here AFTER DispatchLoop/
        /// DispatchStub have already been generated and already accessed
        /// them for real - see call site in Translator.Execute - so this
        /// causes no NEW allocation of its own) - AddressTable.GetValue(ref)
        /// and the private page-walk both lazily ALLOCATE missing pages as a
        /// side effect, which would violate "sin alterar el estado" if
        /// called here, so the actual leaf table entry for this address is
        /// never read directly; only the per-level index it WOULD use (pure
        /// arithmetic, Level.GetValue, no allocation) is computed and logged.
        /// </summary>
        public void LogFunctionTableLookup(ulong address)
        {
            BootEventBridge.Report(
                "LightningJit.FunctionTable info",
                $"base=0x{_functionTable.Base:X},mask=0x{_functionTable.Mask:X},fill=0x{_functionTable.Fill:X},levelCount={_functionTable.Levels.Length}");
            BootEventBridge.Report(
                "LightningJit.FunctionTable stubs",
                $"dispatchStub=0x{DispatchStub:X},slowDispatchStub=0x{SlowDispatchStub:X}");

            bool inRange = _functionTable.IsValid(address);
            BootEventBridge.Report("LightningJit.FunctionTable lookup", $"address=0x{address:X},inRange={inRange}");

            if (inRange)
            {
                var indices = new System.Text.StringBuilder();
                for (int i = 0; i < _functionTable.Levels.Length; i++)
                {
                    if (i > 0)
                    {
                        indices.Append(',');
                    }
                    indices.Append($"level{i}={_functionTable.Levels[i].GetValue(address)}");
                }
                BootEventBridge.Report("LightningJit.FunctionTable level indices", indices.ToString());
            }
        }

        /// <summary>
        /// Diagnóstico real #7 (FASE 4): OFF by default - only runs when the
        /// env var LIGHTNINGJIT_DIAG_DIRECT_DISPATCH is exactly "1" (same
        /// opt-in convention as DUAL_MAPPED_JIT elsewhere in this codebase).
        /// Generates a tiny trampoline that tail-calls directly into
        /// _getFunctionAddress (`mov x16, #_getFunctionAddress; br x16`),
        /// reproducing "DispatchLoop -> GetFunctionAddress" through the real
        /// BLR/native-call mechanism while completely skipping DispatchStub's
        /// FunctionTable lookup. Does NOT touch the real DispatchLoop/
        /// DispatchStub assembly at all - this is a fully separate, isolated
        /// probe, never substituted for the real dispatch path. If this
        /// reaches GetFunctionAddress and translationAttempts/
        /// translatedFunctionsCreated advance (visible via the FASE 5
        /// instrumentation already in NativeInterface.GetFunctionAddress),
        /// the problem is isolated to DispatchStub/FunctionTable; if even
        /// this never reaches GetFunctionAddress, the problem is earlier
        /// (native call mechanism/mapping/ABI), matching the same conclusion
        /// as a SameMapProbe failure.
        /// </summary>
        public ulong? RunDirectDispatchProbe(IntPtr framePointer, ulong address)
        {
            if (Environment.GetEnvironmentVariable("LIGHTNINGJIT_DIAG_DIRECT_DISPATCH") != "1")
            {
                return null;
            }

            BootEventBridge.Report("LightningJit.DirectDispatchProbe begin", $"framePointer=0x{framePointer:X},address=0x{address:X}");

            CodeWriter writer = new();

            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                Assembler asm = new(writer);
                asm.Mov(Register(16), (ulong)_getFunctionAddress);
                asm.Br(Register(16));
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            IntPtr ptr;

            try
            {
                ptr = Map(writer.AsByteSpan());
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("LightningJit.DirectDispatchProbe map", ex);
                return null;
            }

            try
            {
                DirectDispatchProbeDelegate probe = Marshal.GetDelegateForFunctionPointer<DirectDispatchProbeDelegate>(ptr);
                ulong result = probe(framePointer, address);
                BootEventBridge.Report("LightningJit.DirectDispatchProbe result", $"hostFuncPtr=0x{result:X}");
                return result;
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("LightningJit.DirectDispatchProbe call", ex);
                return null;
            }
        }

        /// <summary>
        /// Diagnóstico real #7 (FASE 2): generates `mov w0, #0x12345678; ret`
        /// and maps it through the EXACT SAME cache/Map path DispatchLoop/
        /// DispatchStub use (_noWxCache/_dualMappedCache's MapPageAligned,
        /// same _sharedCache, same SysIcacheInvalidate), then calls it once.
        /// This isolates "can code written through this exact dual-mapping/
        /// icache mechanism actually execute and return correctly" from
        /// "does DispatchLoop's own specific logic have a bug" - if this
        /// fails, the problem is in the mapping/coherence/invocation
        /// mechanism itself, not in anything DispatchLoop-specific.
        /// </summary>
        public (bool succeeded, IntPtr rwAddress, IntPtr rxAddress, uint returnValue, byte[] bytesWritten, byte[] bytesReadBack) RunSameMapProbe()
        {
            // Diagnóstico real #9 (FASE 9B, bug real encontrado): this used
            // to say `const uint ExpectedValue = 0x12345678;`, but
            // Assembler.Mov(Operand, int) is just Movz(rd, imm, 0) - ONE
            // MOVZ instruction with no shift, which only ever loads the
            // LOW 16 bits (confirmed by reading Assembler.cs: the ulong
            // overload is the one that emits a real MOVZ+MOVK sequence for
            // values that don't fit in 16 bits, but that overload was not
            // used here). The real generated/executed instruction was
            // always `mov w0, #0x5678; ret` - matching the actual observed
            // bytes (00CF8A52C0035FD6) exactly. Per explicit preference,
            // keep the single-instruction test and fix the expected value
            // instead of switching to a multi-instruction load.
            const uint ExpectedValue = 0x5678;

            CodeWriter writer = new();

            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                Assembler asm = new(writer);
                asm.Mov(Register(0, OperandType.I32), unchecked((int)ExpectedValue));
                asm.Ret();
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            byte[] code = writer.AsByteSpan().ToArray();
            BootEventBridge.Report("LightningJit.SameMapProbe begin", $"size={code.Length}");

            IntPtr rwAddress = IntPtr.Zero;
            IntPtr rxAddress;

            try
            {
                if (_noWxCache != null)
                {
                    rxAddress = _noWxCache.MapPageAligned(code, out nint rw);
                    rwAddress = rw;
                }
                else if (_dualMappedCache != null)
                {
                    rxAddress = _dualMappedCache.MapPageAligned(code, out rwAddress);
                }
                else
                {
                    rxAddress = JitCache.Map(code);
                    rwAddress = rxAddress;
                }
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("LightningJit.SameMapProbe map", ex);
                return (false, IntPtr.Zero, IntPtr.Zero, 0, Array.Empty<byte>(), Array.Empty<byte>());
            }

            BootEventBridge.Report("LightningJit.SameMapProbe mapped", $"rw=0x{rwAddress:X},rx=0x{rxAddress:X}");

            byte[] bytesWritten = code;

            // FASE 8A: read the SAME bytes from BOTH aliases independently -
            // the previous round's "bytes read back" only ever read through
            // RW (so it trivially always matched what was just written
            // through RW), never proving the RX alias shows the same
            // content. Any exception reading RX is itself significant and
            // reported, not swallowed.
            byte[] bytesReadBackRw = ReadBytesSafe(rwAddress, code.Length, "RW");
            byte[] bytesReadBackRx = ReadBytesSafe(rxAddress, code.Length, "RX");

            BootEventBridge.Report("LightningJit.SameMapProbe bytes written", Convert.ToHexString(bytesWritten));
            if (bytesReadBackRw.Length > 0)
            {
                BootEventBridge.Report("LightningJit.SameMapProbe bytes read back (RW alias)", Convert.ToHexString(bytesReadBackRw));
            }
            if (bytesReadBackRx.Length > 0)
            {
                BootEventBridge.Report("dispatchProbeBytesRx", Convert.ToHexString(bytesReadBackRx));
            }
            bool rwRxMatch = bytesReadBackRw.Length > 0 && bytesReadBackRw.AsSpan().SequenceEqual(bytesReadBackRx);
            BootEventBridge.Report("dispatchProbeRwRxBytesMatch", rwRxMatch.ToString());

            // Coherence test, no execution involved: write pattern A through
            // RW, read RX; write pattern B through RW, read RX again. This
            // isolates "do RW/RX really alias the same backing memory with
            // changes visible across the alias" from anything about
            // instruction fetch/icache/execution.
            try
            {
                byte[] patternA = new byte[code.Length];
                Array.Fill(patternA, (byte)0xAA);
                Marshal.Copy(patternA, 0, rwAddress, patternA.Length);
                byte[] readA = ReadBytesSafe(rxAddress, code.Length, "RX (coherence pattern A)");
                BootEventBridge.Report("LightningJit.SameMapProbe coherence pattern A", $"wrote={Convert.ToHexString(patternA)},readRx={Convert.ToHexString(readA)},match={patternA.AsSpan().SequenceEqual(readA)}");

                byte[] patternB = new byte[code.Length];
                Array.Fill(patternB, (byte)0x55);
                Marshal.Copy(patternB, 0, rwAddress, patternB.Length);
                byte[] readB = ReadBytesSafe(rxAddress, code.Length, "RX (coherence pattern B)");
                BootEventBridge.Report("LightningJit.SameMapProbe coherence pattern B", $"wrote={Convert.ToHexString(patternB)},readRx={Convert.ToHexString(readB)},match={patternB.AsSpan().SequenceEqual(readB)}");

                // Restore the real probe code before anything tries to call it.
                Marshal.Copy(code, 0, rwAddress, code.Length);
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("LightningJit.SameMapProbe coherence test", ex);
                // Still try to restore the real code so the call attempt below is meaningful.
                try { Marshal.Copy(code, 0, rwAddress, code.Length); } catch { /* best effort */ }
            }

            // FASE 8B: query the REAL current/max protection of both
            // aliases right before the call - never assumed from Map()
            // having returned without throwing.
            NativeMemoryDiagnostics.QueryProtection(rwAddress, "RW");
            NativeMemoryDiagnostics.QueryProtection(rxAddress, "RX");

            // FASE 8C: explicit cache synchronization, targeting the RX
            // alias specifically (not only RW), right before the call.
            NativeMemoryDiagnostics.SyncCaches(rwAddress, rxAddress, code.Length);

            // FASE 8F: architecture/PAC context, logged once alongside this
            // probe since it's directly relevant to whether the indirect
            // call below could be affected.
            NativeMemoryDiagnostics.ReportArchitecture();

            // Diagnóstico real #9: this device's chip (Apple A19 Pro) very
            // likely has TXM - this fork's OWN existing code already has a
            // dedicated workaround for it (DualMappedJitAllocator.hasTXM /
            // BreakGetJITMapping) that RunSingleMapControl below does NOT
            // use at all (plain mmap/mprotect). If TXM enforcement is why
            // execution never completes, this is a real, independent signal.
            NativeMemoryDiagnostics.ReportTxmStatus();

            // FASE 8D: a trivially-verifiable, already-compiled-into-the-
            // process native function (getpid), called through the EXACT
            // SAME Marshal.GetDelegateForFunctionPointer mechanism used
            // below - isolates the managed call/delegate/ABI layer from
            // anything specific to DualMappedNoWxCache.
            NativeMemoryDiagnostics.RunNativeControl();

            // FASE 8E/9C: the SAME instruction bytes, mapped through a
            // classic single mmap-RW/mprotect-RX region (no dual alias at
            // all), called through the SAME delegate mechanism, with full
            // before/after protection + cache-sync instrumentation.
            NativeMemoryDiagnostics.RunSingleMapControl(code, ExpectedValue);

            // FASE 9D: Test B - same single-map mechanism, but the
            // generated code starts with `bti c`. Compared against Test A
            // (plain, no BTI) above - if B succeeds and A does not, that
            // is direct evidence of a BTI landing-pad requirement.
            NativeMemoryDiagnostics.RunSingleMapBtiControl(ExpectedValue);

            // FASE 9H: a THIRD, separate single-map variant with entry/
            // before-RET native stage markers, run on its own background
            // thread+poller so a hang here does not block anything else.
            NativeMemoryDiagnostics.RunSingleMapStageProbe();

            // FASE 8G: a SEPARATE stage-marker variant of this same probe,
            // launched on its own background thread so that if IT also
            // hangs, it does not block this thread (and therefore does not
            // block the real DispatchLoop attempt that follows this probe).
            RunSameMapStageProbe();

            uint returnValue = 0;
            bool succeeded = false;

            try
            {
                BootEventBridge.Report("LightningJit.SameMapProbe call begin", $"rx=0x{rxAddress:X}");
                ProbeDelegate probe = Marshal.GetDelegateForFunctionPointer<ProbeDelegate>(rxAddress);
                returnValue = probe();
                BootEventBridge.Report("LightningJit.SameMapProbe call returned", $"result=0x{returnValue:X}");
                succeeded = returnValue == ExpectedValue;
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("LightningJit.SameMapProbe call", ex);
            }

            BootEventBridge.Report(
                succeeded ? "LightningJit.SameMapProbe PASS" : "LightningJit.SameMapProbe FAIL",
                $"expected=0x{ExpectedValue:X},actual=0x{returnValue:X}");

            return (succeeded, rwAddress, rxAddress, returnValue, bytesWritten, bytesReadBackRw);
        }

        private static byte[] ReadBytesSafe(IntPtr address, int length, string label)
        {
            try
            {
                if (address == IntPtr.Zero)
                {
                    return Array.Empty<byte>();
                }

                byte[] bytes = new byte[length];
                Marshal.Copy(address, bytes, 0, length);
                return bytes;
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail($"LightningJit.SameMapProbe read {label} bytes", ex);
                return Array.Empty<byte>();
            }
        }

        /// <summary>
        /// Diagnóstico real #8 (FASE 8G): a SEPARATE tiny function (never
        /// mixed into the main 8-byte probe above) that writes known values
        /// into _diagMarkers offsets 12/16 at entry and right before RET,
        /// using the exact same X16/X17-only scratch-register discipline as
        /// EmitDiagMarker. Run on its own background thread (fire-and-
        /// forget) precisely so a hang here can be observed (via
        /// DiagSameMapEntryStage/DiagSameMapBeforeRetStage, polled the same
        /// way as the FASE 3 markers) without blocking anything else.
        /// </summary>
        private void RunSameMapStageProbe()
        {
            CodeWriter writer = new();

            if (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
            {
                Assembler asm = new(writer);
                EmitDiagMarker(ref asm, 12, 1); // sameMapNativeEntryStage = 1: primera instrucción alcanzada
                EmitDiagMarker(ref asm, 16, 2); // sameMapNativeBeforeRetStage = 2: justo antes de RET
                asm.Ret();
            }
            else
            {
                throw new PlatformNotSupportedException();
            }

            byte[] code = writer.AsByteSpan().ToArray();
            IntPtr rxAddress;

            try
            {
                if (_noWxCache != null)
                {
                    rxAddress = _noWxCache.MapPageAligned(code, out _);
                }
                else if (_dualMappedCache != null)
                {
                    rxAddress = _dualMappedCache.MapPageAligned(code, out _);
                }
                else
                {
                    rxAddress = JitCache.Map(code);
                }
            }
            catch (Exception ex)
            {
                BootEventBridge.ReportFail("LightningJit.SameMapStageProbe map", ex);
                return;
            }

            Thread stageProbeThread = new(() =>
            {
                try
                {
                    BootEventBridge.Report("LightningJit.SameMapStageProbe call begin", $"rx=0x{rxAddress:X}");
                    ProbeDelegate probe = Marshal.GetDelegateForFunctionPointer<ProbeDelegate>(rxAddress);
                    probe();
                    BootEventBridge.Report("LightningJit.SameMapStageProbe call returned");
                }
                catch (Exception ex)
                {
                    BootEventBridge.ReportFail("LightningJit.SameMapStageProbe call", ex);
                }
            })
            {
                IsBackground = true,
                Name = "LightningJit.SameMapStageProbe",
            };
            stageProbeThread.Start();

            // Dedicated poller for THIS probe's markers, independent of
            // Translator.PollDiagMarkers - that one only starts right
            // before the real DispatchLoop call, which this whole method
            // runs before. If the main 8-byte probe above hangs, execution
            // never reaches that point, so without this, a hang here would
            // be invisible.
            Thread pollThread = new(() =>
            {
                int lastEntry = -1, lastBeforeRet = -1;
                for (int i = 0; i < 50; i++) // ~10s at 200ms, then give up polling (thread stays background either way)
                {
                    int entry = DiagSameMapEntryStage;
                    int beforeRet = DiagSameMapBeforeRetStage;

                    if (entry != lastEntry)
                    {
                        BootEventBridge.Report("sameMapNativeEntryStage", entry.ToString());
                        lastEntry = entry;
                    }

                    if (beforeRet != lastBeforeRet)
                    {
                        BootEventBridge.Report("sameMapNativeBeforeRetStage", beforeRet.ToString());
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
                Name = "LightningJit.SameMapStageProbe.Poll",
            };
            pollThread.Start();
        }

        /// <summary>
        /// Diagnóstico real #7 (FASE 3): emits `mov x16, #addr; mov w17, #value; str w17, [x16]`
        /// - a 3-instruction stage marker write into the fixed native memory block
        /// above. X16/X17 are the only registers ever used here because they are
        /// the designated ARM64 scratch registers (IP0/IP1) - never callee-saved
        /// under AAPCS64, so no caller/callee anywhere in this codebase can be
        /// relying on their value surviving across any call or block boundary.
        /// Every call site below that has a LIVE value already sitting in X16 or
        /// X17 at the point a marker is inserted re-materializes it immediately
        /// afterward (documented at each call site) - this never changes which
        /// value ends up in any register the surrounding real code depends on.
        /// </summary>
        private void EmitDiagMarker(ref Assembler asm, int offset, int value)
        {
            IntPtr addr = _diagMarkers + offset;
            asm.Mov(Register(16), (ulong)(long)addr);
            asm.Mov(Register(17, OperandType.I32), value);
            asm.StrRiUn(Register(17, OperandType.I32), Register(16), 0);
        }
    }
}
