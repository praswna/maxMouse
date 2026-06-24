// MaxMouse_GestureHook.cs
// Maya-style marking menu + screen-space vertex drag for 3ds Max.
// Compiled at runtime by maxMouse.ms via the .NET CSharpCodeProvider.
//
// RIGHT button  -> Maya-style marking menu:
//     hold, a radial menu pops up after a short delay, flick toward a slice
//     and release to run it. A fast flick (released before the delay) runs the
//     slice without ever showing the menu. Both the down AND up are swallowed,
//     so Max never sees an unmatched right-button-down; a plain click (no
//     movement) is reproduced as a tagged synthetic right-click so the normal
//     quad menu still appears.
//
// SHIFT+MIDDLE  -> screen-space vertex move (when armed by MAXScript, i.e.
//     Editable Poly/Mesh in vertex sub-object level). The middle down/up are
//     swallowed (so the viewport does not pan); mouse MOVES are never swallowed
//     (that would freeze the cursor). The drag is streamed to MAXScript, which
//     moves the selected verts along the screen plane.
//
// The hook only acts while 3ds Max is the foreground process, so it never
// disturbs other applications. The left button is never touched.
//
// All timing / UI / event raising happens on the 3ds Max UI thread: the
// low-level hook callback only updates state and decides synchronously whether
// to swallow an event; a Forms.Timer drives the menu UI and raises the .NET
// events that MAXScript listens to (so MAXScript never runs re-entrantly
// inside the hook).

