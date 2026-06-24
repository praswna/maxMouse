// MaxMouse_GestureHook.cs
// Maya-style marking menu + screen-space vertex drag for 3ds Max.
// Compiled at runtime by maxMouse.ms via the .NET CSharpCodeProvider.
//
// RIGHT button  -> Maya-style marking menu:
//     hold, a radial menu pops up after a short delay, flick toward a slice
//     and release to run it. A fast flick (released before the delay) runs the
//     slice without ever showing the menu. A plain click (no movement) is
//     passed through so the normal quad menu still works.
//
// MIDDLE button -> screen-space vertex move (when armed by MAXScript, i.e.
//     Editable Poly/Mesh in vertex sub-object level with a vertex selection).
//     The middle events are swallowed (so the viewport does not pan) and the
//     drag is streamed to MAXScript, which moves the selected verts along the
//     screen plane. When not armed, the middle button is left alone (pan).
//
// All timing / UI / event raising happens on the 3ds Max UI thread: the
// low-level hook callback only updates state and decides synchronously whether
// to swallow an event; a Forms.Timer drives the menu UI and raises the .NET
// events that MAXScript listens to (so MAXScript never runs re-entrantly
// inside the hook).

using System;
using System.Drawing;
using System.Drawing.Drawing2D;
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
        private string[] _labels = new string[0];
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
                return cp;
            }
        }

        public void SetLabels(string[] labels) { _labels = labels ?? new string[0]; Invalidate(); }

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
                    g.DrawString(txt, f, tb, new RectangleF(lx - 44, ly - 12, 88, 24), sf);
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

        // ---- configuration (set from MAXScript) ----
        public bool EnableRightMenu { get; set; }
        public bool VertexMoveArmed { get; set; }
        public int  PopupDelayMs    { get; set; }
        public int  DeadZone        { get; set; }

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;
        private Timer _timer;
        private RadialMenu _menu;
        private string[] _rightLabels = new string[0];
        private int _slices = 0;

        // right-button marking-menu state
        private bool _rmDown = false, _menuShown = false;
        private int _rmStartX, _rmStartY, _rmCurX, _rmCurY, _rmDownTick;
        private bool _rmResultReady = false;
        private int _rmResult = -1;

        // middle-button vertex-drag state
        private bool _vDrag = false, _vStartReady = false, _vMovePending = false, _vEndReady = false;
        private int _vStartX, _vStartY, _vCurX, _vCurY;

        public event EventHandler<IndexEventArgs> MarkingMenuSelected;
        public event EventHandler<PointEventArgs> VertexDragStart;
        public event EventHandler<PointEventArgs> VertexDragMove;
        public event EventHandler<EventArgs>      VertexDragEnd;

        public GestureHook()
        {
            EnableRightMenu = true;
            VertexMoveArmed = false;
            PopupDelayMs    = 160;
            DeadZone        = 14;
        }

        public bool IsRunning { get { return _hookId != IntPtr.Zero; } }

        public void SetRightMenu(System.Collections.ArrayList labels)
        {
            string[] arr = new string[labels.Count];
            for (int i = 0; i < labels.Count; i++)
                arr[i] = labels[i] == null ? "" : labels[i].ToString();
            _rightLabels = arr;
            _slices = arr.Length;
            if (_menu != null) _menu.SetLabels(arr);
        }

        public void Start()
        {
            if (_hookId != IntPtr.Zero) return;
            _menu = new RadialMenu();
            _menu.SetLabels(_rightLabels);
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

        private POINT Pt(IntPtr lParam)
        {
            return ((MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT))).pt;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                int msg = wParam.ToInt32();
                POINT p;
                switch (msg)
                {
                    case WM_RBUTTONDOWN:
                        p = Pt(lParam);
                        _rmDown = true; _menuShown = false;
                        _rmStartX = p.x; _rmStartY = p.y; _rmCurX = p.x; _rmCurY = p.y;
                        _rmDownTick = Environment.TickCount;
                        break;

                    case WM_RBUTTONUP:
                        if (_rmDown)
                        {
                            p = Pt(lParam);
                            _rmCurX = p.x; _rmCurY = p.y;
                            _rmDown = false;
                            int idx = SliceIndex(p.x - _rmStartX, p.y - _rmStartY);
                            if (_menuShown)
                            {
                                _rmResult = idx;          // -1 -> cancel
                                _rmResultReady = true;
                                return (IntPtr)1;         // swallow: no quad menu
                            }
                            else if (idx >= 0)
                            {
                                _rmResult = idx;          // quick flick, menu never shown
                                _rmResultReady = true;
                                return (IntPtr)1;
                            }
                            // else: a plain click -> let it through (normal quad menu)
                        }
                        break;

                    case WM_MBUTTONDOWN:
                        if (VertexMoveArmed)
                        {
                            p = Pt(lParam);
                            _vDrag = true;
                            _vStartX = p.x; _vStartY = p.y; _vCurX = p.x; _vCurY = p.y;
                            _vStartReady = true;
                            return (IntPtr)1;             // swallow: no pan
                        }
                        break;

                    case WM_MBUTTONUP:
                        if (_vDrag)
                        {
                            p = Pt(lParam);
                            _vCurX = p.x; _vCurY = p.y;
                            _vDrag = false; _vEndReady = true;
                            return (IntPtr)1;
                        }
                        break;

                    case WM_MOUSEMOVE:
                        p = Pt(lParam);
                        if (_rmDown) { _rmCurX = p.x; _rmCurY = p.y; }
                        if (_vDrag)  { _vCurX = p.x; _vCurY = p.y; _vMovePending = true; return (IntPtr)1; }
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

            // vertex drag streaming
            if (_vStartReady)
            {
                _vStartReady = false;
                EventHandler<PointEventArgs> h = VertexDragStart;
                if (h != null) h(this, new PointEventArgs(_vStartX, _vStartY));
            }
            if (_vMovePending)
            {
                _vMovePending = false;
                EventHandler<PointEventArgs> h = VertexDragMove;
                if (h != null) h(this, new PointEventArgs(_vCurX, _vCurY));
            }
            if (_vEndReady)
            {
                _vEndReady = false;
                EventHandler<EventArgs> h = VertexDragEnd;
                if (h != null) h(this, EventArgs.Empty);
            }
        }
    }
}
