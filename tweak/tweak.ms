/*  tweak - "Ctrl 호버로 커서 밑 버텍스 하이라이트 + Ctrl+중간드래그로 이동" (Editable Poly)
    ==========================================================================
    [개요]  ※ Modo 의 Tweak 처럼 "선택하지 않고" 커서 바로 밑 버텍스를 다룹니다.
    Editable Poly 가 선택돼 있으면(서브오브젝트 레벨 진입 불필요):
      - CTRL 만 누르고 버텍스 근처로 가면 -> 가장 가까운 버텍스가 실시간으로
        빨갛게 하이라이트(네이티브 선택색)됩니다.
      - 그 상태로 CTRL+중간(휠)드래그하면 그 버텍스를 화면 평면으로 이동합니다.
      - 드래그가 끝나도(놓아도) 그 버텍스의 선택은 유지됩니다.
      - 단일 Undo("Tweak Vertex").

    - 빨간 하이라이트는 버텍스 서브오브젝트 레벨일 때 보입니다.
    - 중간버튼 단독은 팬. 왼쪽 버튼은 건드리지 않음.
    - 정확 매칭(Ctrl 단독)이라 Shift / Ctrl+Shift 도구와 안 겹침.

    [단일 파일] C# 후크 소스를 이 .ms 안에 임베드 -> 별도 .cs 컴패니언 불필요.
    [독립성] C# 네임스페이스: TweakMove / 전역 접두사: twk_ / 콜백 ID: #tweakDrag
    [실행] Scripting > Run Script -> tweak.ms (실행 즉시 시작, "Tweak Toggle" 매크로 등록)
    ==========================================================================
*/

global twk_hook                 -- C# 후크 인스턴스
global twk_asm                  -- 컴파일된 어셈블리
global twk_obj, twk_vidx, twk_orig
global twk_center, twk_normal, twk_offset, twk_startLocal, twk_startWorld, twk_delta, twk_ok
global twk_held                 -- theHold(undo) 를 열어두었는지
global twk_pickRadius           -- 커서에서 이 픽셀 반경 안의 최근접 버텍스만 집음
global twk_hoverVidx            -- 현재 하이라이트 중인 버텍스(중복 리드로우 방지)
global twk_showRed              -- 잡은/가리킨 버텍스를 빨갛게(네이티브 선택색) 표시할지
global twk_showCross            -- 이동 가능한 버텍스 위에서 커서를 십자로 바꿀지
if twk_pickRadius == undefined do twk_pickRadius = 40.0
if twk_showRed == undefined do twk_showRed = true
if twk_showCross == undefined do twk_showCross = true

