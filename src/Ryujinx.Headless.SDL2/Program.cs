using CommandLine;
using LibHac.Tools.FsSystem;
using Ryujinx.Audio.Backends.SDL2;
using Ryujinx.Audio.Backends.Apple;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Configuration.Hid;
using Ryujinx.Common.Configuration.Hid.Controller;
using Ryujinx.Common.Configuration.Hid.Controller.Motion;
using Ryujinx.Common.Configuration.Hid.Keyboard;
using Ryujinx.Common.GraphicsDriver;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Logging.Targets;
using Ryujinx.Common.SystemInterop;
using Ryujinx.Common.Utilities;
using Ryujinx.Cpu;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.OpenGL;
using Ryujinx.Graphics.Vulkan;
using Ryujinx.Graphics.Vulkan.MoltenVK;
using Ryujinx.Headless.SDL2.OpenGL;
using Ryujinx.Headless.SDL2.Vulkan;
using Ryujinx.HLE;
using Ryujinx.HLE.FileSystem;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.Input;
using Ryujinx.Input.HLE;
using Ryujinx.Input.SDL2;
using Ryujinx.SDL2.Common;
using Ryujinx.UI.Common.Configuration.System;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using ConfigGamepadInputId = Ryujinx.Common.Configuration.Hid.Controller.GamepadInputId;
using ConfigStickInputId = Ryujinx.Common.Configuration.Hid.Controller.StickInputId;
using Key = Ryujinx.Common.Configuration.Hid.Key;
using Ryujinx.HLE.HOS.SystemState;
using LibHac.Common.Keys;
using LibHac.Common;
using LibHac.Ns;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Fs;
using Path = System.IO.Path;
using Ryujinx.Common.Configuration.Multiplayer;
using Ryujinx.HLE.Loaders.Npdm;
using System.Globalization;
using System.Text;
using LibHac.Ncm;
using Microsoft.Win32.SafeHandles;
using System.Text.RegularExpressions;
using System.Runtime;
using System.Linq;
using System.Threading.Tasks;
using Ryujinx.Input.Native;

namespace Ryujinx.Headless.SDL2
{
    class Program
    {
        public static string Version { get; private set; }

        private static VirtualFileSystem _virtualFileSystem;
        private static ContentManager _contentManager;
        private static AccountManager _accountManager;
        private static LibHacHorizonManager _libHacHorizonManager;
        private static UserChannelPersistence _userChannelPersistence;
        private static InputManager _inputManager;
        private static Switch _emulationContext;
        private static WindowBase _window;

        // Session lifecycle barrier ("running -> stopping -> fullyStopped
        // -> readyForNextGame"): _window.Exit() (inside StopEmulation,
        // below) only blocks until the render loop's while-loop exits -
        // it does NOT wait for ExecutionEntrypoint to actually reach
        // _emulationContext.Dispose()/_window.Dispose() on the managed
        // thread, which happens AFTER MainLoop() returns, as a separate
        // step on that same thread. Without this, stop_emulation could
        // return to Swift - letting the user launch the NEXT game - while
        // THIS session's Translator.Dispose()/EndGameSession() (the
        // shared JIT cache's per-session reset) is still unwinding,
        // racing the next session's first TranslatorStubs.Map call
        // against this session's cleanup of the exact same shared
        // allocator. Starts Set (nothing to wait for before the first
        // game ever runs); Reset at the top of ExecutionEntrypoint, Set
        // once its real teardown is done.
        private static readonly ManualResetEventSlim _sessionFullyTornDown = new(true);

        // Lifecycle diagnostics only - one increment per ExecutionEntrypoint
        // run (one per mainRyu/main_ryujinx_sdl call, i.e. one per game
        // session). Independent from LightningJit.Translator's own
        // _sessionId counter (that one increments inside the Translator
        // constructor, further downstream once Switch/guest construction
        // reaches the CPU context) - the two stay 1:1 in practice since
        // exactly one Translator is created per game session, but are
        // kept as separate counters to avoid a cross-file coupling for a
        // diagnostics-only id.
        private static int _gameSessionId;
        private static WindowsMultimediaTimerResolution _windowsMultimediaTimerResolution;
        private static List<InputConfig> _inputConfiguration;
        private static bool _enableKeyboard;
        private static bool _enableMouse;
        private static IntPtr nativeMetalLayer = IntPtr.Zero;
        private static readonly object metalLayerLock = new object();

        private static readonly InputConfigJsonSerializerContext _serializerContext = new(JsonHelper.GetDefaultSerializerOptions());
        private static readonly TitleUpdateMetadataJsonSerializerContext _titleSerializerContext = new(JsonHelper.GetDefaultSerializerOptions());

                
        [DllImport("RyujinxHelper.framework/RyujinxHelper", CallingConvention = CallingConvention.Cdecl)]
        public static extern void TriggerCallbackWithData(string cIdentifier, IntPtr data,  UIntPtr dataLength);

        [DllImport("RyujinxHelper.framework/RyujinxHelper", CallingConvention = CallingConvention.Cdecl)]
        public static extern void TriggerCallback(string cIdentifier);

        // Deterministic C#->Swift boot bridge, requested explicitly instead
        // of relying on stdout/LogCapture alone (which this exact investigation
        // exists to verify is even reaching Swift at all). Reuses the
        // existing, already-proven TriggerCallbackWithData channel (same one
        // "ran-first-frame"/"ProgressWithPTCorShaderCache" already use
        // successfully from a background GPU thread) under one new
        // identifier, "boot-event", rather than inventing a new native
        // export. Payload is plain UTF-8 "name" or "name|value" - Swift's
        // BootDiagnostics parses it directly into a real stage/result.
        public static void ReportBootEvent(string name, string value = null)
        {
            string payload = value == null ? name : $"{name}|{value}";
            Console.WriteLine($"[BOOT] {payload}");

            byte[] bytes = Encoding.UTF8.GetBytes(payload);
            IntPtr unmanagedPointer = Marshal.AllocHGlobal(bytes.Length);
            try
            {
                Marshal.Copy(bytes, 0, unmanagedPointer, bytes.Length);
                TriggerCallbackWithData("boot-event", unmanagedPointer, (UIntPtr)bytes.Length);
            }
            finally
            {
                Marshal.FreeHGlobal(unmanagedPointer);
            }
        }

        /// Formats type/Message/StackTrace/InnerException recursively - per
        /// instruction, the original exception must never be swallowed, only
        /// reported alongside whatever the caller does with it (rethrow,
        /// etc.). Sent through the same "boot-event" channel with a
        /// "FAIL|stage|reason" payload so Swift's listener can tell a real
        /// failure apart from a plain stage log.
        public static void ReportBootFailure(string stage, Exception ex)
        {
            var sb = new StringBuilder();
            Exception current = ex;
            bool first = true;
            while (current != null)
            {
                if (!first)
                {
                    sb.Append("\nInnerException: ");
                }
                sb.Append(current.GetType().FullName).Append(": ").Append(current.Message);
                sb.Append('\n').Append(current.StackTrace);
                current = current.InnerException;
                first = false;
            }
            string reason = sb.ToString();

            Console.WriteLine($"[BOOT] FAILURE at {stage}:\n{reason}");

            string payload = $"FAIL|{stage}|{reason}";
            byte[] bytes = Encoding.UTF8.GetBytes(payload);
            IntPtr unmanagedPointer = Marshal.AllocHGlobal(bytes.Length);
            try
            {
                Marshal.Copy(bytes, 0, unmanagedPointer, bytes.Length);
                TriggerCallbackWithData("boot-event", unmanagedPointer, (UIntPtr)bytes.Length);
            }
            finally
            {
                Marshal.FreeHGlobal(unmanagedPointer);
            }
        }

        private static bool _unhandledExceptionHandlersInstalled = false;

        /// Per instruction: catch everything that could otherwise die
        /// silently on a thread/task this process never observes directly.
        /// Installed once, idempotently, as early as possible.
        private static void InstallUnhandledExceptionHandlers()
        {
            if (_unhandledExceptionHandlersInstalled)
            {
                return;
            }
            _unhandledExceptionHandlersInstalled = true;

            AppDomain.CurrentDomain.UnhandledException += (sender, e) =>
            {
                ReportBootFailure("AppDomain.UnhandledException", e.ExceptionObject as Exception ?? new Exception(e.ExceptionObject?.ToString() ?? "unknown unhandled exception object"));
            };

            TaskScheduler.UnobservedTaskException += (sender, e) =>
            {
                ReportBootFailure("TaskScheduler.UnobservedTaskException", e.Exception);
                e.SetObserved();
            };
        }

        [UnmanagedCallersOnly(EntryPoint = "main_ryujinx_sdl")]
        public static unsafe int MainExternal(int argCount, IntPtr* pArgs)
        {
            // Explicit, unambiguous test for whether ANY C# output reaches
            // Swift at all - both the deterministic bridge and plain
            // stdout/stderr, before anything else managed code could do
            // might fail or hang. If "BOOT-TEST managed code reached" is
            // missing from the next real report, main_ryujinx_sdl itself
            // was never actually called despite ryujinx.start() returning.
            ReportBootEvent("BOOT-TEST managed code reached");
            Console.WriteLine("[BOOT-TEST] MANAGED CODE REACHED (stdout)");
            Console.Error.WriteLine("[BOOT-TEST] MANAGED CODE REACHED (stderr)");

            InstallUnhandledExceptionHandlers();

            BootEventBridge.ReportEvent = ReportBootEvent;
            BootEventBridge.ReportFailure = ReportBootFailure;

            string[] args = new string[argCount];

            BootEventBridge.Report("mainEntered", "true");
            BootEventBridge.Report("[MAIN] stage", "entered");

            try
            {
                ReportBootEvent("managed entry reached");
                for (int i = 0; i < argCount; i++)
                {
                    args[i] = Marshal.PtrToStringAnsi(pArgs[i]);

                    Console.WriteLine(args[i]);
                }
                ReportBootEvent("args received", $"{argCount} args");

                // "argsReceived" (we got the raw strings from Swift) is
                // NOT the same claim as "argsParsed" (CommandLineParser
                // actually accepted them) - the previous round reported
                // the latter here, which was simply false whenever the
                // parser took the NotParsed branch. argsParsed is now set
                // ONLY inside .WithParsed (see Main() below).
                BootEventBridge.Report("argsReceived", "true");
                BootEventBridge.Report("argsCount", argCount.ToString());
                BootEventBridge.Report("[MAIN] stage", "args received");
                for (int i = 0; i < argCount; i++)
                {
                    BootEventBridge.Report($"[ARGS] {i}", args[i]);
                }

                Main(args);
            }
            catch (Exception e)
            {
                // Dedicated, never-overwritten fields (see
                // ReportMainException's doc comment for why the existing
                // ReportBootFailure/fail() path alone was not enough to
                // actually SEE this on a real device, despite already
                // capturing the full exception).
                ReportMainException("main_ryujinx_sdl", e);
                ReportBootFailure("main_ryujinx_sdl", e);
                Console.WriteLine(e.ToString());
                BootEventBridge.Report("mainReturnCode", "-1");
                return -1;
            }

            BootEventBridge.Report("mainReturnCode", "0");
            return 0;
        }

