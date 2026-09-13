# LockOnFovChanger

The Blood of Dawnwalker — Lock-On 相機調整 Mod  
作者：lukazou (luka.zou@gmail.com)

---

## 這個 Mod 做什麼？

本 Mod 可調整「鎖定敵人（Hard Lock）」時的相機，主要功能：

### 1. Lock-On FOV（視野角）

- 鎖定敵人時套用你設定的 FOV；解除鎖定時還原遊戲原始 FOV
- 遊戲平常約 90，實際依遊戲內設定而異
- 可在 INI 關閉（`FOVEnabled=false`），只使用下方 Offset 功能

### 2. LockOnOffsetZ（俯視高度 / pitch）

- 鎖定敵人時套用；解除鎖定時還原
- 數值越大，鏡頭越俯視（越高往下看）
- `0` = 遊戲預設

### 3. EnemyOffset（側向 Y 偏移）

- 鎖定敵人時套用；解除鎖定時還原為遊戲預設 `120`
- `120` = 遊戲預設（敵人右邊偏移）
- `-180` = 鏡頭居中（敵人在正前方）
- 可設任意數值微調左右視角（例如 `-30`、`60`）

---

## 安裝前準備 — 必須先安裝 UE4SS

本 Mod 依賴 UE4SS 才能載入，請先安裝 [UE4SS for Dawnwalker](https://www.nexusmods.com/thebloodofdawnwalker/mods/18?tab=files)。

請依照該 Mod 頁面的說明完成 UE4SS 安裝，並確認遊戲能正常啟動。

---

## Mod 安裝步驟

1. 解壓本 Mod，將整個 `LockOnFovChanger` 資料夾放到：

   ```
   <遊戲目錄>\Dawnwalker\Binaries\Win64\ue4ss\Mods\LockOnFovChanger\
   ```

   範例（Steam 預設路徑）：

   ```
   D:\steam\steamapps\common\The Blood of Dawnwalker\
     Dawnwalker\Binaries\Win64\ue4ss\Mods\LockOnFovChanger\
   ```

2. 確認資料夾結構如下：

   ```
   LockOnFovChanger/
   ├── enabled.txt
   └── Scripts/
       ├── main.lua
       └── LockOnFovChanger.ini
   ```

3. `enabled.txt` 內容應為 `1`（表示啟用此 Mod）。

4. 編輯 `Scripts\LockOnFovChanger.ini`（見下方說明）。

5. 完全關閉遊戲後重新啟動（修改 INI 後必須重開遊戲才會生效）。

6. （選用）進遊戲後開啟 UE4SS 主控台，輸入 `clo ver`，若有顯示版本號即代表 Mod 已載入。

---

## INI 設定檔（`LockOnFovChanger.ini`）

- 路徑：`Scripts\LockOnFovChanger.ini`
- 遊戲啟動時讀取一次；修改後請重開遊戲
- `clo` 指令只改記憶體，不會自動寫回 INI

### 參數說明

| 參數 | 說明 |
|------|------|
| `FOVEnabled` | 是否啟用 Lock-On FOV。`false` = 鎖定時不改 FOV，仍可使用 Offset |
| `LockOnFOV` | 鎖定時的 FOV（有效範圍 1～179） |
| `LockOnOffsetZ` | 鎖定時的俯視高度。`0` = 遊戲預設（不套用） |
| `EnemyOffset` | 鎖定時的側向偏移。`120` = 預設；`-180` = 居中 |
| `EnableLog` | 是否寫入除錯 log。一般游玩請 `false` |

### 範例

只改 Lock-On 俯視與側向，不動 FOV：

```ini
FOVEnabled=false
LockOnFOV=120
LockOnOffsetZ=90
EnemyOffset=-180
EnableLog=false
```

FOV + Offset 全開：

```ini
FOVEnabled=true
LockOnFOV=120
LockOnOffsetZ=90
EnemyOffset=-180
EnableLog=false
```

請勿在同一行參數後加註解（例：`LockOnFOV=120 ;test`），可能導致數值解析失敗。註解請獨立一行，以分號開頭。

---

## 遊戲內主控台指令（前缀：`clo`）

開啟 UE4SS 主控台後（使用 `~` 要按兩次才能開啟 console），按下搖桿 **B** 或滑鼠點擊 console 視窗才能正常輸入命令，這不是 mod 的問題。

輸入 `clo ?` 可顯示簡短說明。

### Lock-On FOV

| 指令 | 說明 |
|------|------|
| `clo fov disable` | 關閉 Lock-On FOV |
| `clo fov enable` | 開啟 Lock-On FOV |
| `clo fov value 120` | 設定 `LockOnFOV`（1～179；鎖定中立即生效） |

### Lock-On Offset

| 指令 | 說明 |
|------|------|
| `clo offset -180` | 設定 `EnemyOffset`（鎖定中立即生效） |
| `clo pitch 90` | 設定 `LockOnOffsetZ`（`0` = 遊戲預設） |

### 狀態查詢

| 指令 | 說明 |
|------|------|
| `clo fovstatus` | 顯示目前參數與鎖定狀態（推薦） |
| `clo diagstatus` | 顯示除錯用運行狀態（CombatMode、stack 等） |
| `clo ver` | 顯示 Mod 版本 |

---

## 使用建議

- 若只想調視角、不要 FOV，將 `FOVEnabled` 設為 `false`。
- 調參數時建議：鎖定敵人 → 用 `clo offset` / `clo pitch` 微調 → 滿意後寫入 INI。
- `clo` 改的數值重開遊戲會消失；要永久保存請改 INI。
- log 檔（`EnableLog=true` 時）位於 `Scripts` 資料夾，檔名含 `LockOnFovChanger_v` 與日期時間。

---

## 疑難排解

**Mod 完全沒作用？**

- 確認已安裝 [UE4SS for Dawnwalker](https://www.nexusmods.com/thebloodofdawnwalker/mods/18?tab=files)
- 確認 `enabled.txt` 為 `1`
- 確認 `main.lua` 路徑正確
- 執行 `clo ver`；若無反應，查閱 `UE4SS.log`

**改了 INI 沒變化？**

- 必須完全關閉遊戲後重開

**FOV 沒變化？**

- 確認 `FOVEnabled=true`（或 `clo fov enable`）
- 需「鎖定敵人」才會套用 Lock-On FOV

**Offset 沒套用？**

- 需「鎖定敵人」時才會寫入相機

**需要協助除錯？**

- 將 `EnableLog` 改為 `true`，重現問題後提供 log 檔與 INI 內容

---

感謝使用 LockOnFovChanger

---

# English

# LockOnFovChanger

The Blood of Dawnwalker — Lock-On Camera Mod  
Author: lukazou (luka.zou@gmail.com)

---

## What Does This Mod Do?

This mod adjusts the camera while you are **Hard Locked** on an enemy. Main features:

### 1. Lock-On FOV (Field of View)

- Applies your configured FOV while locked; restores the game's original FOV when unlocked
- Normal gameplay is around 90; actual value depends on in-game settings
- Can be disabled in INI (`FOVEnabled=false`) to use only the Offset features below

### 2. LockOnOffsetZ (Pitch / Height)

- Applied while locked; restored when unlocked
- Higher values = more top-down view (camera looks down more)
- `0` = game default

### 3. EnemyOffset (Lateral Y Offset)

- Applied while locked; restored to game default `120` when unlocked
- `120` = game default (enemy offset to the right)
- `-180` = centered camera (enemy directly ahead)
- Any value can be used to fine-tune left/right view (e.g. `-30`, `60`)

---

## Prerequisites — UE4SS Required

This mod requires UE4SS. Install [UE4SS for Dawnwalker](https://www.nexusmods.com/thebloodofdawnwalker/mods/18?tab=files) first.

Follow the instructions on that mod page and confirm the game launches normally.

---

## Installation

1. Extract the mod and place the entire `LockOnFovChanger` folder at:

   ```
   <Game Directory>\Dawnwalker\Binaries\Win64\ue4ss\Mods\LockOnFovChanger\
   ```

   Example (Steam default path):

   ```
   D:\steam\steamapps\common\The Blood of Dawnwalker\
     Dawnwalker\Binaries\Win64\ue4ss\Mods\LockOnFovChanger\
   ```

2. Confirm the folder structure:

   ```
   LockOnFovChanger/
   ├── enabled.txt
   └── Scripts/
       ├── main.lua
       └── LockOnFovChanger.ini
   ```

3. `enabled.txt` should contain `1` (enables this mod).

4. Edit `Scripts\LockOnFovChanger.ini` (see below).

5. Fully restart the game after editing INI (changes load only on startup).

6. (Optional) In-game, open the UE4SS console and run `clo ver`. If a version number appears, the mod loaded successfully.

---

## INI Configuration (`LockOnFovChanger.ini`)

- Path: `Scripts\LockOnFovChanger.ini`
- Read once at game startup; restart after changes
- `clo` commands only change runtime memory; they are **not** saved back to INI

### Parameters

| Parameter | Description |
|-----------|-------------|
| `FOVEnabled` | Enable Lock-On FOV. `false` = no FOV change while locked; offsets still work |
| `LockOnFOV` | FOV while locked (valid range 1–179) |
| `LockOnOffsetZ` | Pitch / height while locked. `0` = game default (not applied) |
| `EnemyOffset` | Lateral offset while locked. `120` = default; `-180` = centered |
| `EnableLog` | Write debug log file. Use `false` for normal play |

### Examples

Offset only (no FOV change):

```ini
FOVEnabled=false
LockOnFOV=120
LockOnOffsetZ=90
EnemyOffset=-180
EnableLog=false
```

FOV + Offset enabled:

```ini
FOVEnabled=true
LockOnFOV=120
LockOnOffsetZ=90
EnemyOffset=-180
EnableLog=false
```

Do not add inline comments on the same line as a value (e.g. `LockOnFOV=120 ;test`) — parsing may fail. Put comments on their own line starting with `;`.

---

## In-Game Console Commands (prefix: `clo`)

After opening the UE4SS console (press `~` **twice**), press gamepad **B** or click the console window before typing — this is a UE4SS/input focus issue, not a mod bug.

Run `clo ?` for a short command list.

### Lock-On FOV

| Command | Description |
|---------|-------------|
| `clo fov disable` | Disable Lock-On FOV |
| `clo fov enable` | Enable Lock-On FOV |
| `clo fov value 120` | Set `LockOnFOV` (1–179; applies immediately while locked) |

### Lock-On Offset

| Command | Description |
|---------|-------------|
| `clo offset -180` | Set `EnemyOffset` (applies immediately while locked) |
| `clo pitch 90` | Set `LockOnOffsetZ` (`0` = game default) |

### Status

| Command | Description |
|---------|-------------|
| `clo fovstatus` | Current settings and lock state (recommended) |
| `clo diagstatus` | Debug runtime state (CombatMode, stack, etc.) |
| `clo ver` | Show mod version |

---

## Tips

- Set `FOVEnabled=false` if you only want angle/offset changes without FOV.
- To tune values: lock on → adjust with `clo offset` / `clo pitch` → save to INI when satisfied.
- `clo` changes are lost after restart; edit INI for permanent settings.
- Log files (`EnableLog=true`) are written under `Scripts`, with filenames containing `LockOnFovChanger_v` and a timestamp.

---

## Troubleshooting

**Mod does nothing at all?**

- Confirm [UE4SS for Dawnwalker](https://www.nexusmods.com/thebloodofdawnwalker/mods/18?tab=files) is installed
- Confirm `enabled.txt` is `1`
- Confirm `main.lua` is in the correct path
- Run `clo ver`; if no response, check `UE4SS.log`

**INI changes have no effect?**

- Fully quit and restart the game

**FOV does not change?**

- Confirm `FOVEnabled=true` (or run `clo fov enable`)
- You must **lock on an enemy** for Lock-On FOV to apply

**Offset not applied?**

- Offsets are written only while **locked on an enemy**

**Need help debugging?**

- Set `EnableLog=true`, reproduce the issue, then provide the log file and INI contents

---

Thank you for using LockOnFovChanger
