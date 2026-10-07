using ARMeilleure.Memory;
using Ryujinx.Cpu.LightningJit.State;
using Ryujinx.Common.Logging;
using System;
// Not `using System.Threading;` - this file already has its own
// `ExecutionContext` (Ryujinx.Cpu.LightningJit.State.ExecutionContext),
// which collides with System.Threading.ExecutionContext. Interlocked is
// referenced fully-qualified below instead.

namespace Ryujinx.Cpu.LightningJit
{
    static class NativeInterface
    {
        private const int DczSizeLog2 = 4; // Log2 size in words
        private const int DczSizeInBytes = 4 << DczSizeLog2;

        // Additive diagnostics counter only - does not affect behavior. This
        // is called directly from hand-assembled ARM64 code via a native
        // function pointer (Blr _getFunctionAddress), not from any other C#
        // code - a marker on the very first statement here is the earliest
        // possible managed-side confirmation that the generated dispatch
        // code's BLR to this callback actually landed.
        private static int s_getFunctionAddressCalls;

        private class ThreadContext
        {
            public ExecutionContext Context { get; }
            public IMemoryManager Memory { get; }
            public Translator Translator { get; }

            public ThreadContext(ExecutionContext context, IMemoryManager memory, Translator translator)
            {
                Context = context;
                Memory = memory;
                Translator = translator;
            }
        }

        [ThreadStatic]
        private static ThreadContext Context;

        public static void RegisterThread(ExecutionContext context, IMemoryManager memory, Translator translator)
        {
            Context = new ThreadContext(context, memory, translator);
        }

        public static void UnregisterThread()
        {
            Context = null;
        }

        public static void Break(ulong address, int imm)
        {
            GetContext().OnBreak(address, imm);
        }

        public static void SupervisorCall(ulong address, int imm)
        {
            GetContext().OnSupervisorCall(address, imm);
        }

        public static void Undefined(ulong address, int opCode)
        {
            GetContext().OnUndefined(address, opCode);
        }

        public static ulong GetCntfrqEl0()
        {
            return GetContext().CntfrqEl0;
        }

        public static ulong GetCntpctEl0()
        {
            return GetContext().CntpctEl0;
        }

        public static ulong GetFunctionAddress(IntPtr framePointer, ulong address)
        {
            int calls = System.Threading.Interlocked.Increment(ref s_getFunctionAddressCalls);
            bool verbose = calls <= 10 || calls % 50 == 0;

            if (verbose)
            {
                BootEventBridge.Report("NativeInterface.GetFunctionAddress entered", $"framePointer=0x{framePointer:X},address=0x{address:X},calls={calls}");
            }

            ulong result = (ulong)Context.Translator.GetOrTranslatePointer(framePointer, address, GetContext().ExecutionMode);

            if (verbose)
            {
                BootEventBridge.Report("NativeInterface.GetFunctionAddress returning", $"result=0x{result:X},calls={calls}");
            }
            return result;
        }

        public static void InvalidateJitCacheRegion(ulong address, ulong size)
        {
            Context.Translator.InvalidateJitCacheRegion(address, size);
        }

        public static void InvalidateCacheLine(ulong address)
        {
            Context.Translator.InvalidateJitCacheRegion(address, DczSizeInBytes);
        }

        public static void SetPageTablePointer() 
        {
            Context.Context.SetPageTablePointer(Context.Memory);
        }

        public static bool CheckSynchronization()
        {
            ExecutionContext context = GetContext();

            context.CheckInterrupt();

            return context.Running;
        }

        public static ExecutionContext GetContext()
        {
            return Context.Context;
        }

        public static IMemoryManager GetMemoryManager()
        {
            return Context.Memory;
        }
    }
}
