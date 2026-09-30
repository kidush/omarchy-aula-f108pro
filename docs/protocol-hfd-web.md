# Huafenda (HFD) keyboard HID protocol, as implemented by web tools

Status: extracted 2026-09-29 from public web code only. No local device was touched.

Legend used below:

- **[code]** read directly from source code (exact byte layout visible in JS).
- **[inferred]** my interpretation (naming, units, purpose), not proven by code or hardware.
- **[other-family]** belongs to the Sonix-based AULA F108 Pro (V1) protocol, not HFD.

## 1. Sources

| # | Source | What it is | Status |
|---|--------|------------|--------|
| S1 | `https://hub.epomaker.com/assets/index-CCms8C28.js` (2.5 MB, Vite bundle, not obfuscated) | Official Epomaker web hub. Contains the full **Huafenda WebHID SDK** (comments call it "华奋达SDK", key table says "based on Huafenda SDK v1.3.2"). | Primary source. Beautified snippets saved in `docs/protocol-sources/web/`. |
| S2 | `https://github.com/HoDPC/epomaker-th108-pro-local-hub` (`th108_pro_hub_local.html`, MIT) | Independent single-file WebHID tool for Epomaker TH108 Pro, wired and 2.4G dongle. | Read in full. Script saved as `hodpc-th108-pro-local-hub.script.js`. |
| S3 | `https://hub.aulacn.com/` | AULA web hub. Live site returns HTTP 403 to curl (with browser UA and Referer too). | Wayback snapshots `index-BmrMXJmj.js` (2026-03-25) and `index-Bo43os5L.js` (2026-04-17) fetched. Code is **obfuscated** (javascript-obfuscator string arrays), and the device table has **no 05ac:024f and no HFD entries** (VIDs 0x0C45, 0x1CA5, 0x372E; usage pages 0xFFA0/0xFFB0/0xFF60). Not useful for HFD. |
| S4 | `https://aulastar.com/web-drive/610.html` ("F108 PRO V2") | Page is empty and only links to "AULA HUB" (`hub.aulacn.com`). | No protocol content. |
| S5 | `github.com/parsiya/f108-pro` (Go), `sarequl/aula-studio` (Swift), `jiarong0423/aula-f108pro-lcd-tool-macos` (C), `Punkster81/AULA-F108-Driver` (Python), `ThePrimeDev/SignalRgb_AulaF108Pro` and `hcode10/Aula-F108Pro-SignalRGB` (SignalRGB JS), `AuRoN89/AULA-F108-PRO-Reverse-Engineering` | AULA F108 Pro (V1) projects. That keyboard is Sonix SN32F290 (wired 0C45:800A) but its **2.4G dongle is also 05AC:024F** ("F108Pro Dongle", MI_03). | Summarised in section 9 because it directly affects device identification. |

GitHub searches for "huafenda", "hub.epomaker.com", "TH108 linux", "TH80 Pro linux", opcode names (`SET_TFT_USER_ANIMATION`, `GET_24G_DISCONNECT_NOTIFY`) returned nothing beyond S2 and S5.

Saved snippets (`docs/protocol-sources/web/`, kept locally and not published because they are third-party code):

| File | Content |
|------|---------|
| `hfd-sdk-core.epomaker-hub.js` | S1 lines 79395-81086: framing (`E_`, `D_`, `O_`, `k_`), opcode table `P_`, every command encoder/decoder, SDK facade `Iv`. **Most important file.** |
| `hfd-tft-oled-adapters.epomaker-hub.js` | S1: TFT (`v_`) and dot-matrix OLED (`__`) adapters: RGB565 conversion, frame-delay table, clear, clock sync; `f_()` wired/2.4G switch. |
| `hfd-connection-and-models.epomaker-hub.js` | S1: connection strategy `Hv` (sleep/wake listeners, offline probe), HFD model registry, model configs (TH108 PRO screen 160x96). |
| `hfd-keymap-encoding.epomaker-hub.js` | S1: key-slot page types and the 4-byte key encoder `C_`, macro/combination builders. |
| `hfd-keytable.txt` | S1 key table `ig` (367 entries): name to 4-byte key slot. |
| `hfd-th108pro-matrix.txt` | S1 TH108 PRO layout: matrixIndex to key label and HID usage. |
| `hodpc-th108-pro-local-hub.script.js` | S2 script. |

Line numbers below ("S1:L79420") refer to the beautified bundle (`js-beautify -s 2`), reproduced by the saved snippet headers.

## 2. Transport