using System;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace MaxMouse
{
    public class IndexEventArgs : EventArgs
    {
        public int Index { get; set; }
        public IndexEventArgs(int i) { Index = i; }
    }

    public class PointEventArgs : EventArgs
    {
        public int X { get; set; }
        public int Y { get; set; }
        public PointEventArgs(int x, int y) { X = x; Y = y; }
    }

    // ----------------------------------------------------------------------
    //  Radial marking-menu overlay (borderless, click-through, non-activating)
    // ----------------------------------------------------------------------
    public class RadialMenu : Form
    {
        // posted (normal-priority) messages used to dispatch the vertex drag,
        // so it isn't starved like a low-priority WM_TIMER tick.
        // WM_APP range (0x8000+) is safe from system / WinForms internal use.
        public const int WM_VSTART = 0x8000 + 1;
        public const int WM_VMOVE  = 0x8000 + 2;
        public const int WM_VEND   = 0x8000 + 3;
        public Action OnVStart, OnVMove, OnVEnd;

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case WM_VSTART: if (OnVStart != null) OnVStart(); return;
                case WM_VMOVE:  if (OnVMove  != null) OnVMove();  return;
                case WM_VEND:   if (OnVEnd   != null) OnVEnd();   return;
            }
            base.WndProc(ref m);
        }

        private string[] _labels = new string[0];
        private string[] _icons = new string[0];
        private readonly Dictionary<string, Image> _iconCache = new Dictionary<string, Image>();
        private int _highlight = -1;
        private readonly int _radius = 95;

        public RadialMenu()
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition   = FormStartPosition.Manual;
            ShowInTaskbar   = false;
            TopMost         = true;
            BackColor       = Color.FromArgb(28, 28, 30);
            Opacity         = 0.88;
            DoubleBuffered  = true;
            Width  = _radius * 2 + 80;
            Height = _radius * 2 + 80;

            // clip the window to a circle so corners don't show
            int rr = _radius + 16;
            using (GraphicsPath gp = new GraphicsPath())
            {
                gp.AddEllipse(Width / 2 - rr, Height / 2 - rr, rr * 2, rr * 2);
                Region = new Region(gp);
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW (keep out of alt-tab)
                cp.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT (click-through, never eats input)
                return cp;
            }
        }

        public void SetLabels(string[] labels, string[] icons)
        {
            _labels = labels ?? new string[0];
            _icons  = icons  ?? new string[0];
            Invalidate();
        }

        private Image GetIcon(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            Image img;
            if (_iconCache.TryGetValue(path, out img)) return img;
            img = null;
            try
            {
                if (File.Exists(path))
                    using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read))
                    using (Image tmp = Image.FromStream(fs))
                        img = new Bitmap(tmp);   // copy so we don't hold the file open
            }
            catch { img = null; }
            _iconCache[path] = img;
            return img;
        }

        public int Highlight
        {
            get { return _highlight; }
            set { if (_highlight != value) { _highlight = value; Invalidate(); } }
        }

        public void ShowAt(int screenX, int screenY)
        {
            _highlight = -1;
            Location = new Point(screenX - Width / 2, screenY - Height / 2);
            if (!Visible) Show(); else Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;

            int n = _labels.Length;
            if (n <= 0) return;

            float cx = Width / 2f, cy = Height / 2f;
            float step = 360f / n;

            if (_highlight >= 0 && _highlight < n)
            {
                using (SolidBrush hb = new SolidBrush(Color.FromArgb(120, 90, 150, 235)))
                {
                    float gdiCenter = _highlight * step - 90f;     // 0=N maps to GDI -90
                    g.FillPie(hb, cx - _radius, cy - _radius, _radius * 2, _radius * 2,
                              gdiCenter - step / 2f, step);
                }
            }

            using (Pen ring = new Pen(Color.FromArgb(80, 255, 255, 255), 1.5f))
            {
                g.DrawEllipse(ring, cx - _radius, cy - _radius, _radius * 2, _radius * 2);
                for (int i = 0; i < n; i++)
                {
                    double a = (i * step - 90f - step / 2f) * Math.PI / 180.0;
                    g.DrawLine(ring, cx, cy,
                               cx + (float)(Math.Cos(a) * _radius),
                               cy + (float)(Math.Sin(a) * _radius));
                }
            }

            using (SolidBrush cb = new SolidBrush(Color.FromArgb(180, 255, 255, 255)))
                g.FillEllipse(cb, cx - 3, cy - 3, 6, 6);

            using (Font f = new Font("Segoe UI", 8.5f, FontStyle.Bold))
            using (SolidBrush tb = new SolidBrush(Color.White))
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                for (int i = 0; i < n; i++)
                {
                    double comp = i * step * Math.PI / 180.0;       // compass radians, 0=N
                    float lx = cx + (float)(Math.Sin(comp) * _radius * 0.72);
                    float ly = cy - (float)(Math.Cos(comp) * _radius * 0.72);
                    string txt = _labels[i] ?? "";
                    Image ic = (i < _icons.Length) ? GetIcon(_icons[i]) : null;
                    if (ic != null)
                    {
                        g.DrawImage(ic, lx - 12, ly - 20, 24, 24);
                        g.DrawString(txt, f, tb, new RectangleF(lx - 44, ly + 5, 88, 18), sf);
                    }
                    else
                    {
                        g.DrawString(txt, f, tb, new RectangleF(lx - 44, ly - 11, 88, 22), sf);
                    }
                }
            }
        }
    }

    // ----------------------------------------------------------------------
    //  Global low-level mouse hook + dispatcher
    // ----------------------------------------------------------------------
    public class GestureHook
    {
        private const int WH_MOUSE_LL    = 14;
        private const int WM_MOUSEMOVE   = 0x0200;
        private const int WM_RBUTTONDOWN = 0x0204;
        private const int WM_RBUTTONUP   = 0x0205;
        private const int WM_MBUTTONDOWN = 0x0207;
        private const int WM_MBUTTONUP   = 0x0208;
        private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        private const uint MOUSEEVENTF_RIGHTUP   = 0x0010;
        // tag used on synthesized right-clicks so the hook ignores its own input
        private const long INJECTED_TAG = 0x4D4D6D6D;

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
        private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

        // ---- configuration (set from MAXScript) ----
        public bool EnableRightMenu { get; set; }
        public bool VertexMoveArmed { get; set; }
        public int  VertexMoveModifier { get; set; }  // 0=none, 1=Ctrl, 2=Alt, 3=Shift
        public int  PopupDelayMs    { get; set; }
        public int  DeadZone        { get; set; }

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;
        private Timer _timer;
        private RadialMenu _menu;
        private string[] _rightLabels = new string[0];
        private string[] _rightIcons = new string[0];
        private int _slices = 0;

        // right-button marking-menu state
        private bool _rmDown = false, _menuShown = false;
        private int _rmStartX, _rmStartY, _rmCurX, _rmCurY, _rmDownTick;
        private bool _rmResultReady = false;
        private bool _rmInjectClick = false;
        private int _rmResult = -1;

        private readonly int _ourPid = System.Diagnostics.Process.GetCurrentProcess().Id;

        // middle-button vertex-drag state (dispatched via posted messages)
        private bool _vDrag = false, _vMovePosted = false;
        private int _vStartX, _vStartY, _vCurX, _vCurY;

        public event EventHandler<IndexEventArgs> MarkingMenuSelected;
        public event EventHandler<PointEventArgs> VertexDragStart;
        public event EventHandler<PointEventArgs> VertexDragMove;
        public event EventHandler<EventArgs>      VertexDragEnd;

        public GestureHook()
        {
            EnableRightMenu = true;
            VertexMoveArmed = false;
            VertexMoveModifier = 1;   // Ctrl + middle by default
            PopupDelayMs    = 160;
            DeadZone        = 14;
        }

        public bool IsRunning { get { return _hookId != IntPtr.Zero; } }

        // is the configured vertex-move modifier key currently held?
        private bool ModifierDown()
        {
            switch (VertexMoveModifier)
            {
                case 1: return (GetAsyncKeyState(0x11) & 0x8000) != 0; // VK_CONTROL
                case 2: return (GetAsyncKeyState(0x12) & 0x8000) != 0; // VK_MENU (Alt)
                case 3: return (GetAsyncKeyState(0x10) & 0x8000) != 0; // VK_SHIFT
                default: return true;                                  // 0 = no modifier
            }
        }

        public void SetRightMenu(System.Collections.ArrayList labels, System.Collections.ArrayList icons)
        {
            string[] L = new string[labels.Count];
            string[] I = new string[labels.Count];
            for (int i = 0; i < labels.Count; i++)
            {
                L[i] = labels[i] == null ? "" : labels[i].ToString();
                I[i] = (icons != null && i < icons.Count && icons[i] != null) ? icons[i].ToString() : "";
            }
            _rightLabels = L;
            _rightIcons  = I;
            _slices = L.Length;
            if (_menu != null) _menu.SetLabels(L, I);
        }

        public void Start()
        {
            if (_hookId != IntPtr.Zero) return;
            _menu = new RadialMenu();
            _menu.SetLabels(_rightLabels, _rightIcons);
            // vertex-drag dispatch (posted messages -> not starved by WM_TIMER)
            _menu.OnVStart = delegate {
                EventHandler<PointEventArgs> h = VertexDragStart;
                if (h != null) h(this, new PointEventArgs(_vStartX, _vStartY));
            };
            _menu.OnVMove = delegate {
                _vMovePosted = false;
                EventHandler<PointEventArgs> h = VertexDragMove;
                if (h != null) h(this, new PointEventArgs(_vCurX, _vCurY));
            };
            _menu.OnVEnd = delegate {
                EventHandler<EventArgs> h = VertexDragEnd;
                if (h != null) h(this, EventArgs.Empty);
            };
            IntPtr forceHandle = _menu.Handle;   // create the window so it can receive posts
            _proc = HookCallback;
            _hookId = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
            _timer = new Timer();
            _timer.Interval = 10;
            _timer.Tick += Tick;
            _timer.Start();
        }

        public void Stop()
        {
            if (_timer != null) { _timer.Stop(); _timer.Dispose(); _timer = null; }
            if (_hookId != IntPtr.Zero) { UnhookWindowsHookEx(_hookId); _hookId = IntPtr.Zero; }
            if (_menu != null) { try { _menu.Hide(); _menu.Dispose(); } catch { } _menu = null; }
            _rmDown = false; _menuShown = false; _vDrag = false;
        }

        // direction (0=N, clockwise) under the cursor, or -1 inside the dead zone
        private int SliceIndex(int dx, int dy)
        {
            double dist = Math.Sqrt((double)dx * dx + (double)dy * dy);
            if (dist < DeadZone || _slices <= 0) return -1;
            double ang = Math.Atan2(dx, -dy) * 180.0 / Math.PI;
            if (ang < 0) ang += 360;
            double step = 360.0 / _slices;
            return ((int)Math.Round(ang / step)) % _slices;
        }

        // only act while a window of THIS process (3ds Max) is in the foreground,
        // so we never interfere with other applications
        private bool MaxIsForeground()
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return false;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return pid == (uint)_ourPid;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));

                // ignore the right-clicks we synthesize ourselves
                if (data.dwExtraInfo.ToInt64() == INJECTED_TAG)
                    return CallNextHookEx(_hookId, nCode, wParam, lParam);

                // leave every other application completely alone
                if (!MaxIsForeground())
                    return CallNextHookEx(_hookId, nCode, wParam, lParam);

                int msg = wParam.ToInt32();
                int px = data.pt.x, py = data.pt.y;
                switch (msg)
                {
                    case WM_RBUTTONDOWN:
                        if (EnableRightMenu)
                        {
                            _rmDown = true; _menuShown = false;
                            _rmStartX = px; _rmStartY = py; _rmCurX = px; _rmCurY = py;
                            _rmDownTick = Environment.TickCount;
                            // swallow the down too; a plain click is reproduced on up
                            // (so Max never sees an unmatched right-button-down)
                            return (IntPtr)1;
                        }
                        break;

                    case WM_RBUTTONUP:
                        if (_rmDown)
                        {
                            _rmCurX = px; _rmCurY = py;
                            _rmDown = false;
                            int idx = SliceIndex(px - _rmStartX, py - _rmStartY);
                            if (_menuShown || idx >= 0)
                                _rmResult = idx;           // gesture / quick flick (idx -1 = cancel)
                            else
                            {
                                _rmResult = -1;            // plain click: no action...
                                _rmInjectClick = true;     // ...reproduce a normal right-click instead
                            }
                            _rmResultReady = true;
                            return (IntPtr)1;              // always swallow the original up
                        }
                        break;

                    case WM_MBUTTONDOWN:
                        if (VertexMoveArmed && ModifierDown() && _menu != null)
                        {
                            _vDrag = true; _vMovePosted = false;
                            _vStartX = px; _vStartY = py; _vCurX = px; _vCurY = py;
                            PostMessage(_menu.Handle, RadialMenu.WM_VSTART, IntPtr.Zero, IntPtr.Zero);
                            return (IntPtr)1;             // swallow: no pan (modifier held)
                        }
                        break;

                    case WM_MBUTTONUP:
                        if (_vDrag && _menu != null)
                        {
                            _vCurX = px; _vCurY = py;
                            _vDrag = false;
                            PostMessage(_menu.Handle, RadialMenu.WM_VEND, IntPtr.Zero, IntPtr.Zero);
                            return (IntPtr)1;
                        }
                        break;

                    case WM_MOUSEMOVE:
                        // record only; NEVER swallow moves (that would freeze the cursor)
                        if (_rmDown) { _rmCurX = px; _rmCurY = py; }
                        if (_vDrag)
                        {
                            _vCurX = px; _vCurY = py;
                            // coalesce: at most one move message in flight
                            if (!_vMovePosted && _menu != null)
                            {
                                _vMovePosted = true;
                                PostMessage(_menu.Handle, RadialMenu.WM_VMOVE, IntPtr.Zero, IntPtr.Zero);
                            }
                        }
                        break;
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }

        private void Tick(object sender, EventArgs e)
        {
            // marking menu: pop up after the hold delay
            if (_rmDown && !_menuShown && EnableRightMenu && _slices > 0 &&
                (Environment.TickCount - _rmDownTick) >= PopupDelayMs)
            {
                _menu.ShowAt(_rmStartX, _rmStartY);
                _menuShown = true;
            }
            if (_menuShown && _rmDown)
                _menu.Highlight = SliceIndex(_rmCurX - _rmStartX, _rmCurY - _rmStartY);

            if (_rmResultReady)
            {
                _rmResultReady = false;
                if (_menuShown) { _menu.Hide(); _menuShown = false; }
                EventHandler<IndexEventArgs> h = MarkingMenuSelected;
                if (h != null && _rmResult >= 0) h(this, new IndexEventArgs(_rmResult));
            }

            // reproduce a normal right-click for a plain (non-gesture) right click,
            // tagged so the hook ignores it -> the usual quad menu appears
            if (_rmInjectClick)
            {
                _rmInjectClick = false;
                mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, (UIntPtr)(ulong)INJECTED_TAG);
                mouse_event(MOUSEEVENTF_RIGHTUP,   0, 0, 0, (UIntPtr)(ulong)INJECTED_TAG);
            }
            // (vertex drag is dispatched via posted messages, not here)
        }
    }
}