-- [임베드] TweakMove 후크 소스. C# 코드 안 큰따옴표는 \" 로 이스케이프되어 있다.
--   Ctrl 을 누른 채 마우스를 움직이면(드래그 아님) hover 를 스트리밍해 MAXScript 가
--   커서 밑 최근접 버텍스를 라이브 하이라이트하게 한다.
global twk_cs = "// TweakMove - embedded mouse hook (Ctrl tweak + Ctrl-hover highlight)
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TweakMove
{
    public class PointEventArgs : EventArgs
    {
        public int X;
        public int Y;
        public PointEventArgs(int x, int y) { X = x; Y = y; }
    }

    class MsgSink : NativeWindow
    {
        public const int WM_VSTART = 0x8000 + 1;
        public const int WM_VMOVE  = 0x8000 + 2;
        public const int WM_VEND   = 0x8000 + 3;
        public const int WM_VHOVER = 0x8000 + 4;
        public Action OnVStart, OnVMove, OnVEnd, OnVHover;

        public MsgSink()
        {
            CreateParams cp = new CreateParams();
            cp.Parent = (IntPtr)(-3);
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_VSTART) { if (OnVStart != null) OnVStart(); return; }
            if (m.Msg == WM_VMOVE)  { if (OnVMove  != null) OnVMove();  return; }
            if (m.Msg == WM_VEND)   { if (OnVEnd   != null) OnVEnd();   return; }
            if (m.Msg == WM_VHOVER) { if (OnVHover != null) OnVHover(); return; }
            base.WndProc(ref m);
        }

        public void Close() { try { DestroyHandle(); } catch { } }
    }

    public class TweakHook
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

        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport(\"user32.dll\", SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport(\"kernel32.dll\", SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string name);
        [DllImport(\"user32.dll\")]
        private static extern short GetAsyncKeyState(int vKey);
        [DllImport(\"user32.dll\")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport(\"user32.dll\")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport(\"user32.dll\")]
        private static extern bool PostMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

        public bool Armed { get; set; }
        public int  Modifier { get; set; }   // 0=none, 1=Ctrl, 2=Alt, 3=Shift (exact)

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;
        private MsgSink _sink;
        private readonly int _ourPid;

        private bool _vDrag = false, _vMovePosted = false, _vHoverPosted = false;
        private int _vStartX, _vStartY, _vCurX, _vCurY;

        public event EventHandler<PointEventArgs> VertexDragStart;
        public event EventHandler<PointEventArgs> VertexDragMove;
        public event EventHandler<EventArgs>      VertexDragEnd;
        public event EventHandler<PointEventArgs> VertexHover;

        public TweakHook()
        {
            Armed = false;
            Modifier = 1;
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
            _sink.OnVHover = delegate {
                _vHoverPosted = false;
                EventHandler<PointEventArgs> h = VertexHover;
                if (h != null) h(this, new PointEventArgs(_vCurX, _vCurY));
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

        private bool ModifierDown()
        {
            bool ctrl  = (GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool alt   = (GetAsyncKeyState(0x12) & 0x8000) != 0;
            bool shift = (GetAsyncKeyState(0x10) & 0x8000) != 0;
            switch (Modifier)
            {
                case 1:  return ctrl  && !alt  && !shift;
                case 2:  return alt   && !ctrl && !shift;
                case 3:  return shift && !ctrl && !alt;
                default: return !ctrl && !alt  && !shift;
            }
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
                int msg = wParam.ToInt32();
                if (msg == WM_MBUTTONDOWN)
                {
                    if (Armed && MaxForeground() && ModifierDown())
                    {
                        MSLLHOOKSTRUCT d = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                        _vDrag = true; _vMovePosted = false;
                        _vStartX = d.pt.x; _vStartY = d.pt.y; _vCurX = d.pt.x; _vCurY = d.pt.y;
                        PostMessage(_sink.Handle, MsgSink.WM_VSTART, IntPtr.Zero, IntPtr.Zero);
                        return (IntPtr)1;
                    }
                }
                else if (msg == WM_MBUTTONUP)
                {
                    if (_vDrag)
                    {
                        MSLLHOOKSTRUCT d = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                        _vCurX = d.pt.x; _vCurY = d.pt.y; _vDrag = false;
                        PostMessage(_sink.Handle, MsgSink.WM_VEND, IntPtr.Zero, IntPtr.Zero);
                        return (IntPtr)1;
                    }
                }
                else if (msg == WM_MOUSEMOVE)
                {
                    if (_vDrag)
                    {
                        MSLLHOOKSTRUCT d = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                        _vCurX = d.pt.x; _vCurY = d.pt.y;
                        if (!_vMovePosted)
                        {
                            _vMovePosted = true;
                            PostMessage(_sink.Handle, MsgSink.WM_VMOVE, IntPtr.Zero, IntPtr.Zero);
                        }
                    }
                    else if (Armed && ModifierDown() && MaxForeground())
                    {
                        // Ctrl held, no drag: stream a hover (never swallow the move) so
                        // MAXScript can live-highlight the nearest vertex under the cursor.
                        MSLLHOOKSTRUCT d = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                        _vCurX = d.pt.x; _vCurY = d.pt.y;
                        if (!_vHoverPosted)
                        {
                            _vHoverPosted = true;
                            PostMessage(_sink.Handle, MsgSink.WM_VHOVER, IntPtr.Zero, IntPtr.Zero);
                        }
                    }
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }
    }
}
"

-- 화면 좌표 p 를 "드래그 평면(잡은 버텍스 통과, 시선 수직)" 위의 월드 좌표로 투영
fn twk_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir twk_normal
    if (abs denom) < 1e-7 then twk_center
    else ( local t = (dot (twk_center - r.pos) twk_normal) / denom; r.pos + t * r.dir )
)

-- 커서(뷰포트 좌표 cursorVP)에서 가장 가까운 버텍스 인덱스(픽셀 반경 내). 없으면 undefined.
--   gw.transPoint 로 각 버텍스를 화면좌표로 투영해 최근접 탐색(O(N)).
fn twk_pickVert obj cursorVP = (
    local nv = polyop.getNumVerts obj
    gw.setTransform (matrix3 1)
    local best = undefined
    local bestD = twk_pickRadius * twk_pickRadius
    local cx = cursorVP.x; local cy = cursorVP.y
    for i = 1 to nv do (
        local sp = gw.transPoint (polyop.getVert obj i node:obj)
        local dx = sp.x - cx; local dy = sp.y - cy
        local d2 = dx*dx + dy*dy
        if d2 < bestD do ( bestD = d2; best = i )
    )
    best
)

-- 잡은/가리킨 버텍스를 빨갛게(네이티브 선택). undo off 라 언두 스택 오염 없음.
fn twk_highlight obj vidx = (
    if twk_showRed do (
        undo off ( try ( polyop.setVertSelection obj #{vidx} ) catch () )
        twk_hoverVidx = vidx
    )
)

-- 커서를 십자(이동 가능) / 기본으로 전환. best-effort(뷰포트 종류에 따라 유지 안 될 수 있음).
--   호버 이벤트는 Max 의 커서 지정 "이후"에 실행되므로 그 위에 덮어써서 십자가 보인다.
fn twk_cursor cross = (
    try (
        local cc = dotNetClass "System.Windows.Forms.Cursor"
        local cs = dotNetClass "System.Windows.Forms.Cursors"
        cc.Current = (if cross then cs.Cross else cs.Default)
    ) catch ()
)

-- [호버] Ctrl 만 누르고 움직일 때(드래그 아님) 최근접 버텍스를 라이브 하이라이트.
--   최근접이 "바뀔 때만" 갱신/리드로우 -> 불필요한 리드로우 최소화.
fn twk_onHover sender args = (
    if twk_ok == true do return false            -- 드래그 중엔 hover 무시
    if not (twk_showRed or twk_showCross) do return false
    try (
        if selection.count != 1 do return false
        local o = selection[1]
        if (classof o.baseObject != Editable_Poly) do return false
        local vidx = twk_pickVert o mouse.pos
        if twk_showCross do twk_cursor (vidx != undefined)   -- 이동 가능 영역이면 십자 커서
        if twk_showRed and vidx != undefined and vidx != twk_hoverVidx do (
            twk_highlight o vidx
            redrawViews()
        )
    ) catch ()
)

-- [드래그 시작] 커서 밑 최근접 버텍스를 집어 원위치/평면을 기록
fn twk_onStart sender args = (
    twk_ok = false
    if twk_held == true do ( try ( theHold.Cancel() ) catch (); twk_held = false )   -- 잔여 hold 정리
    try (
        if selection.count != 1 do return false
        twk_obj = selection[1]
        if (classof twk_obj.baseObject != Editable_Poly) do return false

        twk_offset = [args.X, args.Y] - mouse.pos
        twk_startLocal = [args.X, args.Y] - twk_offset      -- = 다운 시점의 뷰포트 커서 좌표
        twk_vidx = twk_pickVert twk_obj twk_startLocal
        if twk_vidx == undefined do return false            -- 반경 내 버텍스 없음 -> 무동작

        twk_orig   = polyop.getVert twk_obj twk_vidx node:twk_obj
        twk_center = twk_orig
        twk_normal = normalize ((inverse (viewport.getTM())).row3)
        twk_startWorld = twk_planePt twk_startLocal
        twk_delta = [0,0,0]
        twk_highlight twk_obj twk_vidx           -- 잡은 버텍스 빨갛게(드래그 후에도 유지)
        if twk_showCross do twk_cursor true      -- 드래그 동안 십자 유지
        theHold.Begin()                          -- 이동만 언두에 기록(선택은 undo off 로 분리)
        twk_held = true
        twk_ok = true
    ) catch (
        format "tweak: start failed: %\n" (getCurrentException())
        twk_ok = false
        if twk_held == true do ( try ( theHold.Cancel() ) catch (); twk_held = false )
    )
)

-- [드래그 중] 커서를 평면에 투영해 이동량을 구하고 잡은 버텍스 1개를 갱신
fn twk_onMove sender args = (
    if not twk_ok do return false
    try (
        local cur = [args.X, args.Y] - twk_offset
        twk_delta = (twk_planePt cur) - twk_startWorld
        polyop.setVert twk_obj twk_vidx (twk_orig + twk_delta) node:twk_obj
        if twk_showCross do twk_cursor true      -- 드래그 중에도 십자 유지
        redrawViews()
    ) catch ( format "tweak: move failed: %\n" (getCurrentException()) )
)

-- [드래그 끝] 움직였으면 단일 Undo, 아니면 빈 Undo 안 만듦. 선택은 그대로 유지.
fn twk_onEnd sender args = (
    if not twk_ok do return false
    twk_ok = false
    try (
        if twk_held == true do (
            if (length twk_delta) > 1e-6 then theHold.Accept "Tweak Vertex"
            else theHold.Cancel()
            twk_held = false
        )
        redrawViews()
    ) catch (
        format "tweak: commit failed: %\n" (getCurrentException())
        if twk_held == true do ( try ( theHold.Cancel() ) catch (); twk_held = false )
    )
)

-- ===========================================================================
--  무장(Arm): 단일 Editable Poly 가 선택돼 있으면 무장 (서브오브젝트 레벨 불필요)
-- ===========================================================================
fn twk_poll = (
    if twk_hook == undefined do return false
    local armed = false
    if selection.count == 1 do armed = (classof selection[1].baseObject == Editable_Poly)
    twk_hook.Armed = armed
)
fn twk_addCb evt = (
    try ( callbacks.addScript evt "if (twk_poll != undefined) do twk_poll()" id:#tweakDrag ) catch ()
)

-- ===========================================================================
--  컴파일(임베드 문자열) + 시작 / 정지
-- ===========================================================================
fn twk_compile = (
    local prov   = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
    local params = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
    params.ReferencedAssemblies.Add "System.dll"
    params.ReferencedAssemblies.Add "System.Windows.Forms.dll"
    params.GenerateInMemory   = true
    params.GenerateExecutable = false

    local res = prov.CompileAssemblyFromSource params #(twk_cs)
    if res.Errors.HasErrors do (
        local m = "tweak: C# compile errors:\n"
        for i = 0 to res.Errors.Count - 1 do m += (res.Errors.Item[i].ToString()) + "\n"
        throw m
    )
    twk_asm = res.CompiledAssembly
)

fn tweak_start = (
    if twk_hook != undefined and twk_hook.IsRunning do (
        format "tweak: already running.\n"
        return false
    )
    twk_compile()

    local t = twk_asm.GetType "TweakMove.TweakHook"
    twk_hook = (dotNetClass "System.Activator").CreateInstance t
    twk_hook.Modifier = 1     -- 정확 매칭: Ctrl 단독

    dotNet.addEventHandler twk_hook "VertexDragStart" twk_onStart
    dotNet.addEventHandler twk_hook "VertexDragMove"  twk_onMove
    dotNet.addEventHandler twk_hook "VertexDragEnd"   twk_onEnd
    dotNet.addEventHandler twk_hook "VertexHover"     twk_onHover

    twk_hook.Start()

    callbacks.removeScripts id:#tweakDrag
    twk_addCb #selectionSetChanged
    twk_addCb #modPanelSubObjectLevelChanged
    twk_addCb #modPanelSelectionSetChanged
    twk_addCb #modPanelObjPostChange
    callbacks.addScript #preSystemShutdown "if (tweak_stop != undefined) do tweak_stop()" id:#tweakDrag
    twk_poll()

    format "tweak: started (Ctrl-hover highlights nearest vertex; Ctrl+middle-drag tweaks it).\n"
    true
)

fn tweak_stop = (
    callbacks.removeScripts id:#tweakDrag
    if twk_held == true do ( try ( theHold.Cancel() ) catch (); twk_held = false )
    twk_hoverVidx = undefined
    if twk_hook != undefined do ( try ( twk_hook.Stop() ) catch (); twk_hook = undefined )
    format "tweak: stopped.\n"
)

fn tweak_toggle = (
    if (twk_hook != undefined and twk_hook.IsRunning) then tweak_stop() else tweak_start()
)

macroScript tweak_Toggle
    category:"tweakDrag" buttontext:"Tweak" tooltip:"Toggle Ctrl-hover + Ctrl+middle vertex tweak"
( on execute do ( if (tweak_toggle != undefined) do tweak_toggle() ) )

-- 실행 즉시 시작
try ( tweak_start() )
catch ( format "tweak: failed to start: %\n" (getCurrentException()) )