### 2.1 Devices and interfaces

| Item | Value | Ref |
|------|-------|-----|
| Epomaker TH108 PRO / TH108 / TH108 KR / TH87 | VID 0x05AC, PID 0x024F (591); TH87 ISO PID 0x0250 (592) | [code] S1:L81247-81340 |
| Wired config interface | usage page **0xFF68**, usage 0x61, 64-byte output/input reports, report ID 0 | [code] S1 registry `usagePage: 65384, usage: 97`; S2 `UP_WIRED` |
| 2.4G dongle config interface | usage page **0xFF60**, usage 0x61, **32-byte** output reports, report ID 0 | [code] S2 `UP_DONGLE` plus descriptor read (fallback 32); S1 `VALID_USAGE_PAGES` includes 65376 (0xFF60) |
| Wired bulk (screen/animation) interface | usage page **0xFF67** (65383), output report 4104 bytes (8 header + 4096 payload) | [code] S1 `A_(productId, 65383)`, fallback `reportCount || 4104` |
| All HFD usage pages the SDK accepts | 0xFF68, 0xFF80, 0xFF60, 0xFF00, 0xFF01, 0xFF1B | [code] S1 `Iv.VALID_USAGE_PAGES` |
| Other HFD 2.4G dongles | 0C45:FEFC is listed as "AULA F108ProV2 Dongle" (also "AULA NOVA98 Dongle", "2.4G Dongle"); 05AC:024F listed as "2.4G Dongle" / "2.4G Wireless Receiver" | [code] S1 `Iv.NEED_FULL_DEVICE_IDS` |

The report size is **never hard-coded** in the SDK: every command reads
`device.collections[0].outputReports[0].items[0].reportCount` (default 32) and
derives the chunk payload size from it (S1:L79413). S2 does the same from the
descriptor (64 wired, 32 dongle). So the same command stream works on both
the 32-byte and 64-byte interfaces; only the chunking differs.

Your dongle's second 0xFF60/0x61 collection (64-byte) matches the SDK's
`*_24G_64_BYTE` commands (0x3B, 0x3C), which default to `reportCount || 64`
(S1 `uv`, `gv`). The hub never calls them, so which physical interface they
target is **[inferred]**.

All traffic uses **output reports** (`sendReport(0, data)`) and **input reports**
(`inputreport` events). No feature reports are used by the HFD SDK. [code]

### 2.2 Host to device frame (`D_`, S1:L79470)

```
off  size  field
0    1     0xAA              magic
1    1     cmd               opcode (table in section 3)
2    1     len               payload bytes carried in THIS packet (<= reportSize-8)
3    2     addr (LE u16)     byte offset of this chunk inside the logical buffer
5    1     extra0            only set when a command passes `otherHeader[0]`, else 0
6    1     last              1 on the final chunk of a transfer, else 0
                             (overridden by otherHeader[1] when a command supplies it)
7    1     extra2            otherHeader[2] or 0
8..  n     payload           zero padded to reportSize
```
[code]. Some commands replace the 8-byte header with a custom header
(`customHeader`), documented per command.

Chunking (`E_`, S1:L79396): `chunk = reportSize - 8` (24 on the dongle,
56 on 64-byte wired). A logical buffer of `contentSize` bytes starting at
`addrStart` is split into `ceil(contentSize/chunk)` packets; packet *i* has
`addr = addrStart + i*chunk`, `len = min(chunk, remaining)`, and `last = 1` only
on the final one (unless `isNeedLastPacketFlag: false`). [code]

For **reads** the host sends the same framed requests (with zero payload), one
per chunk, and collects one reply per chunk. [code]

### 2.3 Device to host reply (`O_`, `k_`)

```
off  field
0    0x55
1    cmd  (echo of the request opcode, or the `responseCmd` override)
2    lenOrType
3-4  addr (LE u16)
5-7  (command specific, e.g. battery on 0x3B at byte 5)
8..  data
```
[code]. The reply is matched by `data[0]==0x55 && data[1]==cmd` and, when
`checkAddr` is set, `addr == requested addr`. **No status byte, no checksum** is
checked. [code]

### 2.4 Flow control, timing, retries

