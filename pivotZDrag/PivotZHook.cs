// PivotZHook.cs
// Standalone global mouse hook for "Ctrl+Shift + middle-drag = move selected
// verts along the Working Pivot's Z axis" in 3ds Max. Compiled at runtime by
// pivotZDrag.ms.
//
// Self-contained (no UI, no marking menu, independent of maxMouse and
// shiftVertexDrag). It:
//   * installs a WH_MOUSE_LL hook, acting only while 3ds Max is foreground;
//   * when Armed (editable poly/mesh in vertex level) and the modifier set is
//     EXACTLY Ctrl+Shift, swallows the middle button down/up (no pan) and
//     streams the drag to MAXScript via a message-only window (PostMessage,
//     self-coalescing) for smooth, non-re-entrant dispatch.
// The middle button alone, Shift-only, and the left button are all untouched
// (exact modifier match -> never collides with a Shift-only tool).
//
// Kept to C# 3 language features so it compiles on every 3ds Max version.

using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PivotZMove
{
    public class PointEventArgs : EventArgs
    {
        public int X;
        public int Y;
        public PointEventArgs(int x, int y) { X = x; Y = y; }
    }

    // message-only window: receives the posted drag messages on the UI thread
    class MsgSink : NativeWindow
    {
        public const int WM_VSTART = 0x8000 + 1;   // WM_APP range
        public const int WM_VMOVE  = 0x8000 + 2;
        public const int WM_VEND   = 0x8000 + 3;
        public Action OnVStart, OnVMove, OnVEnd;

        public MsgSink()
        {
            CreateParams cp = new CreateParams();
            cp.Parent = (IntPtr)(-3);   // HWND_MESSAGE -> message-only window
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_VSTART) { if (OnVStart != null) OnVStart(); return; }
            if (m.Msg == WM_VMOVE)  { if (OnVMove  != null) OnVMove();  return; }
            if (m.Msg == WM_VEND)   { if (OnVEnd   != null) OnVEnd();   return; }
            base.WndProc(ref m);
        }

        public void Close() { try { DestroyHandle(); } catch { } }
    }

    public class PivotZDragHook
    {
        private const int WH_MOUSE_LL    = 14;
        private const int WM_MOUSEMOVE   = 0x0200;
        private const int WM_MBUTTONDOWN = 0x0207;
        private const int WM_MBUTTONUP   = 0x0208;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSLLHOOKSTRUCT
        {
            public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo;
        }

        private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

        // ---- configuration (set from MAXScript) ----
        public bool Armed { get; set; }       // editable poly/mesh in vertex level
        public int  Modifiers { get; set; }   // EXACT bitmask: 1=Ctrl, 2=Alt, 4=Shift

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;
        private MsgSink _sink;
        private readonly int _ourPid;

        private bool _vDrag = false, _vMovePosted = false;
        private int _vStartX, _vStartY, _vCurX, _vCurY;

        public event EventHandler<PointEventArgs> VertexDragStart;
        public event EventHandler<PointEventArgs> VertexDragMove;
        public event EventHandler<EventArgs>      VertexDragEnd;

        public PivotZDragHook()
        {
            Armed = false;
            Modifiers = 1 | 4;   // Ctrl + Shift by default
            _ourPid = System.Diagnostics.Process.GetCurrentProcess().Id;
        }

        public bool IsRunning { get { return _hookId != IntPtr.Zero; } }

        public void Start()
        {
            if (_hookId != IntPtr.Zero) return;
            _sink = new MsgSink();
            _sink.OnVStart = delegate {
                EventHandler<PointEventArgs> h = VertexDragStart;
                if (h != null) h(this, new PointEventArgs(_vStartX, _vStartY));
            };
            _sink.OnVMove = delegate {
                _vMovePosted = false;
                EventHandler<PointEventArgs> h = VertexDragMove;
                if (h != null) h(this, new PointEventArgs(_vCurX, _vCurY));
            };
            _sink.OnVEnd = delegate {
                EventHandler<EventArgs> h = VertexDragEnd;
                if (h != null) h(this, EventArgs.Empty);
            };
            _proc = HookCallback;
            _hookId = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
        }

        public void Stop()
        {
            if (_hookId != IntPtr.Zero) { UnhookWindowsHookEx(_hookId); _hookId = IntPtr.Zero; }
            if (_sink != null) { _sink.Close(); _sink = null; }
            _vDrag = false;
        }

        // require the held modifier set to EXACTLY equal Modifiers, so e.g.
        // Ctrl+Shift does not also trigger a Shift-only tool
        private bool ModifiersMatch()
        {
            int cur = 0;
            if ((GetAsyncKeyState(0x11) & 0x8000) != 0) cur |= 1; // Ctrl
            if ((GetAsyncKeyState(0x12) & 0x8000) != 0) cur |= 2; // Alt
            if ((GetAsyncKeyState(0x10) & 0x8000) != 0) cur |= 4; // Shift
            return cur == Modifiers;
        }

        private bool MaxForeground()
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return false;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return pid == (uint)_ourPid;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && _sink != null)
            {
                MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                if (MaxForeground())
                {
                    int msg = wParam.ToInt32();
                    int px = data.pt.x, py = data.pt.y;
                    if (msg == WM_MBUTTONDOWN)
                    {
                        if (Armed && ModifiersMatch())
                        {
                            _vDrag = true; _vMovePosted = false;
                            _vStartX = px; _vStartY = py; _vCurX = px; _vCurY = py;
                            PostMessage(_sink.Handle, MsgSink.WM_VSTART, IntPtr.Zero, IntPtr.Zero);
                            return (IntPtr)1;   // swallow: no pan
                        }
                    }
                    else if (msg == WM_MBUTTONUP)
                    {
                        if (_vDrag)
                        {
                            _vCurX = px; _vCurY = py; _vDrag = false;
                            PostMessage(_sink.Handle, MsgSink.WM_VEND, IntPtr.Zero, IntPtr.Zero);
                            return (IntPtr)1;
                        }
                    }
                    else if (msg == WM_MOUSEMOVE)
                    {
                        // record only; never swallow moves (would freeze the cursor)
                        if (_vDrag)
                        {
                            _vCurX = px; _vCurY = py;
                            if (!_vMovePosted)   // coalesce: one move in flight
                            {
                                _vMovePosted = true;
                                PostMessage(_sink.Handle, MsgSink.WM_VMOVE, IntPtr.Zero, IntPtr.Zero);
                            }
                        }
                    }
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }
    }
}
