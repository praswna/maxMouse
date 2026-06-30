/*  tweak - "Ctrl + 휠(중간버튼) 드래그 = 커서 밑 버텍스를 선택 없이 바로 끌기" (Editable Poly)
    ==========================================================================
    [개요]  ※ Modo 의 Tweak 처럼 "선택하지 않고" 커서 바로 밑 버텍스를 잡아 끕니다.
    Editable Poly 가 선택돼 있으면(서브오브젝트 레벨 진입 불필요), CTRL 을 누른 채
    중간(휠) 버튼으로 드래그하면 커서에서 가장 가까운 버텍스 1개를 화면과 평행한
    평면을 따라 이동합니다. 떼면 단일 Undo("Tweak Vertex").
      - 선택을 바꾸지 않습니다(현재 선택/서브레벨 그대로 유지).
      - 중간버튼 단독은 평소대로 팬. 왼쪽 버튼은 건드리지 않음.
      - 정확 매칭(Ctrl 단독)이라 Shift / Ctrl+Shift 도구와 안 겹침.

    [단일 파일] C# 후크 소스를 이 .ms 안에 임베드 -> 별도 .cs 컴패니언 불필요.
        (Dropbox 등 임의 경로에서도 동작. getThisScriptFilename 경로 의존 없음.)
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
if twk_pickRadius == undefined do twk_pickRadius = 40.0

-- [임베드] TweakMove 후크 소스. C# 코드 안 큰따옴표는 \" 로 이스케이프되어 있다.
global twk_cs = "// TweakMove - embedded mouse hook (Ctrl + middle-drag, hover tweak)
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
        public Action OnVStart, OnVMove, OnVEnd;

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

        private bool _vDrag = false, _vMovePosted = false;
        private int _vStartX, _vStartY, _vCurX, _vCurY;

        public event EventHandler<PointEventArgs> VertexDragStart;
        public event EventHandler<PointEventArgs> VertexDragMove;
        public event EventHandler<EventArgs>      VertexDragEnd;

        public TweakHook()
        {
            Armed = false;
            Modifier = 1;   // Ctrl + middle by default
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
                bool want = (msg == WM_MBUTTONDOWN && Armed)
                         || (msg == WM_MBUTTONUP   && _vDrag)
                         || (msg == WM_MOUSEMOVE   && _vDrag);
                if (want && MaxForeground())
                {
                    MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                    int px = data.pt.x, py = data.pt.y;
                    if (msg == WM_MBUTTONDOWN)
                    {
                        if (ModifierDown())
                        {
                            _vDrag = true; _vMovePosted = false;
                            _vStartX = px; _vStartY = py; _vCurX = px; _vCurY = py;
                            PostMessage(_sink.Handle, MsgSink.WM_VSTART, IntPtr.Zero, IntPtr.Zero);
                            return (IntPtr)1;
                        }
                    }
                    else if (msg == WM_MBUTTONUP)
                    {
                        _vCurX = px; _vCurY = py; _vDrag = false;
                        PostMessage(_sink.Handle, MsgSink.WM_VEND, IntPtr.Zero, IntPtr.Zero);
                        return (IntPtr)1;
                    }
                    else
                    {
                        _vCurX = px; _vCurY = py;
                        if (!_vMovePosted)
                        {
                            _vMovePosted = true;
                            PostMessage(_sink.Handle, MsgSink.WM_VMOVE, IntPtr.Zero, IntPtr.Zero);
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

-- 커서(뷰포트 좌표 cursorVP) 에서 가장 가까운 버텍스 인덱스(픽셀 반경 내). 없으면 undefined.
--   gw.transPoint 로 각 버텍스의 월드 위치를 활성 뷰포트 화면좌표로 투영해 최근접 탐색.
--   드래그 시작 때 1회만(O(N)) 수행하므로 이동 중 비용 없음.
--   (주의: 화면거리 기준이라 메시 뒤편 버텍스가 더 가까우면 그게 잡힐 수 있음 - 정밀히
--    원하는 버텍스를 가리키면 됨.)
fn twk_pickVert obj cursorVP = (
    local nv = polyop.getNumVerts obj
    gw.setTransform (matrix3 1)                 -- gw 변환을 항등(월드)으로
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

-- [드래그 시작] 커서 밑 최근접 버텍스를 집어 원위치/평면을 기록 (선택은 건드리지 않음)
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

        twk_orig   = polyop.getVert twk_obj twk_vidx node:twk_obj   -- 월드 원위치
        twk_center = twk_orig                                       -- 평면은 잡은 버텍스를 통과
        twk_normal = normalize ((inverse (viewport.getTM())).row3)  -- 시선(화면 평면 법선)
        twk_startWorld = twk_planePt twk_startLocal
        twk_delta = [0,0,0]
        theHold.Begin()
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
        redrawViews()
    ) catch ( format "tweak: move failed: %\n" (getCurrentException()) )
)

-- [드래그 끝] 움직였으면 단일 Undo, 아니면 빈 Undo 안 만듦
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

    twk_hook.Start()

    callbacks.removeScripts id:#tweakDrag
    twk_addCb #selectionSetChanged
    twk_addCb #modPanelSubObjectLevelChanged
    twk_addCb #modPanelSelectionSetChanged
    twk_addCb #modPanelObjPostChange
    callbacks.addScript #preSystemShutdown "if (tweak_stop != undefined) do tweak_stop()" id:#tweakDrag
    twk_poll()

    format "tweak: started (Ctrl + middle-drag tweaks the nearest vertex under the cursor).\n"
    true
)

fn tweak_stop = (
    callbacks.removeScripts id:#tweakDrag
    if twk_held == true do ( try ( theHold.Cancel() ) catch (); twk_held = false )
    if twk_hook != undefined do ( try ( twk_hook.Stop() ) catch (); twk_hook = undefined )
    format "tweak: stopped.\n"
)

fn tweak_toggle = (
    if (twk_hook != undefined and twk_hook.IsRunning) then tweak_stop() else tweak_start()
)

macroScript tweak_Toggle
    category:"tweakDrag" buttontext:"Tweak" tooltip:"Toggle Ctrl+middle hover tweak (nearest vertex)"
( on execute do ( if (tweak_toggle != undefined) do tweak_toggle() ) )

-- 실행 즉시 시작
try ( tweak_start() )
catch ( format "tweak: failed to start: %\n" (getCurrentException()) )