| Parameter | Value | Ref |
|-----------|-------|-----|
| Send model | Strict stop-and-wait: send one packet, wait for its 0x55 reply, then the next packet. | [code] `E_` |
| Default reply timeout | 500 ms per packet | [code] |
| Retries | 3 resends per packet on timeout, then reject | [code] |
| Longer timeouts | 2000 ms for 0x11/0x21 (game mode), 0x1D/0x2D (side light), 0x3D/0x2A (dot matrix), 0x25 (macro write), 0x50 (TFT), magnetic-axis ops | [code] |
| Fire-and-forget | Factory reset 0x0F (then sleep 100 ms), calibration off, simulation off, music frames (timeout 10 ms, 0 retries), 0x51 (timeout 50 ms, 0 retries) | [code] |
| Inter-command delay | None in the SDK beyond the ack wait. | [code] |
| Checksum | None in the generic frame. Only `setMusicDataV1` (0x35 single-packet form) sets `byte[31] = sum(byte[0..30]) & 0xFF`. | [code] |

### 2.5 Sleep, wake, disconnect (2.4G)

Unsolicited input reports from the dongle (S1 `B_`, `V_`, `H_`, `U_`, S2 push listener):

| Bytes | Meaning | Ref |
|-------|---------|-----|
| `55 FC 04` | 2.4G keyboard disconnected (dongle still present) | [code] S1 `B_` |
| `55 FC 05` | S1 registers it as a "reset" listener; S2 labels it "keyboard lost link with dongle" | [code] / meaning [inferred] |
| `55 FC 06` | Keyboard went to sleep | [code] |
| `A6 FF 01` | Keyboard woke up | [code] |
| `55 FA <type> ...` | Device state notification (`GET_DEVICE_NOTIFY`), callback gets raw frame | [code] |
| `55 FB kv st maxLE minLE curLE strokeLE maxStrokeLE` | Magnetic-axis calibration stream (not relevant to F108) | [code] |

Behaviour in the hub [code]:

- While asleep, commands are **silently dropped** by the dongle. The hub blocks every HFD call when `linkMode==2.4g && !online` (S1:L81201).
- A `GET_DEVICE_INFO` timeout over a receiver is treated as "keyboard asleep / not paired".
- Offline recovery: probe with `GET_DEVICE_INFO` every 3 s, backoff x1.5, capped at 30 s (S1 `Hv.startOfflineRecovery`).

## 3. Opcode table (`P_`, S1:L79511)

| Hex | Name | Used by hub | Section |
|-----|------|-------------|---------|
| 0x01 | COMMUNICATION_START | no (S2 uses it as a harmless probe) | 4.1 |
| 0x02 | COMMUNICATION_END | no | |
| 0x0F | SET_FACTORY_RESET | yes | 4.10 |
| 0x10 | GET_DEVICE_INFO | yes | 4.1 |
| 0x11 / 0x21 | GET / SET_GAME_MODE (sleep, debounce, polling, TFT display time) | yes | 4.2 |
| 0x12 / 0x22 | GET / SET_KEY (main layer, 128 slots) | yes | 4.5 |
| 0x16 / 0x26 | GET / SET_FN_KEY (Fn layer) | yes | 4.5 |
| 0x1C | GET_DEFAULT_FN_KEY_MATRIX | yes | 4.5 |
| 0x1F | GET_DEFAULT_KEY_MATRIX | no | |
| 0x13 / 0x23 | GET / SET_LED_EFFECT (main backlight) | yes | 4.7 |
| 0x14 / 0x24 | GET / SET_CUSTOM_LED_DATA (per-key colors) | yes | 4.7 |
| 0x15 / 0x25 | GET / SET_MACRO | yes | 4.6 |
| 0x17 / 0x27 | GET / SET_MAGNETIC_AXIS_RT | HE boards only | 4.11 |
| 0x18 / 0x28 | GET / SET_MAGNETIC_AXIS_DKS_DATA | HE only | 4.11 |
| 0x1B / 0x2B | GET / SET_LIGHT_BOX | yes | 4.8 |
| 0x1D / 0x2D | GET / SET_SIDE_LIGHT | yes | 4.8 |
| 0x2A / 0x3D | SET_DOT_MATRIX_MODE / GET_DOT_MATRIX_CONFIG | dot-matrix boards | 4.9 |
| 0x30 / 0x31 | SET_KEYBOARD_CUSTOM_FUNCTION_ON / OFF | no | |
| 0x32 | GET_LED_DATA (also reused as the cmd of a 64-byte music path) | music | 4.12 |
| 0x33 | GET_ALL_LIGHTS_RGB (wired) | yes | 4.7 |
| 0x34 | SET_TEMPORARY_COMMAND_DATA (clock sync, screen info) | yes | 4.3 |
| 0x35 | SET_MUSIC_DATA | music | 4.12 |
| 0x36 | CLEAR_LED_DATA | dot-matrix | 4.9 |
| 0x37 | GET_ALL_LIGHTS_RGB_24G (32-byte dongle) | defined, unused | 4.7 |
| 0x3B | GET_ALL_LIGHTS_RGB_24G_64_BYTE | defined, unused | 4.7 |
| 0x3C | SET_MUSIC_DATA_24G_64_BYTE | music | 4.12 |
| 0x40 | SET_LED_BOOT_ANIMATION | no | |
| 0x41 | SET_LED_USER_ANIMATION (dot-matrix; also the **ack cmd for TFT uploads**) | yes | 4.4, 4.9 |
| 0x42 | SET_LED_DATA (GIF lighting / sync animation) | yes | 4.9 |
| 0x4F | SET_FLASH_DOWNLOAD | no | |
| 0x50 | SET_TFT_USER_ANIMATION (screen image/GIF upload) | yes | 4.4 |
| 0x51 | SET_TFT_BUILT_IN_INDEX (select built-in screen page) | yes | 4.4 |
| 0x60 | GET_MAGNETIC_AXIS_KEY_STATUS | HE | |
| 0x64 / 0x65 | SET_CALIBRATION_ON / OFF | HE | 4.11 |
| 0x66 / 0x67 | SET_SIMULATION_TEST_ON / OFF | HE | |
| 0x68 | GET_MAGNETIC_AXIS_STATUS | HE | |
| 0x69 / 0x6A | SET_CALIBRATION_ON_V2 / OFF_V2 | HE | |
| 0xFA | GET_DEVICE_NOTIFY (push) | yes | 2.5 |
| 0xFB | GET_MAGNETIC_AXIS_CALIBRATION_DATA (push) | HE | 2.5 |
| 0xFC | GET_24G_DISCONNECT_NOTIFY (push, see 2.5) | yes | 2.5 |
| 0xFD | GET_TFT_STATE_NOTIFY | no | |