        /// <summary>
        /// Objective: "[MAIN] exceptionType/exceptionMessage/exceptionHResult/
        /// innerException/stackTrace" - requested explicitly because the
        /// existing ReportBootFailure (which already captures the FULL
        /// exception chain, type, message, and stack trace - see its own
        /// body) was never actually visible on a real device report: its
        /// value reaches BootDiagnostics.fail(stage:reason:) on the Swift
        /// side, which OVERWRITES failureStage/failureReason with no
        /// "first reason wins" protection - and Ryujinx.swift's own
        /// wrapper (`throw RyujinxError.executionError(code: result)`,
        /// evaluated right after this returns -1) calls fail() a SECOND
        /// time with a generic "executionError(code: -1)" message,
        /// unconditionally overwriting the real exception this method
        /// already reported first. Reporting these under separate,
        /// dedicated event names - routed to dedicated, never-overwritten
        /// BootDiagnostics fields, not the shared failureStage/
        /// failureReason - sidesteps that overwrite entirely rather than
        /// relying on fixing the ordering of two independent call sites.
        /// </summary>
        private static void ReportMainException(string stage, Exception e)
        {
            BootEventBridge.Report("mainExceptionType", e.GetType().FullName);
            BootEventBridge.Report("mainExceptionMessage", e.Message);
            BootEventBridge.Report("mainExceptionHResult", $"0x{e.HResult:X8}");
            BootEventBridge.Report("mainExceptionStack", e.StackTrace ?? "<no stack trace>");
            BootEventBridge.Report("innerException", e.InnerException?.ToString() ?? "none");
            BootEventBridge.Report("[MAIN] stage", $"exception at {stage}: {e.GetType().Name}: {e.Message}");
        }

        [UnmanagedCallersOnly(EntryPoint = "set_native_window")]
        public static unsafe void SetNativeWindow(IntPtr layer) {
            lock (metalLayerLock) {
                nativeMetalLayer = layer;
                Logger.Info?.Print(LogClass.Application, $"SetNativeWindow called with layer: {layer}");
            }
        }

        public static IntPtr GetNativeMetalLayer()
        {
            lock (metalLayerLock)
            {
                return nativeMetalLayer;
            }
        }


        [UnmanagedCallersOnly(EntryPoint = "create_account")]
        public static void CreateAccount(IntPtr namePtr, IntPtr imagePtr, int imageLength)
        {
            string name = Marshal.PtrToStringAnsi(namePtr);

            byte[] image = null;
            if (imagePtr != IntPtr.Zero && imageLength > 0)
            {
                image = new byte[imageLength];
                Marshal.Copy(imagePtr, image, 0, imageLength);
            }

            _accountManager.AddUser(name, image);
        }

        [UnmanagedCallersOnly(EntryPoint = "delete_account")]
        public static void DeleteAccount(IntPtr userId)
        {
            string name = Marshal.PtrToStringAnsi(userId);

            HLE.HOS.Services.Account.Acc.UserId userIdObj = new HLE.HOS.Services.Account.Acc.UserId(name);
            _accountManager.DeleteUser(userIdObj);
        }

        [UnmanagedCallersOnly(EntryPoint = "open_user")]
        public static void OpenUser(IntPtr userId)
        {
            string name = Marshal.PtrToStringAnsi(userId);

            HLE.HOS.Services.Account.Acc.UserId userIdObj = new HLE.HOS.Services.Account.Acc.UserId(name);
            _accountManager.OpenUser(userIdObj);
        }

        [UnmanagedCallersOnly(EntryPoint = "close_user")]
        public static void CloseUser(IntPtr userId)
        {
            string name = Marshal.PtrToStringAnsi(userId);

            HLE.HOS.Services.Account.Acc.UserId userIdObj = new HLE.HOS.Services.Account.Acc.UserId(name);
            _accountManager.OpenUser(userIdObj);
        }

        [UnmanagedCallersOnly(EntryPoint = "free_avatars")]
        public static unsafe void FreeAvatars(AvatarArray avatarArray)
        {
            if (avatarArray.Avatars != null)
            {
                for (int i = 0; i < avatarArray.Count; i++)
                {
                    if (avatarArray.Avatars[i].ImageData != null)
                        Marshal.FreeHGlobal((IntPtr)avatarArray.Avatars[i].ImageData);
                    if (avatarArray.Avatars[i].FileName != null)
                        Marshal.FreeHGlobal((IntPtr)avatarArray.Avatars[i].FileName);
                }
                Marshal.FreeHGlobal((IntPtr)avatarArray.Avatars);
            }
        }


        [UnmanagedCallersOnly(EntryPoint = "get_avatars")]
        public static unsafe AvatarArray GetAvatars()
        {
            var avatars = AvatarLoader.LoadAvatars(_contentManager, _virtualFileSystem);
            int count = avatars.Count;

            AvatarInfo* avatarInfos = (AvatarInfo*)Marshal.AllocHGlobal(sizeof(AvatarInfo) * count);

            int index = 0;
            foreach (var kvp in avatars)
            {
                string fileName = kvp.Key;
                byte[] imageData = kvp.Value;

                byte* imagePtr = (byte*)Marshal.AllocHGlobal(imageData.Length);
                Marshal.Copy(imageData, 0, (IntPtr)imagePtr, imageData.Length);

                byte[] utf8FileName = Encoding.UTF8.GetBytes(fileName);
                sbyte* fileNamePtr = (sbyte*)Marshal.AllocHGlobal(utf8FileName.Length + 1);
                for (int i = 0; i < utf8FileName.Length; i++)
                {
                    fileNamePtr[i] = (sbyte)utf8FileName[i];
                }
                fileNamePtr[utf8FileName.Length] = 0; 

                avatarInfos[index] = new AvatarInfo
                {
                    ImageData = imagePtr,
                    ImageSize = imageData.Length,
                    FileName = fileNamePtr
                };

                index++;
            }

            return new AvatarArray
            {
                Count = count,
                Avatars = avatarInfos
            };
        }

        [UnmanagedCallersOnly(EntryPoint = "refresh_account_manager")]
        public static void RefreshAccountManager()
        {
            _accountManager.Refresh();
        }
        
        [UnmanagedCallersOnly(EntryPoint = "get_dlc_nca_list")]
        public static unsafe DlcNcaList GetDlcNcaList(IntPtr titleIdPtr, IntPtr pathPtr) 
        {
            var titleId = Marshal.PtrToStringAnsi(titleIdPtr);
            var containerPath = Marshal.PtrToStringAnsi(pathPtr);

            if (!File.Exists(containerPath))
            {
                return new DlcNcaList { success = false };
            }

            using FileStream containerFile = File.OpenRead(containerPath);

            PartitionFileSystem pfs = new();
            pfs.Initialize(containerFile.AsStorage()).ThrowIfFailure();
            bool containsDlc = false;

            _virtualFileSystem.ImportTickets(pfs);

            List<DlcNcaListItem> listItems = new();
            foreach (DirectoryEntryEx fileEntry in pfs.EnumerateEntries("/", "*.nca"))
            {
                using var ncaFile = new UniqueRef<IFile>();

                pfs.OpenFile(ref ncaFile.Ref, fileEntry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();

                Nca nca = TryCreateNca(ncaFile.Get.AsStorage(), containerPath);

                if (nca == null)
                {
                    continue;
                }

                if (nca.Header.ContentType == NcaContentType.PublicData)
                {
                    if ((nca.Header.TitleId & 0xFFFFFFFFFFFFE000).ToString("x16") != titleId)
                    {
                        break;
                    }

                    Logger.Warning?.Print(LogClass.Application, $"ContainerPath: {containerPath}");
                    Logger.Warning?.Print(LogClass.Application, $"TitleId: {nca.Header.TitleId}");
                    Logger.Warning?.Print(LogClass.Application, $"fileEntry.FullPath: {fileEntry.FullPath}");
                    
                    DlcNcaListItem item = new();
                    CopyStringToFixedArray(fileEntry.FullPath, item.Path, 256);
                    item.TitleId = nca.Header.TitleId;
                    listItems.Add(item);
                    
                    containsDlc = true;
                }
            }

            if (!containsDlc)
            {
                Console.WriteLine("The specified file does not contain DLC for the selected title!");
                return new DlcNcaList { success = false };
                // GtkDialog.CreateErrorDialog("The specified file does not contain DLC for the selected title!");
            }
            
            var list = new DlcNcaList { success = true, size = (uint) listItems.Count };

            DlcNcaListItem[] items = listItems.ToArray();

            fixed (DlcNcaListItem* p = &items[0])
            {
                list.items = p;
            }
            
            return list;
        }

        private static Nca TryCreateNca(IStorage ncaStorage, string containerPath)
        {
            try
            {
                return new Nca(_virtualFileSystem.KeySet, ncaStorage);
            }
            catch (Exception exception)
            {
                // ignored
            }

            return null;
        }

        [UnmanagedCallersOnly(EntryPoint = "attach_gamepad")]    
        public static IntPtr AttachGamepad(IntPtr namePtr, IntPtr idPtr)
        {
            if (namePtr == IntPtr.Zero || idPtr == IntPtr.Zero)
            {
                return IntPtr.Zero;
            }

            string value = Marshal.PtrToStringAnsi(namePtr);

            return NativeGamepadDriver.AttachGamepad(value, idPtr);
        }

        [UnmanagedCallersOnly(EntryPoint = "detach_gamepad")]    
        public static void DetachGamepad(IntPtr idPtr)
        {
            NativeGamepadDriver.DetachGamepad(idPtr);
        }

        [UnmanagedCallersOnly(EntryPoint = "set_gamepad_button_state")] 
        public static void SetButtonState(IntPtr idPtr, int buttonId, byte pressed)
        {
            NativeGamepadDriver.SetButtonState(idPtr, buttonId, pressed);
        }

        [UnmanagedCallersOnly(EntryPoint = "set_gamepad_stick_axis")] 
        public static void SetStickAxis(IntPtr idPtr, int stickId, float x, float y)
        {
            NativeGamepadDriver.SetStickAxis(idPtr, stickId, x, y);
        }

        [UnmanagedCallersOnly(EntryPoint = "set_gamepad_motion_axis")] 
        static void SetMotionData(IntPtr idPtr, int motionType, float x, float y, float z)
        {
            NativeGamepadDriver.SetMotionData(idPtr, motionType, x, y, z);
        }

        [UnmanagedCallersOnly(EntryPoint = "set_gamepad_configuration")] 
        unsafe static void setGamepadConfiguration(int argCount, IntPtr* pArgs)
        {
            ControllerOptions Get(int argCount, IntPtr* pArgs)
            {
                string[] args = new string[argCount];

                try
                {
                    for (int i = 0; i < argCount; i++)
                    {
                        args[i] = Marshal.PtrToStringAnsi(pArgs[i]);

                        Console.WriteLine(args[i]);
                    }
    
                    ControllerOptions options = null;
                    Parser.Default.ParseArguments<ControllerOptions>(args)
                    .WithParsed(option => options = option)
                    .WithNotParsed(errors => ReportParserErrors(errors));
                    return options;
                }
                catch (Exception e)
                {
                    Console.WriteLine(e.ToString());
                    return null;
                }
            }


            ControllerOptions option = Get(argCount, pArgs);
            if (option == null)
            {
                return;
            }

            static void LoadPlayerConfiguration(string inputProfileName, string inputId, string inputDSUServer, PlayerIndex index, ControllerOptions option)
            {
                if (inputId == null)
                {
                    return;
                }

                InputConfig inputConfig = HandlePlayerConfiguration(inputProfileName, inputId, inputDSUServer, index, null, option);

                if (inputConfig != null)
                {
                    _inputConfiguration.Add(inputConfig);
                }
            }

            _inputConfiguration = new List<InputConfig>();

            LoadPlayerConfiguration(null, option.InputId1, null, PlayerIndex.Player1, option);
            LoadPlayerConfiguration(null, option.InputId2, null, PlayerIndex.Player2, option);
            LoadPlayerConfiguration(null, option.InputId3, null, PlayerIndex.Player3, option);
            LoadPlayerConfiguration(null, option.InputId4, null, PlayerIndex.Player4, option);
            LoadPlayerConfiguration(null, option.InputId5, null, PlayerIndex.Player5, option);
            LoadPlayerConfiguration(null, option.InputId6, null, PlayerIndex.Player6, option);
            LoadPlayerConfiguration(null, option.InputId7, null, PlayerIndex.Player7, option);
            LoadPlayerConfiguration(null, option.InputId8, null, PlayerIndex.Player8, option);
            LoadPlayerConfiguration(null, option.InputIdHandheld, null, PlayerIndex.Handheld, option);

            Logger.Info?.Print(LogClass.Application, $"Configured {_inputConfiguration.Count} gamepads, {_inputConfiguration} from native code.");

            _window.NpadManager.ReloadConfiguration(_inputConfiguration, _enableKeyboard, _enableMouse);    
        }


        [UnmanagedCallersOnly(EntryPoint = "get_current_fps")]
        public static unsafe int GetFPS()
        {
            if (_window == null || _window.Device == null)
            {
                return 0;
            }

            Switch Device = _window.Device;

            int intValue = (int)Device.Statistics.GetGameFrameRate();

            return intValue;
        }

        /// <summary>
        /// CORRECTION (this round, per explicit audit request): the
        /// previous round's doc comment here called this "percentage of
        /// time the GPU command processor was actually active" and the
        /// Swift-side label said "GPU FIFO %", both of which read as a
        /// physical-GPU-hardware-utilization claim. Verified by reading
        /// the actual call site (Ryujinx.Headless.SDL2/WindowBase.cs:394-396,
        /// the same render loop this iOS build runs): RecordFifoStart()/
        /// RecordFifoEnd() bracket ONLY `Device.ProcessFrame()` - the HOST
        /// CPU call that translates the guest's submitted GPFIFO command
        /// stream into Vulkan API calls, running on this process's own
        /// GPU/render thread. This is CPU time spent on GPU-command
        /// translation, not a reading from any physical GPU hardware
        /// performance counter (Metal's MTLCounterSet/GPU frame capture,
        /// which this does NOT use at all). A high percentage here means
        /// "this thread spent most of the 750ms window inside
        /// ProcessFrame()", which correlates with GPU-command load but is
        /// NOT the same claim as "the physical GPU chip was X% busy".
        /// These values should be read as "FIFO processing thread load", never
        /// presented to a user as GPU hardware utilization without
        /// further evidence (e.g. Metal/Instruments GPU counters, which
        /// this build does not have access to).
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "get_gpu_fifo_percent")]
        public static unsafe float GetGpuFifoPercent()
        {
            if (_window == null || _window.Device == null)
            {
                return 0;
            }

            return (float)_window.Device.Statistics.GetFifoPercent();
        }

