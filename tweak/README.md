# tweak

**3ds Max 독립 실행형 도구**: **Ctrl 호버로 커서 밑 버텍스를 실시간 하이라이트 + Ctrl+중간 버튼 드래그로 이동** (Modo의 Tweak 방식).

단일 파일 — C# 후크 소스를 `.ms` 안에 임베드해서 별도 `.cs` 컴패니언이 필요 없습니다.

---

A **standalone** 3ds Max tool: **Ctrl-hover live-highlights the nearest vertex, and Ctrl + middle-drag tweaks it** (Modo-style Tweak).

Single file — the C# hook source is embedded in the `.ms`, so there is no companion `.cs` to keep alongside it.

---

## 기능 / What it does

Editable Poly가 선택돼 있으면 (**서브오브젝트 레벨 진입 불필요**):

- **Ctrl만 누르고** 버텍스 근처로 가면 → 가장 가까운 버텍스가 **실시간으로 빨갛게 하이라이트**됩니다(네이티브 선택색, 커서를 따라 이동).
- 그 상태로 **Ctrl+중간 버튼 드래그**하면 그 버텍스를 화면 평면 위에서 이동합니다. 떼면 단일 언두(`Tweak Vertex`).
- **드래그가 끝나도(놓아도) 그 버텍스의 선택은 유지됩니다.**
- 중간 버튼 단독은 평소대로 팬. 왼쪽 버튼은 건드리지 않음.
- 정확 매칭(**Ctrl 단독**)이라 `shiftVertexDrag`(Shift) / `pivotZDrag`(Ctrl+Shift)와 충돌하지 않습니다.
- 빨간 하이라이트는 **버텍스 서브오브젝트 레벨**일 때 보입니다.

---

When an Editable Poly is selected (**no need to enter a sub-object level**):

- **Holding Ctrl** and moving near a vertex → the nearest vertex **live-highlights red** (native selection color, following the cursor).
- From there, **Ctrl + middle-drag** moves that vertex along the screen plane. Release = one undo (`Tweak Vertex`).
- **The vertex stays selected after the drag ends.**
- Middle alone pans; the left button is never touched.
- Exact modifier match (**Ctrl only**) — never collides with `shiftVertexDrag` (Shift) or `pivotZDrag` (Ctrl+Shift).
- The red highlight is visible while in **Vertex sub-object level**.

---

## 설치 / Install

1. **Scripting > Run Script…** → `tweak.ms`. 즉시 시작됩니다.
2. 다시 실행하면 토글, 또는 **Tweak** 매크로 사용 (Customize > Toolbars, 카테고리 *tweakDrag*).

`.cs` 파일이 따로 필요 없으므로 파일 하나만 있으면 됩니다.

---

1. **Scripting > Run Script…** → `tweak.ms`. Starts immediately.
2. Run again to toggle, or use the **Tweak** macro (Customize > Toolbars, category *tweakDrag*).

No companion `.cs` file is needed — it is a single self-contained file.

---

## 설정 / Configuration

- **픽 반경:** `twk_pickRadius` (기본 `40.0` 픽셀) — 커서에서 이 반경 안의 최근접 버텍스만 집습니다.
- **수식어:** `tweak_start()` 내 `twk_hook.Modifier` (`0` 없음, `1` Ctrl, `2` Alt, `3` Shift — 기본 Ctrl).
- **빨간 하이라이트:** `twk_showRed` (기본 `true`) — Ctrl 호버 시 최근접 버텍스를 빨갛게 선택 표시하고, 드래그로 이동한 뒤에도 그 선택을 유지합니다. **버텍스 서브오브젝트 레벨**일 때 보입니다. `twk_showRed = false` 로 끌 수 있습니다(호버 하이라이트도 함께 꺼짐).
- **십자 커서:** `twk_showCross` (기본 `true`) — Ctrl 호버 중 **이동 가능한(반경 내) 버텍스 위에 있을 때만** 마우스 포인터를 십자(Cross)로 바꿉니다. best-effort라 뷰포트 종류/Max 버전에 따라 유지되지 않을 수 있습니다. `twk_showCross = false` 로 끕니다.

- **Pick radius:** `twk_pickRadius` (default `40.0` px) — only grabs the nearest vertex within this radius.
- **Modifier:** in `tweak_start()` set `twk_hook.Modifier` (`0` none, `1` Ctrl, `2` Alt, `3` Shift — default Ctrl).
- **Red highlight:** `twk_showRed` (default `true`) — red-selects the nearest vertex on Ctrl-hover and keeps that selection after the drag. Visible while in **Vertex sub-object level**. Set `twk_showRed = false` to disable (also turns off the hover highlight).
- **Crosshair cursor:** `twk_showCross` (default `true`) — during Ctrl-hover, turns the pointer into a crosshair (Cross) **only when over a grabbable vertex (within the radius)**. Best-effort; may not hold on some viewport types / Max versions. Set `twk_showCross = false` to disable.

---

## 참고 / Notes

- **Editable Poly 전용.** 버텍스 1개만 이동(폴오프 없음). 화면 거리 기준 최근접이라 메시 뒤편 버텍스가 더 가까우면 그게 잡힐 수 있습니다 — 원하는 버텍스를 정밀히 가리키면 됩니다.
- 화면↔월드 매핑·픽은 **활성 뷰포트** 기준. Ctrl 호버 중에는 최근접 버텍스를 매 이동마다 O(N)으로 찾지만, 이벤트를 코얼레싱하고 **최근접이 바뀔 때만** 리드로우하므로 부담이 적습니다. 아주 조밀한 메시(수십만 버텍스)에서 호버가 무거우면 `twk_showRed = false` 로 호버 하이라이트를 끄면 됩니다.
- Windows 전용 (Win32 마우스 훅).

- **Editable Poly only.** Moves a single vertex (no falloff). Picking is by screen distance, so a vertex on the far side of the mesh can win if it is closer in screen space — point precisely at the vertex you want.
- Screen↔world mapping/pick uses the **active viewport**. During Ctrl-hover the nearest vertex is found O(N) per move, but events are coalesced and a redraw only happens **when the nearest vertex changes**, so the cost stays low. On very dense meshes (100k+ verts) set `twk_showRed = false` to turn off the hover highlight if it lags.
- Windows only (Win32 mouse hook).