There is **no save / commit opcode**. Every SET is sent as a full buffer and
the hub never issues anything afterwards; persistence to flash is done by the
firmware. [code for absence; persistence itself is inferred]

## 4. Command layouts

"payload[i]" means byte `8+i` of the packet (or of the concatenated logical
buffer across chunks, at `addr = i`).

### 4.1 Handshake / device info: 0x10 GET_DEVICE_INFO (`I_`)

Request: `contentSize 56`. There is no mandatory handshake before it; the hub
calls it first after `open()` and uses `product` to pick the model. [code]

Reply payload (56 bytes, concatenated from chunks) [code]:

| off | field | notes |
|-----|-------|-------|
| 0-3 | ? | unused by hub |
| 4-5 | vid (LE) | |
| 6-7 | pid (LE) | |
| 8-9 | version | `((b8 & 0x0F) + (b8>>4)*10 + b9*100) / 100`, e.g. shown as "V1.14" |
| 10-11 | ? | |
| 12-13 | manufacturer (LE) | |
| 14-15 | product (LE) = "productNum" | TH108 PRO = 7, TH108 = 2, TH108 KR = 5, TH87 = 12, TH108 V2 PRO = 11, TH65 = 40 |
| 16 | workMode | 0 USB, 1 BT, 2 2.4G |
| 17 | batteryLevel | percent [inferred unit] |
| 18 | chargeStatus | |
| 19 | ? | |
| 20-21 | axisInfo | magnetic axis info |
| 22-23 | tftMaxFrames | |
| 24-25 | gifMaxFrames | |
| 26-27 | ledMaxFrames | |
| 28 | tftDirection | 0 normal, 1 rotated 90 |
| 29 | rtPrecision | |
| 30 | frameVersion | |
| 31 | lightingVersion | |
| 32 | firmwareStatus | |

Example, 32-byte dongle (3 request packets, all 32 bytes, zero padded):
```
AA 10 18 00 00 00 00 00  00 ... (24 x 00)
AA 10 18 18 00 00 00 00  00 ...
AA 10 08 30 00 00 01 00  00 ...
```
Example, 64-byte wired: `AA 10 38 00 00 00 01 00` + 56 x `00`. [code-derived]

S2 diagnostics probe: `AA 01 38 00 00 00 01 00 ...` (COMMUNICATION_START with
len 56, leftover LED bytes) and prints any reply. [code]

### 4.2 Game mode / sleep: 0x11 GET, 0x21 SET (`L_`, `R_`)

56-byte buffer, timeout 2000 ms. [code]

