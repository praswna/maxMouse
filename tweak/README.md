# tweak

**3ds Max 독립 실행형 도구**: **Ctrl + 중간 버튼 드래그로 커서 밑 버텍스를 선택 없이 바로 끌기** (Modo의 Tweak 방식).

단일 파일 — C# 후크 소스를 `.ms` 안에 임베드해서 별도 `.cs` 컴패니언이 필요 없습니다.

---

A **standalone** 3ds Max tool: **Ctrl + middle-drag tweaks the nearest vertex under the cursor — no selection needed** (Modo-style Tweak).

Single file — the C# hook source is embedded in the `.ms`, so there is no companion `.cs` to keep alongside it.

---

## 기능 / What it does

Editable Poly가 선택돼 있으면 (**서브오브젝트 레벨 진입 불필요**), **Ctrl**을 누른 채 **중간 버튼**을 드래그하면 커서에서 가장 가까운 버텍스 1개를 화면 평면 위에서 이동합니다. 떼면 단일 언두(`Tweak Vertex`).

- **선택을 바꾸지 않습니다** (현재 선택/서브레벨 그대로 유지).
- 중간 버튼 단독은 평소대로 팬. 왼쪽 버튼은 건드리지 않음.
- 정확 매칭(**Ctrl 단독**)이라 `shiftVertexDrag`(Shift) / `pivotZDrag`(Ctrl+Shift)와 충돌하지 않습니다.

---

When an Editable Poly is selected (**no need to enter a sub-object level**), holding **Ctrl** and dragging the **middle button** moves the single nearest vertex to the cursor along the screen plane. Release = one undo (`Tweak Vertex`).

- **Does not change the selection.**
- Middle alone pans; the left button is never touched.
- Exact modifier match (**Ctrl only**) — never collides with `shiftVertexDrag` (Shift) or `pivotZDrag` (Ctrl+Shift).

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
- **빨간 하이라이트:** `twk_showRed` (기본 `true`) — 드래그 동안 잡은 버텍스를 임시 선택해 빨갛게 표시하고, 놓으면 원래 선택을 복원합니다. **버텍스 서브오브젝트 레벨**일 때 보입니다. `twk_showRed = false` 로 끌 수 있습니다.

- **Pick radius:** `twk_pickRadius` (default `40.0` px) — only grabs the nearest vertex within this radius.
- **Modifier:** in `tweak_start()` set `twk_hook.Modifier` (`0` none, `1` Ctrl, `2` Alt, `3` Shift — default Ctrl).
- **Red highlight:** `twk_showRed` (default `true`) — temporarily selects the grabbed vertex so it shows red during the drag, then restores the original selection on release. Visible while in **Vertex sub-object level**. Set `twk_showRed = false` to disable.

---

## 참고 / Notes

- **Editable Poly 전용.** 버텍스 1개만 이동(폴오프 없음). 화면 거리 기준 최근접이라 메시 뒤편 버텍스가 더 가까우면 그게 잡힐 수 있습니다 — 원하는 버텍스를 정밀히 가리키면 됩니다.
- 화면↔월드 매핑·픽은 **활성 뷰포트** 기준. 큰 메시에서 픽은 드래그 시작 시 1회만(O(N))이라 이동 중 비용은 없습니다.
- Windows 전용 (Win32 마우스 훅).

- **Editable Poly only.** Moves a single vertex (no falloff). Picking is by screen distance, so a vertex on the far side of the mesh can win if it is closer in screen space — point precisely at the vertex you want.
- Screen↔world mapping/pick uses the **active viewport**. On large meshes the pick is a one-time O(N) at drag start, so there is no per-move cost.
- Windows only (Win32 mouse hook).
