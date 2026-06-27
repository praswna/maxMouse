# maxMouse

**3ds Max** 모델링 보조 도구 모음입니다. 각 도구는 독립 실행형으로, 원하는 것만 골라 쓸 수 있습니다.
MAXScript로 작성되었으며, 마우스 훅이 필요한 두 도구만 런타임에 C#을 컴파일합니다.

A small collection of standalone **3ds Max** modeling tools (MAXScript, with
runtime-compiled C# only where a global mouse hook is needed). Each tool lives
in its own folder and is fully independent — run whichever you want.

> 무료 공개 도구입니다 — MIT 라이선스. / Free and open-source — MIT License.

---

## 도구 목록 / Tools

| 폴더 / Folder | 단축키 / Trigger | 기능 / What it does |
|---|---|---|
| [`shiftVertexDrag/`](shiftVertexDrag/) | **Shift + 중간 드래그** / **Shift + middle-drag** | 선택한 버텍스를 **화면 평면** 위에서 이동. 뷰포트 패닝 없음. / Slides the selection along the **screen plane** — viewport does not pan. |
| [`pivotZDrag/`](pivotZDrag/) | **Ctrl+Shift + 중간 드래그** / **Ctrl+Shift + middle-drag** | 선택한 각 버텍스를 **자신의 서피스 노멀** 방향으로 이동 (Inflate). Editable Poly 전용. / Moves each vertex along **its own surface normal** (inflate/deflate). Editable Poly only. |
| [`averageVertices/`](averageVertices/) | **단축키 직접 지정** / **hotkey (you assign)** | **버텍스 평균화 / 릴랙스** (라플라시안 스무딩) — 즉시 실행 매크로 또는 커서 옆 캐디 팝업으로 라이브 프리뷰. / **Average / Relax Vertices** (Laplacian smoothing) — instant macro or cursor-side caddy with live preview. |

각 폴더에 상세 README가 있습니다. / Each folder has its own `README.md` with install, usage, and caveats.

---

## 공통 사항 / Common Notes

- **Editable Poly**가 주 대상입니다. `shiftVertexDrag`는 Editable Mesh도 부분 지원하며, `pivotZDrag`와 `averageVertices`는 Editable Poly 전용입니다.
- 드래그 두 도구(`shiftVertexDrag`, `pivotZDrag`)는 **3ds Max가 포그라운드 앱일 때만** 동작하는 전역 마우스 훅을 설치합니다. 왼쪽 버튼은 건드리지 않으며, 두 도구는 정확한 수식어 매칭으로 충돌하지 않습니다.
- `averageVertices`는 순수 MAXScript(훅 없음)이며, 직접 단축키를 지정할 수 있는 매크로를 등록합니다.
- 마우스 훅 도구는 **Windows 전용**입니다 (Win32 `WH_MOUSE_LL`).

---

- **Editable Poly** is the primary target. `shiftVertexDrag` also has a best-effort Editable Mesh path; `pivotZDrag` and `averageVertices` are Editable Poly only.
- The two drag tools install a global low-level mouse hook that only acts while **3ds Max is the foreground app**; the left button is never touched, and they coexist via exact modifier matching.
- `averageVertices` is pure MAXScript (no hook) and registers macros you bind to a shortcut.
- Windows only for the mouse-hook tools (Win32 `WH_MOUSE_LL`).

---

## 설치 / Install

1. 각 도구의 파일을 해당 폴더 안에 같이 두세요.
2. **Scripting > Run Script…** → 해당 도구의 `.ms` 파일 실행.
3. 드래그 도구는 즉시 시작됩니다. `averageVertices`는 **Customize > Hotkeys** (카테고리 `#MyKUI`)에서 단축키를 지정하세요.

---

1. Keep each tool's files together in its folder.
2. **Scripting > Run Script…** → the tool's `.ms`.
3. Drag tools start immediately; `averageVertices` registers macros you assign in **Customize > Hotkeys** (category `#MyKUI`).

---

## 호환성 / Compatibility

- **Windows 전용** (드래그 도구는 Win32 `WH_MOUSE_LL` 훅 사용).
- 주로 **Editable Poly** (각 도구 README 참조). **Edit Poly / Edit Mesh 모디파이어는 지원하지 않습니다** — 베이스 오브젝트에 직접 작동합니다.
- 드래그 도구는 .NET `CSharpCodeProvider`로 **런타임에 C#을 컴파일**합니다. 3ds Max 2025+ (.NET 8 환경)에서는 동작 확인 후 사용하세요.

---

- **Windows only** (the drag tools use a Win32 `WH_MOUSE_LL` hook).
- **Editable Poly** primarily (see per-tool notes); **Edit Poly / Edit Mesh modifiers are not handled**.
- The drag tools **runtime-compile their C# hook** with the .NET `CSharpCodeProvider`. Test on your target 3ds Max version before relying on it.

---

## 라이선스 / License

MIT — 자유롭게 사용, 수정, 배포 가능합니다. / Free to use, modify, and redistribute.