| off | field |
|-----|-------|
| 3 | sleepTime (unit not in code) |
| 4 | keyDelay (debounce) |
| 5 | reportRate (0..6) |
| 7 | tftDisplayTime |
| 8 | topDeadZone x100 |
| 9 | bottomDeadZone x100 |
| 11 | stabilityMode (0/1) |
| 14 | autoCalibration (0/1) |

The hub always does read-modify-write (GET, patch fields, SET). Other bytes are
sent as 0 by `R_`, so a naive SET zeroes unknown bytes. [code] For TH108 PRO,
`supportSleepTime` is false in the hub. [code]

### 4.3 Clock sync and screen info: 0x34 SET_TEMPORARY_COMMAND_DATA

`contentSize` defaults to 24 (one chunk on both report sizes). [code]

TFT clock (`Nv`, used by the TFT adapter `syncClock`):
```
payload: 5A 01 5A YY MM DD hh mm ss WD  (then zeros to 24)
YY = year % 100, MM 1-12, WD = JS getDay() (0 = Sunday .. 6)
```
Example, 2026-09-29 12:34:56 Tuesday, 32-byte report:
```
AA 34 18 00 00 00 01 00  5A 01 5A 1A 09 1D 0C 22 38 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```
Dot-matrix LED clock (`bv`) is identical except payload[0] = `3A`. [code]

TFT screen info (`Pv`, weather/CPU widgets), 24-byte payload, no retries:
```
[6]=5A  [12]=cpuUsage 0-100  [13]=cpuTemp (s8)  [14]=gpuUsage  [15]=gpuTemp (s8)
[16]=currentTemp (s8)  [17]=maxTemp  [18]=minTemp  [19]=weather 0-23  [20]=humidity 0-100
```
The hub only sends `currentTemp` and `weather`. [code]

### 4.4 Screen (TFT) image / GIF upload: 0x50 SET_TFT_USER_ANIMATION (`jv`, adapter `v_`)

Model config for TH108 PRO / TH108 V2 PRO (`Ng`): **160 x 96**, 1 layer,
max 250 frames, default delay 50 ms, delay range 1-255, direction 0. [code]

Pixel format [code] (`convertToRGB565Normal`):
- Input RGB888 (3 bytes/pixel), rows top to bottom, left to right.
- `v = round(r/255*31)<<11 | round(g/255*63)<<5 | round(b/255*31)`.
- Written **little-endian**: low byte first. 2 bytes/pixel, 160*96*2 = 30720 bytes/frame.
- `tftDirection == 1` uses a column-major walk instead (rotated 90).