        // Deliberately NOT exposing GetGameFrameTime() here - it is a
        // pure derivation of the SAME frame rate get_current_fps already
        // reports (`1000 / frameRate`, see PerformanceStatistics.cs), not
        // an independent measurement. BenchmarkManager.swift's own doc
        // comment already explains exactly this (a previous round
        // correctly declined to add it for this reason) - true P95/P99
        // frametime needs real per-frame intervals, which
        // BenchmarkManager already collects via CADisplayLink
        // (frameIntervals), not a re-derivation of the engine's smoothed
        // FPS average.

        [UnmanagedCallersOnly(EntryPoint = "set_game_volume")]
        public static unsafe void SetGameVolume(float volume) {
            if (_emulationContext == null)
            {
                return;
            }

            Console.WriteLine($"Set Volume, current: {_emulationContext.GetVolume()}, set to: {volume}");

            _emulationContext.SetVolume(volume);

            Console.WriteLine($"tried to set volume {_emulationContext.GetVolume()}");
        }

        [UnmanagedCallersOnly(EntryPoint = "get_game_volume")]
        public static unsafe float GetGameVolume() {
            if (_emulationContext == null)
            {
                return 0;
            }

            Console.WriteLine($"Volume gotten: {_emulationContext.GetVolume()} :3");

            return (float)_emulationContext.GetVolume();
        }

        [UnmanagedCallersOnly(EntryPoint = "initialize")]
        public static unsafe void Initialize()
        {
            AppDataManager.Initialize(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments));
            ReportBootEvent("app data initialized");

            if (_virtualFileSystem == null)
            {
                _virtualFileSystem = VirtualFileSystem.CreateInstance();
            }

            if (_libHacHorizonManager == null)
            {
                _libHacHorizonManager = new LibHacHorizonManager();
                _libHacHorizonManager.InitializeFsServer(_virtualFileSystem);
                _libHacHorizonManager.InitializeArpServer();
                _libHacHorizonManager.InitializeBcatServer();
                _libHacHorizonManager.InitializeSystemClients();
            }

            if (_contentManager == null)
            {
                _contentManager = new ContentManager(_virtualFileSystem);
            }
            
            if (_accountManager == null)
            {
                _accountManager = new AccountManager(_libHacHorizonManager.RyujinxClient);
            }

            _inputManager = new InputManager(new SDL2KeyboardDriver(), new NativeGamepadDriver());

