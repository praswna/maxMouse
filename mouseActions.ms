/*  mouseActions.ms - 마우스 드래그 액션 3종 통합 단일 파일 (C# 후크 임베드)
    ==========================================================================
    전역 마우스 후크 기반의 "수식어 + 중간버튼 드래그" 액션만 한 파일로 통합.
    (averageVertices 는 마우스 액션이 아니라 단축키/캐디 매크로이므로 제외.)

    [3개 액션 - 모디파이어 충돌 없음(정확 매칭)]
      1) shiftVertexDrag : Shift + 중간드래그        = 선택 버텍스를 화면 평면으로 이동
      2) pivotZDrag      : Ctrl+Shift + 중간드래그   = 각 버텍스를 자기 표면 법선으로 이동
      3) tweak           : Ctrl + 중간드래그         = 커서 밑 최근접 버텍스를 선택 없이 끌기

    [단일 파일 핵심]
      - 세 C# 후크 소스를 이 파일 안에 "임베드" -> 별도 .cs 컴패니언 불필요.
        Dropbox 등 임의 경로/마스터 통합에서도 동작(경로 의존/동기화 충돌 제거).
      - 세 액션은 전역 접두사(svm_/pzd_/twk_)로 완전 격리. 전역 비공유.
      - 각 시작은 개별 try/catch 로 격리 -> 한 액션 실패가 전체 로딩을 막지 않음.
      - 모든 후크에 핫패스 fast-reject 최적화 반영.

    [공통]
      - 중간버튼 단독은 팬. 왼쪽 버튼은 절대 건드리지 않음.
      - 한 번의 드래그 = 한 번의 Undo. Max 가 포그라운드일 때만 동작.
      - Editable Poly 주 대상(shiftVertexDrag 만 Editable Mesh best-effort).
      - Windows 전용(Win32 WH_MOUSE_LL).

    [실행] Scripting > Run Script -> mouseActions.ms  (또는 마스터에서 fileIn)
    ==========================================================================
*/

-- ###########################################################################
-- ## [ACTION 1] shiftVertexDrag : Shift + 중간드래그 = 화면 평면 이동
-- ###########################################################################

global svm_hook                 -- C# 후크 인스턴스
global svm_asm                  -- 컴파일된 어셈블리
global svm_obj, svm_isPoly, svm_meshCopy, svm_sel, svm_selBA, svm_orig
global svm_center, svm_normal, svm_offset, svm_startLocal, svm_startWorld, svm_delta, svm_ok
global svm_held                 -- theHold(undo) 를 열어두었는지

-- [임베드] ShiftVertexHook.cs. C# 코드 안 큰따옴표는 \" 로 이스케이프되어 있다.
global svm_cs = "// ShiftVertexMove - embedded mouse hook (Shift + middle-drag)
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ShiftVertexMove
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

    public class VertexDragHook
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
        public int  Modifier { get; set; }

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelMouseProc _proc;
        private MsgSink _sink;
        private readonly int _ourPid;

        private bool _vDrag = false, _vMovePosted = false;
        private int _vStartX, _vStartY, _vCurX, _vCurY;

        public event EventHandler<PointEventArgs> VertexDragStart;
        public event EventHandler<PointEventArgs> VertexDragMove;
        public event EventHandler<EventArgs>      VertexDragEnd;

        public VertexDragHook()
        {
            Armed = false;
            Modifier = 3;
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

fn svm_getWorld i = (
    if svm_isPoly then ( polyop.getVert svm_obj i node:svm_obj )
    else ( (getVert svm_meshCopy i) * svm_obj.objecttransform )
)
fn svm_setWorld i wp = (
    if svm_isPoly then ( polyop.setVert svm_obj i wp node:svm_obj )
    else ( setVert svm_meshCopy i (wp * (inverse svm_obj.objecttransform)) )
)
fn svm_commit = ( if not svm_isPoly do ( svm_obj.mesh = svm_meshCopy; update svm_obj.mesh ) )

fn svm_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir svm_normal
    if (abs denom) < 1e-7 then svm_center
    else ( local t = (dot (svm_center - r.pos) svm_normal) / denom; r.pos + t * r.dir )
)