Logical buffer = 256-byte delay table + frames [code]:
```
table[0]            = N (frame count, <= 255)
table[1 .. N-1]     = delay[i] * 5  for i = 0 .. N-2
table[N]            = 0
table[N+1 .. 255]   = 0xFF
then N frames of RGB565 LE
```
Where the adapter builds `delay[]` in 10 ms units (`round(ms/10)`), so the byte
written is `ms/2` [code for math, unit meaning inferred]. The adapter also
**prepends a copy of frame 0** (N = frames + 1) and rotates the delay list
(`delay[k]` belongs to frame `(k+1) % frames`, then frame 0's delay is unshifted).
This looks like "cover frame + loop" behaviour. [code; purpose inferred]

Clear screen = one all-black frame with delay list `[6]` (table `01 00 FF FF...`). [code]

Packetisation (custom 8-byte header, payload from byte 8):
```
0  AA
1  50
2  chunkIndex low      (LE u16)
3  chunkIndex high
4  chunkTotal low      (LE u16)
5  chunkTotal high
6  50                  (constant, meaning unknown)
7  06                  (constant, meaning unknown)
8.. chunk payload (reportSize - 8 bytes, last chunk zero padded)
```
- Reply awaited: `55 41 ...` (cmd **0x41**, not 0x50; `responseCmd: SET_LED_USER_ANIMATION`), timeout 2000 ms, 3 retries, one ack per chunk. [code]
- **Wired**: sent on the separate **0xFF67** bulk interface, 4104-byte reports, 4096 payload bytes per chunk. One 160x96 frame + table = 30976 bytes = 8 chunks. [code]
- **2.4G dongle**: `f_()` returns false, so it goes out on the normal config interface (collection[0] of the opened device), `reportSize - 8` bytes per chunk: 24 bytes on the 32-byte interface = **1291 packets per single frame**, each acked. [code]. Real-world speed over 2.4G is untested [gap].

Built-in screen page: **0x51 SET_TFT_BUILT_IN_INDEX**, payload `[index]`, len 1,
timeout 50 ms, no retries, bulk interface when wired. [code]

### 4.5 Keymap and knob: 0x12/0x22 (main), 0x16/0x26 (Fn), 0x1C (default Fn)

Buffer: **512 bytes = 128 slots x 4 bytes**, slot index = `matrixIndex` of the
layout (see `hfd-th108pro-matrix.txt`). SET always writes the whole 512 bytes.
On a 32-byte report that is 22 packets (21 x 24 + 8); on 64-byte, 10 packets. [code]

Slot encoding (`C_`, key table `hfd-keytable.txt`) [code]:

| byte0 (page) | bytes 1-3 | example |
|--------------|-----------|---------|
| 0x00 DEFAULT | 00 00 00 = factory default for that position | |
| 0x01 MOUSE | [1]=sub (1 buttons, 3 wheel), [2]=value | Left `01 01 01 00`, Right `01 01 02 00`, Middle `01 01 04 00`, Back `01 01 08 00`, Fwd `01 01 10 00`, Wheel up `01 03 01 00`, down `01 03 FF 00` |
| 0x02 KEYBOARD | [1]=modifier mask [inferred], [2]=HID usage | A `02 00 04 00`, Fn `02 00 AF 00`, "disabled" `02 00 6B 00` |
| 0x03 CONSUMER | [1..2]=consumer usage LE | Vol+ `03 E9 00 00`, Vol- `03 EA 00 00`, Mute `03 E2 00 00`, Calc `03 92 01 00` |
| 0x04 SYSTEM, 0x05 EXTRA_FUNCTION | | defined only |
| 0x06 MACRO | [1]=macroId, [2]=play type, [3]=loop count | play type: 0 once, 1 fixed count, 2 press-again-to-stop, 3 release-to-stop, 4 click-to-play |
| 0x07 CB, 0x08 DKS, 0x09 MT, 0x0A TGL, 0x0B SOCD, 0x0C RS | advanced keys | |
| 0x0D FUNC | [1..3] = 24-bit function id (BE) | `0D 00 00 2E` Knob Mode, `0D 00 00 01` Restore Factory, full list in key table |
| 0x80-0xFF FUNC_V2 | `0x80 | hi7(a)`, lo(a), hi(b), lo(b) | two 15/16-bit ids |
| 0x0E END | | |

Knob: TH108 V2 PRO layout (`tg`) maps the knob to **slots 13 (CW), 14 (CCW),
15 (press)** of the same 128-slot tables, default Vol+ / Vol- / Mute. The hub's
`__hfdProbeKnob` notes the location is still being verified against the
official driver. [code; F108 slot numbers are a gap]

Read: `GET_KEY` returns the same 512-byte layout. [code]

### 4.6 Macros: 0x15 GET_MACRO, 0x25 SET_MACRO (`Tv`, `Ev`)

Logical memory, addressed with the frame `addr` field [code]:
```
0..399   100 x u32 LE: absolute offset of macro i's record (0 = empty)
400..    records, packed back to back
record:  u16 LE (actionCount * 2), 00 00, then actionCount x 4 bytes:
         [0-1] delay ms (LE u16) [2] keycode [3] flags
flags:   bit7 = press(1)/release(0); bits 6-4 = action type
         keyboard (type 1/2): press 0x90, release 0x10
         mouse    (other):    press 0xB0, release 0x30
```
Write sequence: one transfer of the 400-byte index at addr 0 **without** the
last flag, then one transfer of all records at addr 400 **with** the last flag,
timeout 2000 ms. [code] Pool limit for TH108 V2 PRO: 624 bytes; hub limits 20
macros, 511 actions each. [code] Read: index (400 bytes), then 4 bytes at each
offset, then `count/2 * 4` bytes at offset+4. [code]

Example first packet (32-byte report):
`AA 25 18 00 00 00 00 00` + 24 bytes of index. [code-derived]

### 4.7 Main backlight RGB

**0x23 SET_LED_EFFECT / 0x13 GET** (`ov`, `av`), 16-byte payload [code]:
```
[0] mode        0 = off, 1..19 effects, 0x80 = custom per-key
[1-3] R G B
[4] 0xFF (fixed on write)
[5-7] secondary R G B
[8] colorMode   0 = single color, 1 = vibrant/rainbow
[9] brightness  (hub 1-5; S2 allows 0-5)
[10] speed      1-5
[11] direction  option value (effect specific, see below)
[12] effectModeType
[13] 00
[14-15] AA 55   trailer
```
Effects [code]: 1 Static, 2 Single Light Up, 3 Single Light Off, 4 Starlight,
5 Snowfall, 6 Flower Bloom, 7 Breathing, 8 Spectrum Cycle, 9 Colorful Spring,
10 Colorful Cross (dir 2 down-up, 3 up-down), 11 Waveflow (0 L-R, 1 R-L),
12 Mountain Path (0/1), 13 One Touch, 14 One Stone Two Birds, 15 Ripple,
16 Stream (0/1), 17 Layered Mountains, 18 Gentle Wind (0/1), 19 Shuttle, 128 Custom.

Example (static red, brightness 5, speed 3), 32-byte dongle, identical in S1 and S2:
```
AA 23 10 00 00 00 01 00  01 FF 00 00 FF 00 00 00  00 05 03 00 00 00 AA 55  00 00 00 00 00 00 00 00
```
On/off in the hub = GET, set mode 0 (remember previous), SET. [code]

**0x24 SET_CUSTOM_LED_DATA / 0x14 GET** (`dv`, `sv`): 512 bytes =
128 x `[ledIndex, R, G, B]`. The hub then sends SET_LED_EFFECT with mode 0x80,
colorMode 1, brightness 3, speed 0. [code]

**0x33 GET_ALL_LIGHTS_RGB** (live colors, wired): host sends 512 bytes
`[i,0,0,0]` for i = 0..127, reply 128 x `[i,R,G,B]`. [code]

**0x37 GET_ALL_LIGHTS_RGB_24G** (32-byte dongle): custom 4-byte header
`AA 37 <pktIndex> 00`, data from byte 4, reply colors RGB565 **big-endian**
2 bytes/LED, battery at reply byte 3. **0x3B** (64-byte dongle): normal header,
payload = LED ids (u16 LE each), reply RGB565 BE, battery at reply byte 5.
Both unused by the hub. [code]

### 4.8 Light box (0x1B/0x2B) and side light (0x1D/0x2D)

24-byte payload [code]: `[0] mode, [1-3] RGB, [8] colorMode, [9] brightness, [10] speed`.
Side light uses a 2000 ms timeout. Side-light effect list (`og`): 1 Streamer,
2 Static, 3 Breathing, 4 Spectrum, 5 Off, 6 Dynamic, 7 Chain Reaction. [code]
The hub has a write-then-read-back probe because firmware support varies. [code]

### 4.9 Dot-matrix LED screen (not TFT; for completeness)

- 0x2A SET_DOT_MATRIX_MODE / 0x3D GET: 9 bytes `bgRGB, textRGB, type, mode, dotMatrixMode(1..3)`.
- 0x36 CLEAR_LED_DATA: empty payload.
- 0x41 SET_LED_USER_ANIMATION: data `[frames LE16, (101-speed) LE16, RGB...]`, custom header `AA 41 idxHi idxLo totHi tot+1 00 00` (BE, note the odd `+1`), bulk interface.
- 0x42 SET_LED_DATA: same framing for GIF lighting. [code]

### 4.10 Factory reset: 0x0F

Single packet `AA 0F <mode> 00 00 00 00 00`, mode 0xFF = reset all, 0x05 =
clear calibration. Not acked; hub waits 100 ms. [code]

### 4.11 Magnetic axis (HE boards only)

0x17/0x27 RT: 1024 bytes = 128 x 8 `[axisType, flags(b0 wholeFast, b1 rampage), trigger LE16, pressRT LE16, releaseRT LE16]`.
0x18/0x28 DKS: 1024 bytes = 64 x 16. Calibration 0x64/0x65, 0x69/0x6A (custom
header `AA 69 00...`). Not relevant to a non-HE F108. [code]

### 4.12 Music / audio visualiser (0x35, 0x3C, 0x32)

Three variants in `gv` / `_v` (RGB565 BE streaming, custom header
`AA 35 pkt profile`, or 64-byte `0x3C` with addr; `_v` single packet with checksum
at byte 31). Low priority. [code]

## 5. Wired vs dongle summary

| Aspect | Wired | 2.4G dongle |
|--------|-------|-------------|
| Config usage page | 0xFF68 / 0x61 | 0xFF60 / 0x61 |
| Report size | 64 (chunk 56) | 32 (chunk 24); a 64-byte 0xFF60 collection also exists (used by the `_64_BYTE` opcodes) |
| Screen upload | separate 0xFF67 interface, 4096-byte chunks | same config interface, 24-byte chunks |
| Push events | none documented | `55 FC 04/05/06`, `A6 FF 01` |
| Offline handling | n/a | commands dropped while asleep; probe with 0x10 |
| Protocol bytes | identical | identical |

## 6. Minimal Go driver sequence (derived)

1. Open the hidraw node whose report descriptor has usage page 0xFF60 usage 0x61 and 32-byte output report (dongle) or 0xFF68/0x61 (wired). Read report size from the descriptor. [code-derived]
2. Start a reader goroutine; route `55 xx` replies by opcode (and addr) and handle `55 FC 0x` / `A6 FF 01` pushes. [code-derived]
3. `GET_DEVICE_INFO` (0x10). Timeout on dongle = keyboard asleep. Check `product`, `workMode`, `tftMaxFrames`, `tftDirection`. [code-derived]
4. Writes: build the logical buffer, chunk with `addr` and `last`, send one packet, wait for `55 <cmd>` (500 ms, 3 retries). [code-derived]
5. Clock: 0x34 with `5A 01 5A YY MM DD hh mm ss WD`. [code]
6. Screen: 0x50 with the 256-byte table + RGB565 LE frames, acks with cmd 0x41. [code]

hidraw note [inferred]: with no report ID, write exactly `reportSize` bytes
prefixed by a `0x00` report-ID byte if using hidapi; on raw `/dev/hidrawN`
write the 32 bytes directly (Linux hidraw expects the report ID only when the
descriptor declares one).

## 7. Confidence

- Framing, opcodes, chunking, reply matching, all layouts above: **high** (read from a non-obfuscated production SDK and cross-checked on 0x23 against the independent S2 implementation, byte for byte).
- That your "Alma F108 Pro" speaks this protocol: **medium-high**. Your dongle (05AC:024F, 0xFF60/0x61, 32-byte, no report ID) matches S2's TH108 PRO dongle exactly. See section 9 for the competing Sonix hypothesis.
- Screen resolution for your unit: **unknown**. HFD TH108 PRO is 160x96; Sonix F108 Pro V1 is 240x135. Read `GET_DEVICE_INFO` and the Windows driver config to confirm.

## 8. Gaps

- Sleep-time units, meaning of info bytes 0-3/10-11/19, TFT header bytes 6-7 (`50 06`).
- Whether 2.4G screen uploads are practical (1291 acked packets per frame).
- Which dongle interface (32 vs 64 byte) is `collections[0]` in WebHID; the SDK always uses the opened device's first collection.
- Knob slots for the F108 (hub still probing on TH108 V2 PRO).
- No explicit save opcode; flash-commit timing is unknown.
- `55 FC 05` semantics disagree between S1 ("reset") and S2 ("lost link").
- AULA's own hub is obfuscated and contains no 05AC:024F entry, so no AULA-side confirmation.

## 9. Competing hypothesis: Sonix-based AULA F108 Pro (V1) [other-family]

From S5 (parsiya/f108-pro `ai-docs/device-info.md` quoting the vendor `config.xml`; aula-studio `KeyboardProfile.swift`):

- Wired 0C45:800A (Sonix SN32F290, board "HFD80CP100"), 2.4G dongle **05AC:024F** "F108Pro Dongle", `MI_03`.
- Wired config: 64-byte **feature** reports on usage page 0xFF13, multi-step `04 18` begin / `04 xx` data / `04 02` apply / `04 F0` finalize, each read back. LCD: 240x135 RGB565, 256-byte header (count + per-frame delay in 20 ms units), 4096-byte output reports on 0xFF68, 141-frame limit (overflow corrupts menu graphics, no bounds check).
- 2.4G: single packet `05 10 00 mode R G B 00 00 00 00 colorful bright speed dir 00 00 55 AA`, macros in 28-byte chunks with subcommand `09`, LCD header `7F 03`.
- SignalRGB script for 05AC:024F validates `interface 3|4, usage_page 0xFF60, usage 0x0001` and sends 65-byte `04 20` / `04 02` feature reports.

Discriminator: your dongle reports **usage 0x61** with a 32-byte output report,
which matches the HFD TH108 PRO dongle (S2) and not the SignalRGB F108 V1
dongle descriptor (usage 0x0001, 64-byte feature). A read-only `GET_DEVICE_INFO`
(`AA 10 18 00 00 00 00 00` ...) answered with `55 10` would confirm HFD; this
was not run per instructions.