            GCSettings.LatencyMode = GCLatencyMode.Batch;
        }

        [UnmanagedCallersOnly(EntryPoint = "initialize-dualmapped")]
        public static unsafe bool InitializeDM() => Cpu.LightningJit.DualMappedTranslator.InitializeDualMapped();

        static void Main(string[] args)
        {
            ReportBootEvent("Program.Main entered");

            // Make process DPI aware for proper window sizing on high-res screens.
            ForceDpiAware.Windows();

            Silk.NET.Core.Loader.SearchPathContainer.Platform = Silk.NET.Core.Loader.UnderlyingPlatform.MacOS;

            if (!OperatingSystem.IsIOS())
            {
                // Console.Title = $"Ryujinx Console {Version} (Headless SDL2)";
            }

            if (OperatingSystem.IsMacOS() || OperatingSystem.IsIOS() || OperatingSystem.IsLinux())
            {
                AutoResetEvent invoked = new(false);

                // MacOS must perform SDL polls from the main thread.
                SDL2Driver.MainThreadDispatcher = action =>
                {
                    invoked.Reset();

                    WindowBase.QueueMainThreadAction(() =>
                    {
                        action();

                        invoked.Set();
                    });

                    invoked.WaitOne();
                };
            }

            if (OperatingSystem.IsMacOS())
            {
                MVKInitialization.InitializeResolver();
            }

            BootEventBridge.Report("argsParseAttempted", "true");
            BootEventBridge.Report("[MAIN] stage", "ParseArguments begin");

            Parser.Default.ParseArguments<Options>(args)
            .WithParsed(opts =>
            {
                // argsParsed/argsParseSucceeded can ONLY become true here -
                // inside WithParsed, after CommandLineParser itself
                // accepted every argument. The previous round reported
                // argsParsed=true unconditionally right after receiving
                // the raw strings, which was simply wrong whenever the
                // parser actually took the NotParsed branch below.
                BootEventBridge.Report("argsParsed", "true");
                BootEventBridge.Report("argsParseSucceeded", "true");
                BootEventBridge.Report("[MAIN] stage", "ParseArguments succeeded");
                Load(opts);
            })
            .WithNotParsed(errors =>
            {
                BootEventBridge.Report("argsParsed", "false");
                BootEventBridge.Report("argsParseSucceeded", "false");
                BootEventBridge.Report("[MAIN] stage", "ParseArguments failed (NotParsed)");
                ReportParserErrors(errors);
                // Deliberately NOT calling errors.Output() (the previous
                // behavior here) - CONFIRMED root cause of the real
                // crash (device stack trace): CommandLine.Parser.
                // DisplayHelp -> CommandLine.Text.HelpText.AutoBuild ->
                // HelpText..ctor -> System.ConsolePal.get_WindowWidth(),
                // which throws PlatformNotSupportedException on iOS
                // (there is no console window to measure). Whatever
                // argument(s) actually failed to parse are now fully
                // reported above, via ReportParserErrors, before this
                // comment is even reached - a parse failure must produce
                // a clear diagnostic, never a crash trying to render
                // help text for a terminal that does not exist here.
            });
        }

        /// <summary>
        /// Reports every CommandLine.Error from a failed ParseArguments
        /// call under "[ARGS] error[N].*" - using reflection over each
        /// concrete error's OWN properties (beyond the Error base class)
        /// rather than hand-matching every CommandLineParser 2.9.1 error
        /// subtype (BadFormatTokenError/UnknownOptionError/
        /// MissingRequiredOptionError/etc.) by name, since getting even
        /// one of those exact property names wrong would be a compile
        /// error with no local way to verify against the real package
        /// (not restored in this environment). Error.Tag (the type
        /// discriminator central to how this library works at all) is
        /// the one property assumed with high confidence; everything
        /// else is discovered at runtime, so this works correctly
        /// regardless of exactly which error subtype is involved.
        /// </summary>
        private static void ReportParserErrors(IEnumerable<CommandLine.Error> errors)
        {
            var errorList = errors.ToList();
            BootEventBridge.Report("parserErrorCount", errorList.Count.ToString());

            for (int i = 0; i < errorList.Count; i++)
            {
                CommandLine.Error error = errorList[i];
                string typeName = error.GetType().Name;
                string tag = error.Tag.ToString();

                var detailParts = new List<string>();
                foreach (var prop in error.GetType().GetProperties())
                {
                    if (prop.DeclaringType == typeof(CommandLine.Error))
                    {
                        continue;
                    }

                    try
                    {
                        object value = prop.GetValue(error);
                        detailParts.Add($"{prop.Name}={value}");
                    }
                    catch (Exception ex)
                    {
                        detailParts.Add($"{prop.Name}=<unreadable: {ex.Message}>");
                    }
                }
                string details = string.Join("; ", detailParts);

                BootEventBridge.Report($"[ARGS] error[{i}].type", typeName);
                BootEventBridge.Report($"[ARGS] error[{i}].tag", tag);
                BootEventBridge.Report($"[ARGS] error[{i}].details", details);

                if (i == 0)
                {
                    BootEventBridge.Report("firstParserErrorType", typeName);
                    BootEventBridge.Report("firstParserErrorToken", details);
                    BootEventBridge.Report("firstParserErrorName", tag);
                }

                Console.WriteLine($"[ARGS] error[{i}] = {typeName} (tag={tag}): {details}");
            }
        }
    
        [UnmanagedCallersOnly(EntryPoint = "install_firmware")]
        public static IntPtr InstallFirmwareNative(IntPtr inputPtr)
        {
            // ✖ is to tell if its an error or not because i'm too lazy to make a bool 
            try
            {
                if (inputPtr == IntPtr.Zero)
                {
                    return Marshal.StringToHGlobalAnsi("Error: inputPtr is null. ✖");
                }

                string inputString = Marshal.PtrToStringAnsi(inputPtr);

                if (string.IsNullOrEmpty(inputString))
                {
                    return Marshal.StringToHGlobalAnsi("Error: inputString is null or empty. ✖");
                }
                
                string firmwareVersion = InstallFirmware(inputString);

                return Marshal.StringToHGlobalAnsi(firmwareVersion);
            }
            catch (Exception ex)
            {
                return Marshal.StringToHGlobalAnsi($"Error: {ex.Message} ✖");
            }
        }

        public static string InstallFirmware(string filePath)
        {
            if (string.IsNullOrEmpty(filePath))
            {
                throw new ArgumentException("File path cannot be null or empty.", nameof(filePath));
            }

            if (_contentManager == null)
            {
                throw new InvalidOperationException("_contentManager is not initialized.");
            }

            // VerifyFirmwarePackage only reads the SOURCE package's own NCA
            // headers - it never touches the registered/ destination, so its
            // version string is not proof anything was actually installed.
            SystemVersion sourceVersion = _contentManager.VerifyFirmwarePackage(filePath);
            if (sourceVersion is null)
            {
                throw new InvalidOperationException("The provided file is not a valid firmware package.");
            }

            // This used to be `Task.Run(() => _contentManager.InstallFirmware(filePath));`
            // with the source package's version returned immediately after -
            // the real extraction/copy into registered/ was still running in
            // the background with no completion signal and no exception
            // ever reaching the caller. InstallFirmware is already a
            // synchronous, blocking call; calling it directly here means
            // this native function - the caller's only completion signal -
            // does not return until the real work is actually done.
            _contentManager.InstallFirmware(filePath);

            // Verify against the same source GetInstalledFirmwareVersion()
            // reads, so a caller gets the real installed state back, not
            // the source package's declared version.
            SystemVersion installedVersion = _contentManager.GetCurrentFirmwareVersion();
            if (installedVersion is null)
            {
                throw new InvalidOperationException("Firmware installation finished, but the installed version could not be verified in registered/.");
            }

            return installedVersion.VersionString;
        }


        [UnmanagedCallersOnly(EntryPoint = "installed_firmware_version")]
        public static IntPtr GetInstalledFirmwareVersionNative()
        {
            var result = GetInstalledFirmwareVersion();
            return Marshal.StringToHGlobalAnsi(result);
        }

        [UnmanagedCallersOnly(EntryPoint = "free_firmware_version")]
        public static void FreeFirmwareVersion(IntPtr versionPtr)
        {
            if (versionPtr != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(versionPtr);
            }
        }

        public static string GetInstalledFirmwareVersion()
        {
            try
            {
                var version = _contentManager.GetCurrentFirmwareVersion();

                if (version != null)
                {
                    return version.VersionString;
                }

                return String.Empty;
            } catch
            {
                return String.Empty;
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "pause_emulation")]
        public static void PauseEmulation(bool shouldPause)
        {
            if (_emulationContext != null && _emulationContext.System != null)
            {
                _emulationContext.System.TogglePauseEmulation(shouldPause);
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "stop_emulation")]
        public static void StopEmulation()
        {
            BootEventBridge.Report("stop_emulation entered");
            BootEventBridge.Report($"[SESSION {_gameSessionId}] stop requested");
            if (_window != null)
            {
                _window.Exit();
            }

            // Real completion barrier, not a fixed sleep: _window.Exit()
            // above only guarantees the render loop's while-loop has
            // exited - this waits for ExecutionEntrypoint's managed
            // thread to actually finish _emulationContext.Dispose()/
            // _window.Dispose() (see _sessionFullyTornDown's doc
            // comment). The timeout is a safety bound against a genuine
            // hang during teardown, never the primary gate - the real
            // gate is the Set() call at the end of ExecutionEntrypoint.
            bool fullyStopped = _sessionFullyTornDown.Wait(TimeSpan.FromSeconds(10));
            BootEventBridge.Report("stop_emulation sessionFullyTornDown", fullyStopped.ToString());
            BootEventBridge.Report("stop_emulation returned", "teardown barrier satisfied, safe to start the next game session");
        }

        [UnmanagedCallersOnly(EntryPoint = "get_game_info")]
        public static GameInfoNative GetGameInfoNative(int descriptor, IntPtr extensionPtr)
        {
            if (_virtualFileSystem == null) {
                _virtualFileSystem = VirtualFileSystem.CreateInstance();
            }
            
            var extension = Marshal.PtrToStringAnsi(extensionPtr);
            var stream = OpenFile(descriptor);

            var gameInfo = GetGameInfo(stream, extension);

            if (gameInfo == null) {
                return new GameInfoNative(0, "", "", "", "", new byte[0]);
            }

            return new GameInfoNative(
                (ulong)gameInfo.FileSize, 
                gameInfo.TitleName + "\0", 
                gameInfo.TitleId + "\0", 
                gameInfo.Developer + "\0", 
                gameInfo.Version + "\0", 
                gameInfo.Icon
            );
        }

        public static GameInfo? GetGameInfo(Stream gameStream, string extension)
        {

            var gameInfo = new GameInfo
            {
                FileSize = gameStream.Length * 0.000000000931,
                TitleName = "Unknown",
                TitleId = "0000000000000000",
                Developer = "Unknown",
                Version = "0",
                Icon = null
            };

            const Language TitleLanguage = Language.AmericanEnglish;

            BlitStruct<ApplicationControlProperty> controlHolder = new(1);

            try
            {
                try
                {
                    if (extension == "nsp" || extension == "pfs0" || extension == "xci")
                    {
                        IFileSystem pfs;

                        bool isExeFs = false;

                        if (extension == "xci")
                        {
                            Xci xci = new(_virtualFileSystem.KeySet, gameStream.AsStorage());

                            pfs = xci.OpenPartition(XciPartitionType.Secure);
                        }
                        else
                        {
                            var pfsTemp = new PartitionFileSystem();
                            pfsTemp.Initialize(gameStream.AsStorage()).ThrowIfFailure();
                            pfs = pfsTemp;

                            // If the NSP doesn't have a main NCA, decrement the number of applications found and then continue to the next application.
                            bool hasMainNca = false;

                            foreach (DirectoryEntryEx fileEntry in pfs.EnumerateEntries("/", "*"))
                            {
                                if (Path.GetExtension(fileEntry.FullPath).ToLower() == ".nca")
                                {
                                    using UniqueRef<IFile> ncaFile = new();

                                    pfs.OpenFile(ref ncaFile.Ref, fileEntry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();

                                    Nca nca = new(_virtualFileSystem.KeySet, ncaFile.Get.AsStorage());
                                    int dataIndex = Nca.GetSectionIndexFromType(NcaSectionType.Data, NcaContentType.Program);

                                    // Some main NCAs don't have a data partition, so check if the partition exists before opening it
                                    if (nca.Header.ContentType == NcaContentType.Program && !(nca.SectionExists(NcaSectionType.Data) && nca.Header.GetFsHeader(dataIndex).IsPatchSection()))
                                    {
                                        hasMainNca = true;

                                        break;
                                    }
                                }
                                else if (Path.GetFileNameWithoutExtension(fileEntry.FullPath) == "main")
                                {
                                    isExeFs = true;
                                }
                            }

                            if (!hasMainNca && !isExeFs)
                            {
                                return null;
                            }
                        }

                        if (isExeFs)
                        {
                            using UniqueRef<IFile> npdmFile = new();

                            LibHac.Result result = pfs.OpenFile(ref npdmFile.Ref, "/main.npdm".ToU8Span(), OpenMode.Read);

                            if (ResultFs.PathNotFound.Includes(result))
                            {
                                Npdm npdm = new(npdmFile.Get.AsStream());

                                gameInfo.TitleName = npdm.TitleName;
                                gameInfo.TitleId = npdm.Aci0.TitleId.ToString("x16");
                            }
                        }
                        else
                        {
                            GetControlFsAndTitleId(pfs, out IFileSystem? controlFs, out string? id);

                            gameInfo.TitleId = id;

                            if (controlFs == null)
                            {
                                Logger.Error?.Print(LogClass.Application, $"No control FS was returned. Unable to process game any further: {gameInfo.TitleName}");
                                return null;
                            }

                            // Check if there is an update available.
                            if (IsUpdateApplied(gameInfo.TitleId, out IFileSystem? updatedControlFs))
                            {
                                // Replace the original ControlFs by the updated one.
                                controlFs = updatedControlFs;
                            }

                            ReadControlData(controlFs, controlHolder.ByteSpan);


                            GetGameInformation(ref controlHolder.Value, out gameInfo.TitleName, out gameInfo.TitleId, out gameInfo.Developer, out gameInfo.Version);

                            // Read the icon from the ControlFS and store it as a byte array
                            try
                            {
                                using UniqueRef<IFile> icon = new();

                                controlFs?.OpenFile(ref icon.Ref, $"/icon_{TitleLanguage}.dat".ToU8Span(), OpenMode.Read).ThrowIfFailure();

                                using MemoryStream stream = new();

                                icon.Get.AsStream().CopyTo(stream);
                                gameInfo.Icon = stream.ToArray();
                            }
                            catch (HorizonResultException)
                            {
                                foreach (DirectoryEntryEx entry in controlFs.EnumerateEntries("/", "*"))
                                {
                                    if (entry.Name == "control.nacp")
                                    {
                                        continue;
                                    }

                                    using var icon = new UniqueRef<IFile>();

                                    controlFs?.OpenFile(ref icon.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();

                                    using MemoryStream stream = new();

                                    icon.Get.AsStream().CopyTo(stream);
                                    gameInfo.Icon = stream.ToArray();

                                    if (gameInfo.Icon != null)
                                    {
                                        break;
                                    }
                                }

                            }
                        }
                    }
                    else if (extension == "nro")
                    {
                        BinaryReader reader = new(gameStream);

                        byte[] Read(long position, int size)
                        {
                            gameStream.Seek(position, SeekOrigin.Begin);

                            return reader.ReadBytes(size);
                        }

                        gameStream.Seek(24, SeekOrigin.Begin);

                        int assetOffset = reader.ReadInt32();

                        if (Encoding.ASCII.GetString(Read(assetOffset, 4)) == "ASET")
                        {
                            byte[] iconSectionInfo = Read(assetOffset + 8, 0x10);

                            long iconOffset = BitConverter.ToInt64(iconSectionInfo, 0);
                            long iconSize = BitConverter.ToInt64(iconSectionInfo, 8);

                            ulong nacpOffset = reader.ReadUInt64();
                            ulong nacpSize = reader.ReadUInt64();

                            // Reads and stores game icon as byte array
                            if (iconSize > 0)
                            {
                                gameInfo.Icon = Read(assetOffset + iconOffset, (int)iconSize);
                            }

                            // Read the NACP data
                            Read(assetOffset + (int)nacpOffset, (int)nacpSize).AsSpan().CopyTo(controlHolder.ByteSpan);

                            GetGameInformation(ref controlHolder.Value, out gameInfo.TitleName, out gameInfo.TitleId, out gameInfo.Developer, out gameInfo.Version);
                        }
                    }
                }
                catch (MissingKeyException exception)
                {
                    Logger.Warning?.Print(LogClass.Application, $"Your key set is missing a key with the name: {exception.Name}");
                }
                catch (InvalidDataException exception)
                {
                    Logger.Warning?.Print(LogClass.Application, $"The header key is incorrect or missing and therefore the NCA header content type check has failed. {exception}");
                }
                catch (Exception exception)
                {
                    Logger.Warning?.Print(LogClass.Application, $"The gameStream encountered was not of a valid type. Error: {exception}");

                    return null;
                }
            }
            catch (IOException exception)
            {
                Logger.Warning?.Print(LogClass.Application, exception.Message);
            }

            void ReadControlData(IFileSystem? controlFs, Span<byte> outProperty)
            {
                using UniqueRef<IFile> controlFile = new();

                controlFs?.OpenFile(ref controlFile.Ref, "/control.nacp".ToU8Span(), OpenMode.Read).ThrowIfFailure();
                controlFile.Get.Read(out _, 0, outProperty, ReadOption.None).ThrowIfFailure();
            }

            void GetGameInformation(ref ApplicationControlProperty controlData, out string? titleName, out string titleId, out string? publisher, out string? version)
            {
                _ = Enum.TryParse(TitleLanguage.ToString(), out TitleLanguage desiredTitleLanguage);

                if (controlData.Title.ItemsRo.Length > (int)desiredTitleLanguage)
                {
                    titleName = controlData.Title[(int)desiredTitleLanguage].NameString.ToString();
                    publisher = controlData.Title[(int)desiredTitleLanguage].PublisherString.ToString();
                }
                else
                {
                    titleName = null;
                    publisher = null;
                }

                if (string.IsNullOrWhiteSpace(titleName))
                {
                    foreach (ref readonly var controlTitle in controlData.Title.ItemsRo)
                    {
                        if (!controlTitle.NameString.IsEmpty())
                        {
                            titleName = controlTitle.NameString.ToString();

                            break;
                        }
                    }
                }

                if (string.IsNullOrWhiteSpace(publisher))
                {
                    foreach (ref readonly var controlTitle in controlData.Title.ItemsRo)
                    {
                        if (!controlTitle.PublisherString.IsEmpty())
                        {
                            publisher = controlTitle.PublisherString.ToString();

                            break;
                        }
                    }
                }

                if (controlData.PresenceGroupId != 0)
                {
                    titleId = controlData.PresenceGroupId.ToString("x16");
                }
                else if (controlData.SaveDataOwnerId != 0)
                {
                    titleId = controlData.SaveDataOwnerId.ToString();
                }
                else if (controlData.AddOnContentBaseId != 0)
                {
                    titleId = (controlData.AddOnContentBaseId - 0x1000).ToString("x16");
                }
                else
                {
                    titleId = "0000000000000000";
                }

                version = controlData.DisplayVersionString.ToString();
            }

            void GetControlFsAndTitleId(IFileSystem pfs, out IFileSystem? controlFs, out string? titleId)
            {
                (_, _, Nca? controlNca) = GetGameData(_virtualFileSystem, pfs, 0);

                if (controlNca == null)
                {
                    Logger.Warning?.Print(LogClass.Application, "Control NCA is null. Unable to load control FS.");
                }

                // Return the ControlFS
                controlFs = controlNca?.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.None);
                titleId = controlNca?.Header.TitleId.ToString("x16");
            }

            (Nca? mainNca, Nca? patchNca, Nca? controlNca) GetGameData(VirtualFileSystem fileSystem, IFileSystem pfs, int programIndex)
            {
                Nca? mainNca = null;
                Nca? patchNca = null;
                Nca? controlNca = null;

                fileSystem.ImportTickets(pfs);

                foreach (DirectoryEntryEx fileEntry in pfs.EnumerateEntries("/", "*.nca"))
                {
                    using var ncaFile = new UniqueRef<IFile>();

                    Logger.Info?.Print(LogClass.Application, $"Loading file from PFS: {fileEntry.FullPath}");

                    pfs.OpenFile(ref ncaFile.Ref, fileEntry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();

                    Nca nca = new(fileSystem.KeySet, ncaFile.Release().AsStorage());

                    int ncaProgramIndex = (int)(nca.Header.TitleId & 0xF);

                    if (ncaProgramIndex != programIndex)
                    {
                        continue;
                    }

                    if (nca.Header.ContentType == NcaContentType.Program)
                    {
                        int dataIndex = Nca.GetSectionIndexFromType(NcaSectionType.Data, NcaContentType.Program);

                        if (nca.SectionExists(NcaSectionType.Data) && nca.Header.GetFsHeader(dataIndex).IsPatchSection())
                        {
                            patchNca = nca;
                        }
                        else
                        {
                            mainNca = nca;
                        }
                    }
                    else if (nca.Header.ContentType == NcaContentType.Control)
                    {
                        controlNca = nca;
                    }
                }

                return (mainNca, patchNca, controlNca);
            }

            bool IsUpdateApplied(string? titleId, out IFileSystem? updatedControlFs)
            {
                updatedControlFs = null;

                string? updatePath = "(unknown)";

                if (_virtualFileSystem == null)
                {
                    Logger.Error?.Print(LogClass.Application, "SwitchDevice was not initialized.");
                    return false;
                }

                try
                {
                    (Nca? patchNca, Nca? controlNca) = GetGameUpdateData(_virtualFileSystem, titleId, 0, out updatePath);

                    if (patchNca != null && controlNca != null)
                    {
                        updatedControlFs = controlNca.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.None);

                        return true;
                    }
                }
                catch (InvalidDataException)
                {
                    Logger.Warning?.Print(LogClass.Application, $"The header key is incorrect or missing and therefore the NCA header content type check has failed. Errored File: {updatePath}");
                }
                catch (MissingKeyException exception)
                {
                    Logger.Warning?.Print(LogClass.Application, $"Your key set is missing a key with the name: {exception.Name}. Errored File: {updatePath}");
                }

                return false;
            }

            (Nca? patch, Nca? control) GetGameUpdateData(VirtualFileSystem fileSystem, string? titleId, int programIndex, out string? updatePath)
            {
                updatePath = "";

                if (ulong.TryParse(titleId, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out ulong titleIdBase))
                {
                    // Clear the program index part.
                    titleIdBase &= ~0xFUL;

                    // Load update information if exists.
                    string titleUpdateMetadataPath = Path.Combine(AppDataManager.GamesDirPath, titleIdBase.ToString("x16"), "updates.json");

                    if (File.Exists(titleUpdateMetadataPath))
                    {
                        string updatePathRelative = JsonHelper.DeserializeFromFile(titleUpdateMetadataPath, _titleSerializerContext.TitleUpdateMetadata).Selected;
                        updatePath = Path.Combine(AppDataManager.BaseDirPath, updatePathRelative);

                        if (File.Exists(updatePath))
                        {
                            FileStream file = new(updatePath, FileMode.Open, FileAccess.Read);
                            PartitionFileSystem nsp = new();
                            nsp.Initialize(file.AsStorage()).ThrowIfFailure();

                            return GetGameUpdateDataFromPartition(fileSystem, nsp, titleIdBase.ToString("x16"), programIndex);
                        }
                    }
                }

                return (null, null);
            }

            (Nca? patchNca, Nca? controlNca) GetGameUpdateDataFromPartition(VirtualFileSystem fileSystem, PartitionFileSystem pfs, string titleId, int programIndex)
            {
                Nca? patchNca = null;
                Nca? controlNca = null;

                fileSystem.ImportTickets(pfs);

                foreach (DirectoryEntryEx fileEntry in pfs.EnumerateEntries("/", "*.nca"))
                {
                    using var ncaFile = new UniqueRef<IFile>();

                    pfs.OpenFile(ref ncaFile.Ref, fileEntry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();

                    Nca nca = new(fileSystem.KeySet, ncaFile.Release().AsStorage());

                    int ncaProgramIndex = (int)(nca.Header.TitleId & 0xF);

                    if (ncaProgramIndex != programIndex)
                    {
                        continue;
                    }

                    if ($"{nca.Header.TitleId.ToString("x16")[..^3]}000" != titleId)
                    {
                        break;
                    }

                    if (nca.Header.ContentType == NcaContentType.Program)
                    {
                        patchNca = nca;
                    }
                    else if (nca.Header.ContentType == NcaContentType.Control)
                    {
                        controlNca = nca;
                    }
                }

                return (patchNca, controlNca);
            }

            return gameInfo;
        }

        static ControllerType GetControllerTypeByIndex(Options optionsInstance, int index)
        {
            if (index < 0 || index > 7)
                throw new ArgumentOutOfRangeException(nameof(index), "Index must be between 0 and 7.");

            string propertyName = $"controllerType{index + 1}";
            var property = typeof(Options).GetProperty(propertyName);

            if (property == null)
                throw new InvalidOperationException($"Property '{propertyName}' not found in Options.");

            return (ControllerType)property.GetValue(optionsInstance);
        }

        static ControllerType GetControllerTypeByIndex(ControllerOptions optionsInstance, int index)
        {
            if (index < 0 || index > 7)
                throw new ArgumentOutOfRangeException(nameof(index), "Index must be between 0 and 7.");

            string propertyName = $"controllerType{index + 1}";
            var property = typeof(ControllerOptions).GetProperty(propertyName);

            if (property == null)
                throw new InvalidOperationException($"Property '{propertyName}' not found in ControllerOptions.");

            return (ControllerType)property.GetValue(optionsInstance);
        }
        
#nullable enable
        private static InputConfig HandlePlayerConfiguration(string inputProfileName, string inputId, string inputDSUServer, PlayerIndex index, Options? option, ControllerOptions? controllerOptions = null)
#nullable disable
        {
            if (inputId == null)
            {
                Logger.Info?.Print(LogClass.Application, $"{index} not configured");

                return null;
            }

            IGamepad gamepad;

            bool isKeyboard = true;

            gamepad = _inputManager.KeyboardDriver.GetGamepad(inputId);

            if (gamepad == null)
            {
                gamepad = _inputManager.GamepadDriver.GetGamepad(inputId);
                isKeyboard = false;

                if (gamepad == null)
                {
                    Logger.Error?.Print(LogClass.Application, $"{index} gamepad not found (\"{inputId}\")");

                    inputId = "0";

                    gamepad = _inputManager.KeyboardDriver.GetGamepad(inputId);

                    isKeyboard = true;
                }
            }


            gamepad.Dispose();

            InputConfig config;

            if (inputProfileName == null || inputProfileName.Equals("default"))
            {
                if (isKeyboard)
                {
                    config = new StandardKeyboardInputConfig
                    {
                        Version = InputConfig.CurrentVersion,
                        Backend = InputBackendType.WindowKeyboard,
                        Id = null,
                        ControllerType = ControllerType.JoyconPair,
                        LeftJoycon = new LeftJoyconCommonConfig<Key>
                        {
                            DpadUp = Key.Up,
                            DpadDown = Key.Down,
                            DpadLeft = Key.Left,
                            DpadRight = Key.Right,
                            ButtonMinus = Key.Minus,
                            ButtonL = Key.E,
                            ButtonZl = Key.Q,
                            ButtonSl = Key.Unbound,
                            ButtonSr = Key.Unbound,
                        },

                        LeftJoyconStick = new JoyconConfigKeyboardStick<Key>
                        {
                            StickUp = Key.W,
                            StickDown = Key.S,
                            StickLeft = Key.A,
                            StickRight = Key.D,
                            StickButton = Key.F,
                        },

                        RightJoycon = new RightJoyconCommonConfig<Key>
                        {
                            ButtonA = Key.Z,
                            ButtonB = Key.X,
                            ButtonX = Key.C,
                            ButtonY = Key.V,
                            ButtonPlus = Key.Plus,
                            ButtonR = Key.U,
                            ButtonZr = Key.O,
                            ButtonSl = Key.Unbound,
                            ButtonSr = Key.Unbound,
                        },

                        RightJoyconStick = new JoyconConfigKeyboardStick<Key>
                        {
                            StickUp = Key.I,
                            StickDown = Key.K,
                            StickLeft = Key.J,
                            StickRight = Key.L,
                            StickButton = Key.H,
                        },
                    };
                }
                else
                {
                    bool isNintendoStyle = true; // gamepadName.Contains("Nintendo") || gamepadName.Contains("Joycons");

                    ControllerType currentController;

                    if (index == PlayerIndex.Handheld)
                    {
                        currentController = ControllerType.Handheld;
                    }
                    else
                    {
                        if (option == null)
                        {
                            if (controllerOptions != null)
                            {
                                currentController = GetControllerTypeByIndex(controllerOptions, (int)index);
                            }
                            else
                            {
                                currentController = ControllerType.JoyconPair;
                            }
                        } else
                        {
                            currentController = GetControllerTypeByIndex(option, (int)index);
                        }
                    }

                    Console.WriteLine($"Configuring {inputId} as {currentController} ({index})");

                    config = new StandardControllerInputConfig
                    {
                        Version = InputConfig.CurrentVersion,
                        Backend = InputBackendType.GamepadSDL2,
                        Id = null,
                        ControllerType = currentController,
                        DeadzoneLeft = 0.1f,
                        DeadzoneRight = 0.1f,
                        RangeLeft = 1.0f,
                        RangeRight = 1.0f,
                        TriggerThreshold = 0.5f,
                        LeftJoycon = new LeftJoyconCommonConfig<ConfigGamepadInputId>
                        {
                            DpadUp = ConfigGamepadInputId.DpadUp,
                            DpadDown = ConfigGamepadInputId.DpadDown,
                            DpadLeft = ConfigGamepadInputId.DpadLeft,
                            DpadRight = ConfigGamepadInputId.DpadRight,
                            ButtonMinus = ConfigGamepadInputId.Minus,
                            ButtonL = ConfigGamepadInputId.LeftShoulder,
                            ButtonZl = ConfigGamepadInputId.LeftTrigger,
                            ButtonSl = ConfigGamepadInputId.Unbound,
                            ButtonSr = ConfigGamepadInputId.Unbound,
                        },

                        LeftJoyconStick = new JoyconConfigControllerStick<ConfigGamepadInputId, ConfigStickInputId>
                        {
                            Joystick = ConfigStickInputId.Left,
                            StickButton = ConfigGamepadInputId.LeftStick,
                            InvertStickX = false,
                            InvertStickY = false,
                            Rotate90CW = false,
                        },

                        RightJoycon = new RightJoyconCommonConfig<ConfigGamepadInputId>
                        {
                            ButtonA = isNintendoStyle ? ConfigGamepadInputId.A : ConfigGamepadInputId.B,
                            ButtonB = isNintendoStyle ? ConfigGamepadInputId.B : ConfigGamepadInputId.A,
                            ButtonX = isNintendoStyle ? ConfigGamepadInputId.X : ConfigGamepadInputId.Y,
                            ButtonY = isNintendoStyle ? ConfigGamepadInputId.Y : ConfigGamepadInputId.X,
                            ButtonPlus = ConfigGamepadInputId.Plus,
                            ButtonR = ConfigGamepadInputId.RightShoulder,
                            ButtonZr = ConfigGamepadInputId.RightTrigger,
                            ButtonSl = ConfigGamepadInputId.Unbound,
                            ButtonSr = ConfigGamepadInputId.Unbound,
                        },

                        RightJoyconStick = new JoyconConfigControllerStick<ConfigGamepadInputId, ConfigStickInputId>
                        {
                            Joystick = ConfigStickInputId.Right,
                            StickButton = ConfigGamepadInputId.RightStick,
                            InvertStickX = false,
                            InvertStickY = false,
                            Rotate90CW = false,
                        },

                        Motion = new StandardMotionConfigController
                        {
                            MotionBackend = MotionInputBackendType.GamepadDriver,
                            EnableMotion = true,
                            Sensitivity = 100,
                            GyroDeadzone = 1,
                        },
                        Rumble = new RumbleConfigController
                        {
                            StrongRumble = 1f,
                            WeakRumble = 1f,
                            EnableRumble = true,
                        },
                    };
                }
            }
            else
            {
                string profileBasePath;

                if (isKeyboard)
                {
                    profileBasePath = Path.Combine(AppDataManager.ProfilesDirPath, "keyboard");
                }
                else
                {
                    profileBasePath = Path.Combine(AppDataManager.ProfilesDirPath, "controller");
                }

                string path = Path.Combine(profileBasePath, inputProfileName + ".json");

                if (!File.Exists(path))
                {
                    Logger.Error?.Print(LogClass.Application, $"Input profile \"{inputProfileName}\" not found for \"{inputId}\"");

                    return null;
                }

                try
                {
                    config = JsonHelper.DeserializeFromFile(path, _serializerContext.InputConfig);
                }
                catch (JsonException)
                {
                    Logger.Error?.Print(LogClass.Application, $"Input profile \"{inputProfileName}\" parsing failed for \"{inputId}\"");

                    return null;
                }
            }

            config.Id = inputId;
            config.PlayerIndex = index;

            string inputTypeName = isKeyboard ? "Keyboard" : "Gamepad";

            Logger.Info?.Print(LogClass.Application, $"{config.PlayerIndex} configured with {inputTypeName} \"{config.Id}\"");

            // If both stick ranges are 0 (usually indicative of an outdated profile load) then both sticks will be set to 1.0.
            if (config is StandardControllerInputConfig controllerConfig)
            {
                if (controllerConfig.RangeLeft <= 0.0f && controllerConfig.RangeRight <= 0.0f)
                {
                    controllerConfig.RangeLeft = 1.0f;
                    controllerConfig.RangeRight = 1.0f;

                    Logger.Info?.Print(LogClass.Application, $"{config.PlayerIndex} stick range reset. Save the profile now to update your configuration");
                }
            }

            return config;
        }

        static void Load(Options option)
        {
            try
            {
                LoadInner(option);
            }
            catch (Exception ex)
            {
                ReportMainException("Program.Load", ex);
                ReportBootFailure("Program.Load", ex);
                throw;
            }
        }

        static void LoadInner(Options option)
        {
            BootEventBridge.Report("[MAIN] stage", "LoadInner entered");

            // REVERTED (regression found and confirmed by diff against
            // b11a4596f - "diff causal"): this round's audit guarded
            // this block behind `if (_libHacHorizonManager == null)`,
            // reasoning that Initialize() (the "initialize" native
            // export, called once at app startup from Swift's
            // AppModeRouterView) already does this exact setup, so
            // repeating it here on every LoadInner() call was a leak.
            // That reasoning was correct in isolation, but this is the
            // ONLY change in b11a4596f that touches any code reachable
            // between "Program.Main entered" and ExecutionEntrypoint()
            // - and the regression report shows mainRyu returning -1
            // ~20ms after entry, with NONE of ExecutionEntrypoint's own
            // stage markers ("window initialize begin" etc.) present,
            // meaning the failure is upstream of it, inside Load()/
            // LoadInner() - i.e. inside or immediately after exactly
            // this block. Unconditionally re-running
            // InitializeFsServer/InitializeArpServer/InitializeBcatServer/
            // InitializeSystemClients here is what every previously-
            // working build did; reverting to that exact behavior is
            // the safest, most targeted fix available without a real
            // device to capture the actual exception type/message this
            // guard was producing (now instrumented below and in
            // MainExternal's catch block specifically so a future
            // regression like this one is never silently a bare "-1"
            // again). The real per-game leak this guard was trying to
            // fix (constructing a new LibHac.Horizon kernel instance
            // each launch) remains a known, lower-priority issue -
            // documented, not silently reintroduced without a trace.
            _libHacHorizonManager = new LibHacHorizonManager();
            BootEventBridge.Report("[MAIN] stage", "LibHacHorizonManager constructed");
            _libHacHorizonManager.InitializeFsServer(_virtualFileSystem);
            BootEventBridge.Report("[MAIN] stage", "LibHac FS server initialized");
            _libHacHorizonManager.InitializeArpServer();
            BootEventBridge.Report("[MAIN] stage", "LibHac ARP server initialized");
            _libHacHorizonManager.InitializeBcatServer();
            BootEventBridge.Report("[MAIN] stage", "LibHac BCAT server initialized");
            _libHacHorizonManager.InitializeSystemClients();
            BootEventBridge.Report("libHacInitialized", "true");

            // _contentManager = new ContentManager(_virtualFileSystem);

            _accountManager = new AccountManager(_libHacHorizonManager.RyujinxClient, option.UserProfile);

            _userChannelPersistence = new UserChannelPersistence();

            GraphicsConfig.EnableShaderCache = true;

            if (OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                if (option.GraphicsBackend == GraphicsBackend.OpenGl)
                {
                    option.GraphicsBackend = GraphicsBackend.Vulkan;
                    Logger.Warning?.Print(LogClass.Application, "OpenGL is not supported on Apple platforms, switching to Vulkan!");
                }
            }

            IGamepad gamepad;

            if (option.ListInputIds)
            {
                Logger.Info?.Print(LogClass.Application, "Input Ids:");

                foreach (string id in _inputManager.KeyboardDriver.GamepadsIds)
                {
                    gamepad = _inputManager.KeyboardDriver.GetGamepad(id);

                    Logger.Info?.Print(LogClass.Application, $"- {id} (\"{gamepad.Name}\")");

                    gamepad.Dispose();
                }

               string[] gamepadsIdsArray = _inputManager.GamepadDriver.GamepadsIds.ToArray();

                foreach (string id in gamepadsIdsArray)
                {
                    gamepad = _inputManager.GamepadDriver.GetGamepad(id);

                    string gamepadsIdsString = $"- {id} (\"{gamepad.Name}\")";

                    Logger.Info?.Print(LogClass.Application, gamepadsIdsString);

                    gamepad.Dispose();
                }

                return;
            }

            if (option.InputPath == null)
            {
                Logger.Error?.Print(LogClass.Application, "Please provide a file to load");

                return;
            }
            

            Match match = Regex.Match(option.InputPath, @"0x[0-9A-Fa-f]+");
            if (match.Success)
            {
                string hexStr = match.Value.Substring(2);
                ulong id = Convert.ToUInt64(hexStr, 16);
                string contentPath = _contentManager.GetInstalledContentPath(id, StorageId.BuiltInSystem, NcaContentType.Program);

                option.InputPath = contentPath;
            }

            _inputConfiguration = new List<InputConfig>();
            _enableKeyboard = option.EnableKeyboard;
            _enableMouse = option.EnableMouse;

            static void LoadPlayerConfiguration(string inputProfileName, string inputId, string inputDSUServer, PlayerIndex index, Options option)
            {
                if (inputId == null)
                {
                    return;
                }

                InputConfig inputConfig = HandlePlayerConfiguration(inputProfileName, inputId, inputDSUServer, index, option);

                if (inputConfig != null)
                {
                    _inputConfiguration.Add(inputConfig);
                }
            }

            LoadPlayerConfiguration(option.InputProfile1Name, option.InputId1, option.InputDSUServer1, PlayerIndex.Player1, option);
            LoadPlayerConfiguration(option.InputProfile2Name, option.InputId2, option.InputDSUServer2, PlayerIndex.Player2, option);
            LoadPlayerConfiguration(option.InputProfile3Name, option.InputId3, option.InputDSUServer3, PlayerIndex.Player3, option);
            LoadPlayerConfiguration(option.InputProfile4Name, option.InputId4, option.InputDSUServer4, PlayerIndex.Player4, option);
            LoadPlayerConfiguration(option.InputProfile5Name, option.InputId5, option.InputDSUServer5, PlayerIndex.Player5, option);
            LoadPlayerConfiguration(option.InputProfile6Name, option.InputId6, option.InputDSUServer6, PlayerIndex.Player6, option);
            LoadPlayerConfiguration(option.InputProfile7Name, option.InputId7, option.InputDSUServer7, PlayerIndex.Player7, option);
            LoadPlayerConfiguration(option.InputProfile8Name, option.InputId8, option.InputDSUServer8, PlayerIndex.Player8, option);
            LoadPlayerConfiguration(option.InputProfileHandheldName, option.InputIdHandheld, option.InputDSUServerHandheld, PlayerIndex.Handheld, option);

            if (_inputConfiguration.Count == 0)
            {
                return;
            }

            // Setup logging level
            Logger.SetEnable(LogLevel.Debug, option.LoggingEnableDebug);
            Logger.SetEnable(LogLevel.Stub, !option.LoggingDisableStub);
            Logger.SetEnable(LogLevel.Info, !option.LoggingDisableInfo);
            Logger.SetEnable(LogLevel.Warning, !option.LoggingDisableWarning);
            Logger.SetEnable(LogLevel.Error, option.LoggingEnableError);
            Logger.SetEnable(LogLevel.Trace, option.LoggingEnableTrace);
            Logger.SetEnable(LogLevel.Guest, !option.LoggingDisableGuest);
            Logger.SetEnable(LogLevel.AccessLog, option.LoggingEnableFsAccessLog);

            if (!option.DisableFileLog)
            {
                string logDir = AppDataManager.LogsDirPath;
                FileStream logFile = null;

                if (!string.IsNullOrEmpty(logDir))
                {
                    logFile = FileLogTarget.PrepareLogFile(logDir);
                }

                if (logFile != null)
                {
                    //Logger.AddTarget(new AsyncLogTargetWrapper(
                    //    new FileLogTarget("file", logFile),
                    //    1000,
                    //    AsyncLogTargetOverflowAction.Block
                    // ));
                }
                else
                {
                    Logger.Error?.Print(LogClass.Application, "No writable log directory available. Make sure either the Logs directory, Application Data, or the Ryujinx directory is writable.");
                }
            }

            if (OperatingSystem.IsIOS()) 
            {
                Logger.Info?.Print(LogClass.Application, $"Current Device: {option.DisplayName} ({option.DeviceModel}) {Environment.OSVersion.Version}");
                Logger.Info?.Print(LogClass.Application, $"Increased Memory Limit: {option.MemoryEnt}");
            }

            AppDomain.CurrentDomain.UnhandledException += (sender, e) =>
            {
                var ex = e.ExceptionObject as Exception;
                var trace = new System.Diagnostics.StackTrace(ex, true);
                var frame = trace.GetFrame(0);
                var file = frame?.GetFileName();
                var line = frame?.GetFileLineNumber();

                Logger.Info?.Print(LogClass.Application,
                    $"Unhandled exception: {ex}\nFile: {file}\nLine: {line}");

            };


            // Setup graphics configuration
            GraphicsConfig.EnableShaderCache = !option.DisableShaderCache;
            GraphicsConfig.EnableTextureRecompression = option.EnableTextureRecompression;
            GraphicsConfig.ResScale = option.ResScale;
            GraphicsConfig.MaxAnisotropy = option.MaxAnisotropy;
            GraphicsConfig.ShadersDumpPath = option.GraphicsShadersDumpPath;
            GraphicsConfig.EnableMacroHLE = !option.DisableMacroHLE;
            GraphicsConfig.EnableColorSpacePassthrough = true;

            DriverUtilities.InitDriverConfig(option.BackendThreading == BackendThreading.Off);
            _virtualFileSystem.ReloadKeySet();
            BootEventBridge.Report("vfsInitialized", "true");
            BootEventBridge.Report("[MAIN] stage", "VFS key set reloaded");
            ReportBootEvent("configuration initialized");
            BootEventBridge.Report("configurationInitialized", "true");
            while (true)
            {
                BootEventBridge.Report("applicationLoadStarted", "true");
                BootEventBridge.Report("[MAIN] stage", "LoadApplication begin");
                LoadApplication(option);

                if (_userChannelPersistence.PreviousIndex == -1 || !_userChannelPersistence.ShouldRestart)
                {
                    break;
                }

                _userChannelPersistence.ShouldRestart = false;
            }

            _inputManager.Dispose();
        }

        private static void SetupProgressHandler()
        {
            if (_emulationContext.Processes.ActiveApplication.DiskCacheLoadState != null)
            {
                _emulationContext.Processes.ActiveApplication.DiskCacheLoadState.StateChanged -= ProgressHandler;
                _emulationContext.Processes.ActiveApplication.DiskCacheLoadState.StateChanged += ProgressHandler;
            }

            _emulationContext.Gpu.ShaderCacheStateChanged -= ProgressHandler;
            _emulationContext.Gpu.ShaderCacheStateChanged += ProgressHandler;
        }

        private static void ProgressHandler<T>(T state, int current, int total) where T : Enum
        {
            // string label = state switch
            // {
            //    LoadState => $"PTC : {current}/{total}",
            //    ShaderCacheState => $"Shaders : {current}/{total}",
            //    _ => throw new ArgumentException($"Unknown Progress Handler type {typeof(T)}"),
            // };

            string jsonData = state switch
            {
                LoadState => $"[\"PTC\",{current},{total}]",
                ShaderCacheState => $"[\"Shaders\",{current},{total}]",
                _ => throw new ArgumentException($"Unknown Progress Handler type {typeof(T)}"),
            };

            // Convert to UTF-8 bytes
            byte[] jsonBytes = Encoding.UTF8.GetBytes(jsonData);

            // Allocate unmanaged memory and send
            IntPtr unmanagedPointer = Marshal.AllocHGlobal(jsonBytes.Length);
            try
            {
                Marshal.Copy(jsonBytes, 0, unmanagedPointer, jsonBytes.Length);

                TriggerCallbackWithData(
                    "ProgressWithPTCorShaderCache",
                    unmanagedPointer,
                    (UIntPtr)jsonBytes.Length
                );
            }
            finally
            {
                Marshal.FreeHGlobal(unmanagedPointer);
            }

            // Logger.Info?.Print(LogClass.Application, label);
        }

        private static WindowBase CreateWindow(Options options)
        {
            if (OperatingSystem.IsIOS()) {
                return new MoltenVKWindow(_inputManager, options.LoggingGraphicsDebugLevel, options.AspectRatio, options.EnableMouse, options.HideCursorMode);
            }
            else 
            {
                return options.GraphicsBackend == GraphicsBackend.Vulkan
                    ? new VulkanWindow(_inputManager, options.LoggingGraphicsDebugLevel, options.AspectRatio, options.EnableMouse, options.HideCursorMode)
                    : new OpenGLWindow(_inputManager, options.LoggingGraphicsDebugLevel, options.AspectRatio, options.EnableMouse, options.HideCursorMode);
            }
        }

        private static IRenderer CreateRenderer(Options options, WindowBase window)
        {
            if (options.GraphicsBackend == GraphicsBackend.Vulkan)
            {
                string preferredGpuId = string.Empty;
                Vk api = Vk.GetApi();

                // Handle GPU preference selection
                if (!string.IsNullOrEmpty(options.PreferredGPUVendor))
                {
                    string preferredGpuVendor = options.PreferredGPUVendor.ToLowerInvariant();
                    var devices = VulkanRenderer.GetPhysicalDevices(api);

                    foreach (var device in devices)
                    {
                        if (device.Vendor.ToLowerInvariant() == preferredGpuVendor)
                        {
                            preferredGpuId = device.Id;
                            break;
                        }
                    }
                }

                if (window is VulkanWindow vulkanWindow)
                {
                    return new VulkanRenderer(
                        api,
                        (instance, vk) => new SurfaceKHR((ulong)(vulkanWindow.CreateWindowSurface(instance.Handle))),
                        vulkanWindow.GetRequiredInstanceExtensions,
                        preferredGpuId);
                }
                else if (window is MoltenVKWindow mvulkanWindow)
                {
                    return new VulkanRenderer(
                        api,
                        (instance, vk) => new SurfaceKHR((ulong)(mvulkanWindow.CreateWindowSurface(instance.Handle))),
                        mvulkanWindow.GetRequiredInstanceExtensions,
                        preferredGpuId);
                }
            }

            // Fallback to OpenGL renderer if Vulkan is not used
            return new OpenGLRenderer();
        }

        private static Switch InitializeEmulationContext(WindowBase window, IRenderer renderer, Options options)
        {
            BackendThreading threadingMode = options.BackendThreading;

            renderer = new ThreadedRenderer(renderer);

            bool AppleHV = false;

            if ((!OperatingSystem.IsIOSVersionAtLeast(16, 4)) && options.UseHypervisor) 
            {
                AppleHV = true;
            }
            else if (OperatingSystem.IsIOS()) 
            {
                AppleHV = false;
            } else {
                AppleHV = options.UseHypervisor;
            }

            // idk :3
            HLE.HOS.Services.Nifm.StaticService.AnyInternetRequestAccepted.isAnyInternetRequestAccepted = options.EnableInternetAccess;

            HLEConfiguration configuration = new(_virtualFileSystem,
                _libHacHorizonManager,
                _contentManager,
                _accountManager,
                _userChannelPersistence,
                renderer,
                new SDL2HardwareDeviceDriver(), // AppleHardwareDeviceDriver(), // Will rework Apple Audio later.
                options.ExpandRAM ? MemoryConfiguration.MemoryConfiguration8GiB : MemoryConfiguration.MemoryConfiguration4GiB,
                window,
                options.SystemLanguage,
                options.SystemRegion,
                !options.DisableVSync,
                !options.DisableDockedMode,
                !options.DisablePTC,
                options.EnableInternetAccess,
                !options.DisableFsIntegrityChecks ? IntegrityCheckLevel.ErrorOnInvalid : IntegrityCheckLevel.None,
                options.FsGlobalAccessLogMode,
                options.SystemTimeOffset,
                options.SystemTimeZone,
                options.MemoryManagerMode,
                options.IgnoreMissingServices,
                options.AspectRatio,
                options.AudioVolume,
                AppleHV,
                options.MultiplayerLanInterfaceId,
                options.ldnMitm ? MultiplayerMode.LdnMitm : MultiplayerMode.Disabled);

            return new Switch(configuration);
        }

        private static void ExecutionEntrypoint()
        {
            int sessionId = System.Threading.Interlocked.Increment(ref _gameSessionId);
            BootEventBridge.Report($"[SESSION {sessionId}] start");

            // See _sessionFullyTornDown's doc comment - this marks the
            // barrier as "not satisfied yet" for the ENTIRE duration of
            // this session, from here until the finally block below sets
            // it again (on every exit path, including an exception).
            _sessionFullyTornDown.Reset();

            try
            {
                if (OperatingSystem.IsWindows())
                {
                    _windowsMultimediaTimerResolution = new WindowsMultimediaTimerResolution(1);
                }

                DisplaySleep.Prevent();

                ReportBootEvent("window initialize begin");
                try
                {
                    _window.Initialize(_emulationContext, _inputConfiguration, _enableKeyboard, _enableMouse);
                }
                catch (Exception ex)
                {
                    ReportBootFailure("ExecutionEntrypoint.window initialize", ex);
                    throw;
                }
                ReportBootEvent("window initialized");
                BootEventBridge.Report($"[SESSION {sessionId}] renderer created");

                ReportBootEvent("window execute begin");
                BootEventBridge.Report($"[SESSION {sessionId}] game running");
                try
                {
                    _window.Execute();
                }
                catch (Exception ex)
                {
                    ReportBootFailure("ExecutionEntrypoint.window execute", ex);
                    throw;
                }

                // _window.Execute() only returns after _window.Exit() (see
                // StopEmulation) has driven MainLoop()'s while-loop to
                // exit - i.e. the render loop has genuinely stopped.
                BootEventBridge.Report($"[SESSION {sessionId}] render thread exited");

                BootEventBridge.Report("ExecutionEntrypoint emulationContext dispose begin");
                _emulationContext.Dispose();
                BootEventBridge.Report("ExecutionEntrypoint emulationContext dispose end");
                BootEventBridge.Report($"[SESSION {sessionId}] renderer disposed");
                _window.Dispose();

                if (OperatingSystem.IsWindows())
                {
                    _windowsMultimediaTimerResolution?.Dispose();
                    _windowsMultimediaTimerResolution = null;
                }
            }
            finally
            {
                BootEventBridge.Report($"[SESSION {sessionId}] teardown completed");

                // Always runs, including on an exception path above - a
                // failed session must still release the barrier, or every
                // future StopEmulation() call would block for its full
                // timeout for no reason.
                _sessionFullyTornDown.Set();
            }
        }

        private static bool LoadApplication(Options options)
        {
            string path = options.InputPath;

            Logger.RestartTime();

            ReportBootEvent("renderer selection begin");
            ReportBootEvent("renderer = " + (OperatingSystem.IsIOS() ? "MoltenVK (Vulkan)" : options.GraphicsBackend.ToString()));

            ReportBootEvent("GPU initialization begin");
            BootEventBridge.Report("deviceInitializationStarted", "true");
            BootEventBridge.Report("[MAIN] stage", "GPU/device initialization begin");
            WindowBase window = CreateWindow(options);

            if (window is MoltenVKWindow mvulkanWindow) {
                mvulkanWindow.SetNativeWindow(nativeMetalLayer);
            }

            IRenderer renderer = CreateRenderer(options, window);
            ReportBootEvent("renderer created");

            _window = window;

            _window.IsFullscreen = options.IsFullscreen;
            _window.DisplayId = options.DisplayId;
            _window.IsExclusiveFullscreen = options.IsExclusiveFullscreen;
            _window.ExclusiveFullscreenWidth = options.ExclusiveFullscreenWidth;
            _window.ExclusiveFullscreenHeight = options.ExclusiveFullscreenHeight;
            _window.AntiAliasing = options.AntiAliasing;
            _window.ScalingFilter = options.ScalingFilter;
            _window.ScalingFilterLevel = options.ScalingFilterLevel;
            renderer.Window?.SetColorSpacePassthrough(true);


            ReportBootEvent("HLE initialization begin");
            _emulationContext = InitializeEmulationContext(window, renderer, options);
            ReportBootEvent("HLE initialized");

            SystemVersion firmwareVersion = _contentManager.GetCurrentFirmwareVersion();
            ReportBootEvent("firmware initialized");

            Logger.Notice.Print(LogClass.Application, $"Using Firmware Version: {firmwareVersion?.VersionString}");

            bool isFirmwareTitle = false;

            if (path.StartsWith("@SystemContent"))
            {
                path = VirtualFileSystem.SwitchPathToSystemPath(path);

                isFirmwareTitle = true;
            }



            ReportBootEvent("game load begin");
            BootEventBridge.Report("guestInitializationStarted", "true");
            BootEventBridge.Report("[MAIN] stage", "guest/game load begin");

            try
            {
                if (Directory.Exists(path))
                {
                    string[] romFsFiles = Directory.GetFiles(path, "*.istorage");

                    if (romFsFiles.Length == 0)
                    {
                        romFsFiles = Directory.GetFiles(path, "*.romfs");
                    }

                    if (romFsFiles.Length > 0)
                    {
                        Logger.Info?.Print(LogClass.Application, "Loading as cart with RomFS.");

                        if (!_emulationContext.LoadCart(path, romFsFiles[0]))
                        {
                            _emulationContext.Dispose();

                            ReportBootEvent("game load failed", "LoadCart (with RomFS) returned false");
                            return false;
                        }
                    }
                    else
                    {
                        Logger.Info?.Print(LogClass.Application, "Loading as cart WITHOUT RomFS.");

                        if (!_emulationContext.LoadCart(path))
                        {
                            _emulationContext.Dispose();

                            ReportBootEvent("game load failed", "LoadCart returned false");
                            return false;
                        }
                    }
                }
                else if (File.Exists(path))
                {
                    switch (Path.GetExtension(path).ToLowerInvariant())
                    {
                        case ".xci":
                            Logger.Info?.Print(LogClass.Application, "Loading as XCI.");

                            if (!_emulationContext.LoadXci(path))
                            {
                                _emulationContext.Dispose();

                                ReportBootEvent("game load failed", "LoadXci returned false");
                                return false;
                            }
                            break;
                        case ".nca":
                            Logger.Info?.Print(LogClass.Application, "Loading as NCA.");

                            if (!_emulationContext.LoadNca(path))
                            {
                                _emulationContext.Dispose();

                                ReportBootEvent("game load failed", "LoadNca returned false");
                                return false;
                            }
                            break;
                        case ".nsp":
                        case ".pfs0":
                            Logger.Info?.Print(LogClass.Application, "Loading as NSP.");

                            if (!_emulationContext.LoadNsp(path))
                            {
                                _emulationContext.Dispose();

                                ReportBootEvent("game load failed", "LoadNsp returned false");
                                return false;
                            }
                            break;
                        default:
                            if (isFirmwareTitle) {
                                Logger.Info?.Print(LogClass.Application, "Loading as Firmware Title (NCA).");

                                if (!_emulationContext.LoadNca(path))
                                {
                                    _emulationContext.Dispose();

                                    ReportBootEvent("game load failed", "LoadNca (firmware title) returned false");
                                    return false;
                                }
                            }
                            else {
                                Logger.Info?.Print(LogClass.Application, "Loading as Homebrew.");
                                try
                                {
                                    if (!_emulationContext.LoadProgram(path))
                                    {
                                        _emulationContext.Dispose();

                                        ReportBootEvent("game load failed", "LoadProgram returned false");
                                        return false;
                                    }
                                }
                                catch (ArgumentOutOfRangeException)
                                {
                                    Logger.Error?.Print(LogClass.Application, "The specified file is not supported by Ryujinx.");

                                    _emulationContext.Dispose();

                                    ReportBootEvent("game load failed", "LoadProgram threw ArgumentOutOfRangeException - file not supported");
                                    return false;
                                }
                            }
                            break;
                    }
                }
                else
                {
                    Logger.Warning?.Print(LogClass.Application, $"Couldn't load '{options.InputPath}'. Please specify a valid XCI/NCA/NSP/PFS0/NRO file.");

                    _emulationContext.Dispose();

                    ReportBootEvent("game load failed", $"'{options.InputPath}' is not a valid XCI/NCA/NSP/PFS0/NRO file or directory");
                    return false;
                }
            }
            catch (Exception ex)
            {
                // Per instruction: never swallow the original exception -
                // report it, then rethrow unchanged. This is an outer net
                // around the dispatch above; the existing, more specific
                // ArgumentOutOfRangeException catch for LoadProgram is left
                // exactly as it was.
                ReportBootFailure("Program.LoadApplication", ex);
                throw;
            }

            ReportBootEvent("game load succeeded");

            // All Load*() branches above either `return false` on failure or
            // fall through here on success - reaching this point means the
            // executable is open and Horizon's kernel scheduler has already
            // created/scheduled the guest's main thread as part of that load
            // call. There is no separate, later "start the guest" call in
            // this file to instrument instead.
            ReportBootEvent("game file opened");
            ReportBootEvent("executable loaded");
            ReportBootEvent("guest execution begin");

            SetupProgressHandler();
            ExecutionEntrypoint();

            return true;
        }

        private static FileStream OpenFile(int descriptor)
        {
            var safeHandle = new SafeFileHandle(descriptor, false);

            return new FileStream(safeHandle, FileAccess.ReadWrite);
        }

        [StructLayout(LayoutKind.Sequential)]
        public unsafe struct AvatarInfo
        {
            public byte* ImageData;    
            public int ImageSize;     
            public sbyte* FileName;  
        }

        [StructLayout(LayoutKind.Sequential)]
        public unsafe struct AvatarArray
        {
            public int Count;          
            public AvatarInfo* Avatars; 
        }

        public class GameInfo
        {
            public double FileSize;
            public string? TitleName;
            public string? TitleId;
            public string? Developer;
            public string? Version;
            public byte[]? Icon;
        }

        public unsafe struct DlcNcaListItem 
        {
            public fixed byte Path[256];
            public ulong TitleId;
        }

        public unsafe struct DlcNcaList
        {
            public bool success;
            public uint size;
            public unsafe DlcNcaListItem* items;

        }

        public unsafe struct GameInfoNative
        {
            public ulong FileSize;
            public fixed byte TitleName[512];
            public fixed byte TitleId[32];
            public fixed byte Developer[256];
            public fixed byte Version[16];  
            public byte* ImageData;  
            public uint ImageSize;   

            public GameInfoNative(ulong fileSize, string titleName, string titleId, string developer, string version, byte[] imageData)
            {
                FileSize = fileSize;

                fixed (byte* titleNamePtr = TitleName)
                fixed (byte* titleIdPtr = TitleId)
                fixed (byte* developerPtr = Developer)
                fixed (byte* versionPtr = Version)
                {
                    CopyStringToFixedArray(titleName, titleNamePtr, 512);
                    CopyStringToFixedArray(titleId, titleIdPtr, 32);
                    CopyStringToFixedArray(developer, developerPtr, 256);
                    CopyStringToFixedArray(version, versionPtr, 16);
                }

                if (imageData == null || imageData.Length > 4096 * 4096)
                {
                    ImageSize = 0;
                    ImageData = null;
                }
                else 
                {
                    ImageSize = (uint)imageData.Length;
                    ImageData = (byte*)Marshal.AllocHGlobal(imageData.Length);
                    Marshal.Copy(imageData, 0, (IntPtr)ImageData, imageData.Length);
                }
            }

            public void Dispose()
            {
                if (ImageData != null)
                {
                    Marshal.FreeHGlobal((IntPtr)ImageData);
                    ImageData = null;
                }
            }
        }
        
        [UnmanagedCallersOnly(EntryPoint = "free_game_info")]
        public static unsafe void FreeGameInfo(GameInfoNative* gameInfoPtr)
        {
            if (gameInfoPtr == null)
                return;
                
            if (gameInfoPtr->ImageData != null)
            {
                Marshal.FreeHGlobal((IntPtr)gameInfoPtr->ImageData);
                gameInfoPtr->ImageData = null;
            }
            gameInfoPtr->ImageSize = 0;
        }

        private static unsafe void CopyStringToFixedArray(string source, byte* destination, int length)
        {
            var span = new Span<byte>(destination, length);
            span.Clear();
            Encoding.UTF8.GetBytes(source, span);
        }

        [UnmanagedCallersOnly(EntryPoint = "update_settings_external")]
        public static unsafe int UpdateSettingsExternal(int argCount, IntPtr* pArgs)
        {
            string[] args = new string[argCount];

            try
            {
                for (int i = 0; i < argCount; i++)
                {
                    args[i] = Marshal.PtrToStringAnsi(pArgs[i]);
                }

                Options parsedOptions = null;
                Parser.Default.ParseArguments<Options>(args)
                    .WithParsed(opts => parsedOptions = opts);

                if (parsedOptions == null)
                {
                    Console.WriteLine("Failed to parse options.");
                    return -1;
                }

                ApplyDynamicSettings(parsedOptions);
            }
            catch (Exception e)
            {
                Console.WriteLine(e.ToString());
                return -1;
            }

            return 0;
        }

        private static void ApplyDynamicSettings(Options options)
        {
            GraphicsConfig.ResScale = options.ResScale;
            GraphicsConfig.MaxAnisotropy = options.MaxAnisotropy;
            GraphicsConfig.EnableShaderCache = !options.DisableShaderCache;
            GraphicsConfig.EnableTextureRecompression = options.EnableTextureRecompression;
            GraphicsConfig.EnableMacroHLE = !options.DisableMacroHLE;

            // Was missing entirely: this method propagated ResScale/MaxAnisotropy/etc.
            // but never re-applied ScalingFilter/ScalingFilterLevel, so a live
            // update_settings_external call changing --scaling-filter had no
            // effect until the next full relaunch.
            if (_window != null)
            {
                _window.ScalingFilter = options.ScalingFilter;
                _window.ScalingFilterLevel = options.ScalingFilterLevel;
                _window.SetScalingFilter();
            }

            if (_emulationContext != null)
            {
                _emulationContext.SetVolume(options.AudioVolume);

                _emulationContext.System.State.SetLanguage(options.SystemLanguage);
                _emulationContext.System.State.SetRegion(options.SystemRegion);
                _emulationContext.EnableDeviceVsync = !options.DisableVSync;
                _emulationContext.System.State.DockedMode = !options.DisableDockedMode;
                _emulationContext.System.EnablePtc = !options.DisablePTC;
                _emulationContext.System.FsIntegrityCheckLevel = !options.DisableFsIntegrityChecks ? IntegrityCheckLevel.ErrorOnInvalid : IntegrityCheckLevel.None;
                _emulationContext.System.GlobalAccessLogMode = options.FsGlobalAccessLogMode;
                _emulationContext.Configuration.IgnoreMissingServices = options.IgnoreMissingServices;
                _emulationContext.Configuration.AspectRatio = options.AspectRatio;
                _emulationContext.Configuration.EnableInternetAccess = options.EnableInternetAccess;
                _emulationContext.Configuration.MemoryManagerMode = options.MemoryManagerMode;
                _emulationContext.Configuration.MultiplayerLanInterfaceId = options.MultiplayerLanInterfaceId;
            }
        }
    }


}