fn svm_gatherVerts obj isPoly lvl = (
    if isPoly then (
        case lvl of (
            1: (polyop.getVertSelection obj)
            2: (polyop.getVertsUsingEdge obj (polyop.getEdgeSelection obj))
            3: (polyop.getVertsUsingEdge obj (polyop.getEdgeSelection obj))
            4: (polyop.getVertsUsingFace obj (polyop.getFaceSelection obj))
            5: (polyop.getVertsUsingFace obj (polyop.getFaceSelection obj))
            default: #{}
        )
    ) else (
        case lvl of (
            1: (getVertSelection obj)
            2: (try (meshop.getVertsUsingEdge obj (getEdgeSelection obj)) catch (#{}))
            default: (try (meshop.getVertsUsingFace obj (getFaceSelection obj)) catch (#{}))
        )
    )
)

fn svm_onStart sender args = (
    svm_ok = false
    if svm_held == true do ( try ( theHold.Cancel() ) catch (); svm_held = false )   -- 이전 드래그 잔여 정리
    try (
        if selection.count != 1 do return false
        svm_obj = selection[1]
        local b = svm_obj.baseObject
        svm_isPoly = (classof b == Editable_Poly)
        local isMesh = (classof b == Editable_Mesh)
        if not (svm_isPoly or isMesh) do return false

        svm_meshCopy = if isMesh then svm_obj.mesh else undefined
        local lvl = try (subobjectLevel) catch (1)
        if lvl == undefined do lvl = 1
        svm_selBA = svm_gatherVerts svm_obj svm_isPoly lvl   -- bitArray (Poly 일괄 setVert용)
        svm_sel   = svm_selBA as array
        if svm_sel.count == 0 do return false

        svm_orig = for i in svm_sel collect (svm_getWorld i)
        local c = [0,0,0]; for w in svm_orig do c += w
        svm_center = c / svm_orig.count
        svm_normal = normalize ((inverse (viewport.getTM())).row3)

        svm_offset = [args.X, args.Y] - mouse.pos
        svm_startLocal = [args.X, args.Y] - svm_offset
        svm_startWorld = svm_planePt svm_startLocal
        svm_delta = [0,0,0]
        theHold.Begin()
        svm_held = true
        svm_ok = true
    ) catch (
        format "shiftVertexDrag: start failed: %\n" (getCurrentException())
        svm_ok = false
        if svm_held == true do ( try ( theHold.Cancel() ) catch (); svm_held = false )
    )
)

fn svm_onMove sender args = (
    if not svm_ok do return false
    try (
        local cur = [args.X, args.Y] - svm_offset
        svm_delta = (svm_planePt cur) - svm_startWorld
        if svm_isPoly then (
            local posArr = for k = 1 to svm_sel.count collect (svm_orig[k] + svm_delta)
            polyop.setVert svm_obj svm_selBA posArr node:svm_obj
        ) else (
            for k = 1 to svm_sel.count do svm_setWorld svm_sel[k] (svm_orig[k] + svm_delta)
            svm_commit()
        )
        redrawViews()
    ) catch ( format "shiftVertexDrag: move failed: %\n" (getCurrentException()) )
)

fn svm_onEnd sender args = (
    if not svm_ok do return false
    svm_ok = false
    try (
        if svm_held == true do (
            if (length svm_delta) > 1e-6 then theHold.Accept "Move Verts (screen)"
            else theHold.Cancel()
            svm_held = false
        )
        redrawViews()
    ) catch (
        format "shiftVertexDrag: commit failed: %\n" (getCurrentException())
        if svm_held == true do ( try ( theHold.Cancel() ) catch (); svm_held = false )
    )
)

fn svm_poll = (
    if svm_hook == undefined do return false
    local armed = false
    if selection.count == 1 do (
        local b = selection[1].baseObject
        local lvl = try (subobjectLevel) catch (0)
        if lvl == undefined do lvl = 0
        if (lvl >= 1 and lvl <= 5) do armed = (classof b == Editable_Poly or classof b == Editable_Mesh)
    )
    svm_hook.Armed = armed
)
fn svm_addCb evt = (
    try ( callbacks.addScript evt "if (svm_poll != undefined) do svm_poll()" id:#shiftVertexDrag ) catch ()
)

-- [임베드 컴파일] 파일을 읽지 않고 내장 문자열 svm_cs 를 컴파일
fn svm_compile = (
    local prov   = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
    local params = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
    params.ReferencedAssemblies.Add "System.dll"
    params.ReferencedAssemblies.Add "System.Windows.Forms.dll"
    params.GenerateInMemory   = true
    params.GenerateExecutable = false

    local res = prov.CompileAssemblyFromSource params #(svm_cs)
    if res.Errors.HasErrors do (
        local m = "shiftVertexDrag: C# compile errors:\n"
        for i = 0 to res.Errors.Count - 1 do m += (res.Errors.Item[i].ToString()) + "\n"
        throw m
    )
    svm_asm = res.CompiledAssembly
)

fn shiftVertexDrag_start = (
    if svm_hook != undefined and svm_hook.IsRunning do (
        format "shiftVertexDrag: already running.\n"
        return false
    )
    svm_compile()

    local t = svm_asm.GetType "ShiftVertexMove.VertexDragHook"
    svm_hook = (dotNetClass "System.Activator").CreateInstance t
    svm_hook.Modifier = 3     -- 트리거 수정자: 0=없음, 1=Ctrl, 2=Alt, 3=Shift

    dotNet.addEventHandler svm_hook "VertexDragStart" svm_onStart
    dotNet.addEventHandler svm_hook "VertexDragMove"  svm_onMove
    dotNet.addEventHandler svm_hook "VertexDragEnd"   svm_onEnd

    svm_hook.Start()

    callbacks.removeScripts id:#shiftVertexDrag
    svm_addCb #selectionSetChanged
    svm_addCb #modPanelSubObjectLevelChanged
    svm_addCb #modPanelSelectionSetChanged
    svm_addCb #modPanelObjPostChange
    callbacks.addScript #preSystemShutdown "if (shiftVertexDrag_stop != undefined) do shiftVertexDrag_stop()" id:#shiftVertexDrag
    svm_poll()

    format "shiftVertexDrag: started (Shift + middle-drag moves verts in screen space).\n"
    true
)

fn shiftVertexDrag_stop = (
    callbacks.removeScripts id:#shiftVertexDrag
    if svm_held == true do ( try ( theHold.Cancel() ) catch (); svm_held = false )
    if svm_hook != undefined do ( try ( svm_hook.Stop() ) catch (); svm_hook = undefined )
    format "shiftVertexDrag: stopped.\n"
)

fn shiftVertexDrag_toggle = (
    if (svm_hook != undefined and svm_hook.IsRunning) then shiftVertexDrag_stop() else shiftVertexDrag_start()
)

macroScript shiftVertexDrag_Toggle
    category:"shiftVertexDrag" buttontext:"ShiftVertDrag" tooltip:"Toggle Shift+middle vertex drag"
( on execute do ( if (shiftVertexDrag_toggle != undefined) do shiftVertexDrag_toggle() ) )


-- ###########################################################################
-- ## [ACTION 2] pivotZDrag : Ctrl+Shift + 중간드래그 = 각 버텍스를 자기 법선으로 이동
-- ###########################################################################

global pzd_hook
global pzd_asm
global pzd_obj, pzd_sel, pzd_selBA, pzd_orig
global pzd_center, pzd_normal, pzd_axis, pzd_offset, pzd_startLocal, pzd_startWorld, pzd_ok
global pzd_invOTM                    -- inverse(objecttransform) 캐시 (드래그 중 불변)
global pzd_norm                      -- 각 버텍스의 (로컬) 법선 배열(sel 과 같은 순서)
global pzd_amt                       -- 이동량(스칼라)
global pzd_prevCoord                 -- 드래그 전 좌표계(끝나면 복원)
global pzd_prevPivotTM               -- 드래그 전 워킹 피벗 TM(끝나면 복원, 비파괴)
global pzd_switched                  -- 좌표계/피벗을 바꿨고 아직 복원 안 했는지
global pzd_held                      -- theHold(undo) 를 열어두었는지

-- [임베드] PivotZHook.cs.
global pzd_cs = "// PivotZMove - embedded mouse hook (Ctrl+Shift + middle-drag)
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
        public int  Modifiers { get; set; }

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
            Modifiers = 1 | 4;
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

        private bool ModifiersMatch()
        {
            int cur = 0;
            if ((GetAsyncKeyState(0x11) & 0x8000) != 0) cur |= 1;
            if ((GetAsyncKeyState(0x12) & 0x8000) != 0) cur |= 2;
            if ((GetAsyncKeyState(0x10) & 0x8000) != 0) cur |= 4;
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
                        if (ModifiersMatch())
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

-- 좌표계/워킹 피벗을 드래그 전 상태로 복원 (전환했을 때만)
fn pzd_restoreCoord = (
    if pzd_switched == true do (
        if pzd_prevPivotTM != undefined do ( try ( WorkingPivot.setTM pzd_prevPivotTM ) catch () )
        if pzd_prevCoord  != undefined do ( try ( toolMode.coordsys pzd_prevCoord ) catch () )
        pzd_switched = false
    )
)

fn pzd_getWorld i = ( polyop.getVert pzd_obj i node:pzd_obj )
fn pzd_getObj   i = ( polyop.getVert pzd_obj i )

fn pzd_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir pzd_normal
    if (abs denom) < 1e-7 then pzd_center
    else ( local t = (dot (pzd_center - r.pos) pzd_normal) / denom; r.pos + t * r.dir )
)

fn pzd_tmFromZ zdir pos = (
    local z = normalize zdir
    local upv = if (abs (dot z [0,0,1])) > 0.99 then [1,0,0] else [0,0,1]
    local x = normalize (cross upv z)
    local y = normalize (cross z x)
    matrix3 x y z pos
)

fn pzd_vertNormals obj sel = (
    local norms = #()
    for vi in sel do (
        local faces = polyop.getFacesUsingVert obj #{vi}
        local n = [0,0,0]
        for f in faces do n += polyop.getFaceNormal obj f
        if (length n) < 1e-9 do n = [0,0,1]
        append norms (normalize n)
    )
    norms
)

fn pzd_gatherVerts obj lvl = (
    case lvl of (
        1: (polyop.getVertSelection obj)
        2: (polyop.getVertsUsingEdge obj (polyop.getEdgeSelection obj))
        3: (polyop.getVertsUsingEdge obj (polyop.getEdgeSelection obj))
        4: (polyop.getVertsUsingFace obj (polyop.getFaceSelection obj))
        5: (polyop.getVertsUsingFace obj (polyop.getFaceSelection obj))
        default: #{}
    )
)

fn pzd_onStart sender args = (
    pzd_ok = false
    pzd_restoreCoord()    -- 이전 드래그가 미완료로 좌표계를 바꿔놨다면 먼저 원복(원본 보존)
    if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
    pzd_switched = false
    try (
        if selection.count != 1 do return false
        pzd_obj = selection[1]
        if (classof pzd_obj.baseObject != Editable_Poly) do return false   -- Editable Poly 전용

        local lvl = try (subobjectLevel) catch (1)
        if lvl == undefined do lvl = 1
        pzd_selBA = pzd_gatherVerts pzd_obj lvl
        pzd_sel = pzd_selBA as array
        if pzd_sel.count == 0 do return false
        pzd_invOTM = inverse pzd_obj.objecttransform

        pzd_orig = for i in pzd_sel collect (pzd_getObj i)
        local wc = [0,0,0]
        for i in pzd_sel do wc += (pzd_getWorld i)
        pzd_center = wc / pzd_sel.count

        pzd_normal = normalize ((inverse (viewport.getTM())).row3)

        pzd_norm = pzd_vertNormals pzd_obj pzd_sel
        local an = [0,0,0]; for nrm in pzd_norm do an += nrm
        pzd_axis = if (length an) > 1e-6 then (normalize an) else [0,0,1]

        local otm = pzd_obj.objecttransform
        local avgWorld = normalize ((pzd_axis * otm) - otm.row4)
        pzd_prevCoord   = try (getRefCoordSys()) catch (#world)
        pzd_prevPivotTM = try (WorkingPivot.getTM()) catch (undefined)
        try (
            WorkingPivot.setTM (pzd_tmFromZ avgWorld pzd_center)
            toolMode.coordsys #working_pivot
            pzd_switched = true
        ) catch ()

        pzd_offset = [args.X, args.Y] - mouse.pos
        pzd_startLocal = [args.X, args.Y] - pzd_offset
        pzd_startWorld = pzd_planePt pzd_startLocal
        pzd_amt = 0.0
        theHold.Begin()
        pzd_held = true
        pzd_ok = true
    ) catch (
        format "pivotZDrag: start failed: %\n" (getCurrentException())
        pzd_ok = false
        if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
        pzd_restoreCoord()
    )
)

fn pzd_amtFromDrag args = (
    local cur = [args.X, args.Y] - pzd_offset
    local d   = (pzd_planePt cur) - pzd_startWorld
    local dObj = (d * pzd_invOTM) - pzd_invOTM.row4
    dot dObj pzd_axis
)

fn pzd_applyAmt amt = (
    local posArr = for k = 1 to pzd_sel.count collect (pzd_orig[k] + amt * pzd_norm[k])
    polyop.setVert pzd_obj pzd_selBA posArr
)

fn pzd_onMove sender args = (
    if not pzd_ok do return false
    try (
        pzd_amt = pzd_amtFromDrag args
        pzd_applyAmt pzd_amt
        redrawViews()
    ) catch ( format "pivotZDrag: move failed: %\n" (getCurrentException()) )
)

fn pzd_onEnd sender args = (
    if not pzd_ok do return false
    pzd_ok = false
    try (
        if pzd_held == true do (
            if (abs pzd_amt) > 1e-6 then theHold.Accept "Move Verts (vertex normals)"
            else theHold.Cancel()
            pzd_held = false
        )
        redrawViews()
    ) catch (
        format "pivotZDrag: commit failed: %\n" (getCurrentException())
        if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
    )
    pzd_restoreCoord()
)

fn pzd_poll = (
    if pzd_hook == undefined do return false
    local armed = false
    if selection.count == 1 do (
        local b = selection[1].baseObject
        local lvl = try (subobjectLevel) catch (0)
        if lvl == undefined do lvl = 0
        if (lvl >= 1 and lvl <= 5) do armed = (classof b == Editable_Poly)
    )
    pzd_hook.Armed = armed
)
fn pzd_addCb evt = (
    try ( callbacks.addScript evt "if (pzd_poll != undefined) do pzd_poll()" id:#pivotZDrag ) catch ()
)

-- [임베드 컴파일] 파일을 읽지 않고 내장 문자열 pzd_cs 를 컴파일
fn pzd_compile = (
    local prov   = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
    local params = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
    params.ReferencedAssemblies.Add "System.dll"
    params.ReferencedAssemblies.Add "System.Windows.Forms.dll"
    params.GenerateInMemory   = true
    params.GenerateExecutable = false

    local res = prov.CompileAssemblyFromSource params #(pzd_cs)
    if res.Errors.HasErrors do (
        local m = "pivotZDrag: C# compile errors:\n"
        for i = 0 to res.Errors.Count - 1 do m += (res.Errors.Item[i].ToString()) + "\n"
        throw m
    )
    pzd_asm = res.CompiledAssembly
)

fn pivotZDrag_start = (
    if pzd_hook != undefined and pzd_hook.IsRunning do (
        format "pivotZDrag: already running.\n"
        return false
    )
    pzd_compile()

    local t = pzd_asm.GetType "PivotZMove.PivotZDragHook"
    pzd_hook = (dotNetClass "System.Activator").CreateInstance t
    pzd_hook.Modifiers = (bit.or 1 4)     -- 정확 매칭: Ctrl(1) + Shift(4)

    dotNet.addEventHandler pzd_hook "VertexDragStart" pzd_onStart
    dotNet.addEventHandler pzd_hook "VertexDragMove"  pzd_onMove
    dotNet.addEventHandler pzd_hook "VertexDragEnd"   pzd_onEnd

    pzd_hook.Start()

    callbacks.removeScripts id:#pivotZDrag
    pzd_addCb #selectionSetChanged
    pzd_addCb #modPanelSubObjectLevelChanged
    pzd_addCb #modPanelSelectionSetChanged
    pzd_addCb #modPanelObjPostChange
    callbacks.addScript #preSystemShutdown "if (pivotZDrag_stop != undefined) do pivotZDrag_stop()" id:#pivotZDrag
    pzd_poll()

    format "pivotZDrag: started (Ctrl+Shift + middle-drag moves verts along their surface normals).\n"
    true
)

fn pivotZDrag_stop = (
    callbacks.removeScripts id:#pivotZDrag
    if pzd_held == true do ( try ( theHold.Cancel() ) catch (); pzd_held = false )
    pzd_restoreCoord()
    if pzd_hook != undefined do ( try ( pzd_hook.Stop() ) catch (); pzd_hook = undefined )
    format "pivotZDrag: stopped.\n"
)

fn pivotZDrag_toggle = (
    if (pzd_hook != undefined and pzd_hook.IsRunning) then pivotZDrag_stop() else pivotZDrag_start()
)

macroScript pivotZDrag_Toggle
    category:"pivotZDrag" buttontext:"PivotZDrag" tooltip:"Toggle Ctrl+Shift+middle move along vertex normals"
( on execute do ( if (pivotZDrag_toggle != undefined) do pivotZDrag_toggle() ) )


-- ###########################################################################
-- ## [ACTION 3] tweak : Ctrl + 중간드래그 = 커서 밑 최근접 버텍스를 선택 없이 끌기
-- ###########################################################################

global twk_hook
global twk_asm
global twk_obj, twk_vidx, twk_orig
global twk_center, twk_normal, twk_offset, twk_startLocal, twk_startWorld, twk_delta, twk_ok
global twk_held
global twk_pickRadius           -- 커서에서 이 픽셀 반경 안의 최근접 버텍스만 집음
if twk_pickRadius == undefined do twk_pickRadius = 40.0

-- [임베드] TweakMove 후크 소스.
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

fn twk_planePt p = (
    local r = mapScreenToWorldRay p
    local denom = dot r.dir twk_normal
    if (abs denom) < 1e-7 then twk_center
    else ( local t = (dot (twk_center - r.pos) twk_normal) / denom; r.pos + t * r.dir )
)

-- 커서(뷰포트 좌표)에서 가장 가까운 버텍스 인덱스(픽셀 반경 내). 없으면 undefined.
--   gw.transPoint 로 각 버텍스를 화면좌표로 투영해 최근접 탐색. 드래그 시작 때 1회만(O(N)).
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

fn twk_onStart sender args = (
    twk_ok = false
    if twk_held == true do ( try ( theHold.Cancel() ) catch (); twk_held = false )
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
        theHold.Begin()
        twk_held = true
        twk_ok = true
    ) catch (
        format "tweak: start failed: %\n" (getCurrentException())
        twk_ok = false
        if twk_held == true do ( try ( theHold.Cancel() ) catch (); twk_held = false )
    )
)

fn twk_onMove sender args = (
    if not twk_ok do return false
    try (
        local cur = [args.X, args.Y] - twk_offset
        twk_delta = (twk_planePt cur) - twk_startWorld
        polyop.setVert twk_obj twk_vidx (twk_orig + twk_delta) node:twk_obj
        redrawViews()
    ) catch ( format "tweak: move failed: %\n" (getCurrentException()) )
)

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

fn twk_poll = (
    if twk_hook == undefined do return false
    local armed = false
    if selection.count == 1 do armed = (classof selection[1].baseObject == Editable_Poly)
    twk_hook.Armed = armed
)
fn twk_addCb evt = (
    try ( callbacks.addScript evt "if (twk_poll != undefined) do twk_poll()" id:#tweakDrag ) catch ()
)

-- [임베드 컴파일] 파일을 읽지 않고 내장 문자열 twk_cs 를 컴파일
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


-- ###########################################################################
-- ## [시작] 각 액션을 개별 try/catch 로 격리 시작 (한 액션 실패가 전체를 막지 않음)
-- ###########################################################################
try ( shiftVertexDrag_start() )
catch ( format "mouseActions: shiftVertexDrag 시작 실패: %\n" (getCurrentException()) )

try ( pivotZDrag_start() )
catch ( format "mouseActions: pivotZDrag 시작 실패: %\n" (getCurrentException()) )

try ( tweak_start() )
catch ( format "mouseActions: tweak 시작 실패: %\n" (getCurrentException()) )

format "mouseActions: 준비 완료 (Shift / Ctrl+Shift / Ctrl + 중간드래그).\n"
