// MaxMouse_GestureHook.cs
// Global low-level mouse hook + gesture recognizer for 3ds Max.
// Compiled at runtime by maxMouse.ms via the C# CodeDomProvider.
//
// Responsibilities (kept in C# so decisions are synchronous inside the hook):
//   * Install a WH_MOUSE_LL hook on the 3ds Max UI thread.
//   * While the right or middle button is held, accumulate movement and
//     reduce it to a direction string such as "DR" (down then right).
//   * On button-up, if the drag was an actual gesture (moved past the
//     threshold) swallow the up event (so the right-click quad menu does
//     not appear) and queue the gesture; otherwise let the click pass
//     through untouched so normal clicks/menus keep working.
//   * Raise GestureRecognized OUTSIDE the hook callback (via a Forms.Timer)
//     so the MAXScript handler runs on the message loop, not re-entrantly
//     inside the low-level hook.

using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace MaxMouse
{
    public class GestureEventArgs : EventArgs
    {
        public string Button { get; set; }   // "R" = right, "M" = middle
        public string Gesture { get; set; }  // e.g. "L", "DR", "RU"
        public GestureEventArgs(string button, string gesture)
        {
            Button = button;
            Gesture = gesture;
        }
    }

    public class GestureHook
    {
        // ---- Win32 ----
        private const int WH_MOUSE_LL   = 14;
        private const int WM_MOUSEMOVE  = 0x0200;
        private const int WM_RBUTTONDOWN= 0x0204;
        private const int WM_RBUTTONUP  = 0x0205;
        private const int WM_MBUTTONDOWN= 0x0207;
        private const int WM_MBUTTONUP  = 0x0208;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSLLHOOKSTRUCT
        {
            public POINT pt;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        // ---- configuration (set from MAXScript) ----
        public bool EnableRight  { get; set; }
        public bool EnableMiddle { get; set; }
        public int  MinDistance  { get; set; }  // px of travel before a direction token is emitted

        // ---- state ----
        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;        // kept alive to avoid GC of the delegate
        private Timer _dispatch;
        private readonly Queue<GestureEventArgs> _pending = new Queue<GestureEventArgs>();

        private bool _tracking = false;
        private string _activeButton = "";
        private int _lastX, _lastY, _accX, _accY;
        private bool _moved = false;
        private readonly StringBuilder _path = new StringBuilder();
        private char _lastDir = '\0';

        public event EventHandler<GestureEventArgs> GestureRecognized;

        public GestureHook()
        {
            EnableRight  = true;
            EnableMiddle = true;
            MinDistance  = 18;
        }

        public bool IsRunning { get { return _hookId != IntPtr.Zero; } }

        public void Start()
        {
            if (_hookId != IntPtr.Zero) return;
            _proc = HookCallback;
            _hookId = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
            _dispatch = new Timer();
            _dispatch.Interval = 10;
            _dispatch.Tick += Dispatch;
            _dispatch.Start();
        }

        public void Stop()
        {
            if (_dispatch != null) { _dispatch.Stop(); _dispatch.Dispose(); _dispatch = null; }
            if (_hookId != IntPtr.Zero) { UnhookWindowsHookEx(_hookId); _hookId = IntPtr.Zero; }
            _tracking = false;
            _pending.Clear();
        }

        private void Dispatch(object sender, EventArgs e)
        {
            while (_pending.Count > 0)
            {
                GestureEventArgs g = _pending.Dequeue();
                EventHandler<GestureEventArgs> h = GestureRecognized;
                if (h != null) h(this, g);
            }
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                int msg = wParam.ToInt32();
                switch (msg)
                {
                    case WM_RBUTTONDOWN: if (EnableRight)  Begin("R", lParam); break;
                    case WM_MBUTTONDOWN: if (EnableMiddle) Begin("M", lParam); break;
                    case WM_MOUSEMOVE:   if (_tracking)    Move(lParam);       break;
                    case WM_RBUTTONUP:
                        if (_tracking && _activeButton == "R" && End()) return (IntPtr)1;
                        break;
                    case WM_MBUTTONUP:
                        if (_tracking && _activeButton == "M" && End()) return (IntPtr)1;
                        break;
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }

        private POINT Pt(IntPtr lParam)
        {
            return ((MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT))).pt;
        }

        private void Begin(string button, IntPtr lParam)
        {
            POINT p = Pt(lParam);
            _tracking = true;
            _activeButton = button;
            _lastX = p.x; _lastY = p.y;
            _accX = 0; _accY = 0;
            _path.Length = 0;
            _lastDir = '\0';
            _moved = false;
        }

        private void Move(IntPtr lParam)
        {
            POINT p = Pt(lParam);
            int dx = p.x - _lastX;
            int dy = p.y - _lastY;
            _lastX = p.x; _lastY = p.y;
            _accX += dx; _accY += dy;

            if (Math.Abs(_accX) < MinDistance && Math.Abs(_accY) < MinDistance) return;

            char dir;
            if (Math.Abs(_accX) > Math.Abs(_accY)) dir = _accX > 0 ? 'R' : 'L';
            else                                   dir = _accY > 0 ? 'D' : 'U';

            _accX = 0; _accY = 0;
            if (dir != _lastDir)
            {
                _path.Append(dir);
                _lastDir = dir;
                _moved = true;
            }
        }

        // returns true if a gesture was recognized (and the button-up should be swallowed)
        private bool End()
        {
            _tracking = false;
            string g = _path.ToString();
            _path.Length = 0;
            if (!_moved || g.Length == 0) return false;   // a plain click -> let it pass through
            _pending.Enqueue(new GestureEventArgs(_activeButton, g));
            return true;
        }
    }
}
