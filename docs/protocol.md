# Alma F108 Pro: protocol recovered from the official AULA F108Pro Windows driver

Status: static analysis only, 2026-09-29. No local USB/HID device was touched and no
Windows binary was executed.

Legend:

- **[code]** read directly from the decompiled driver (function address given).
- **[inferred]** my interpretation (names, units, purpose). Not proven by code or hardware.
- **[prior-hw]** not re-derived here, but verified on real hardware by parsiya/f108-pro
  (wired Sonix keyboard only).

Companion document: `docs/protocol-hfd-web.md` (Huafenda web SDK, `AA .. AA 55` framing).
That is a **different** protocol that also lives on 05AC:024F. See section 9.

## 1. Source software

| Item | Value |
|------|-------|
| Alma download | None found. Alma (BR) publishes no driver; searches only return AULA pages. |
| Package used | `AULA F108Pro Driver.exe`, 10,763,304 bytes, from `https://www.aulastar.com/drive/list_28_4/` ("F108Pro", aid=561). Inno Setup 6.1, unpacked with innoextract 1.9. |
| Main binary | `app/DeviceDriver.exe`, PE32 i386, native MFC C++ with a `mui.dll` UI library and embedded SQLite. Version string "Beta 1.0.0.2", copyright 东莞市索艾电子科技有限公司. |
| Decompiler | Ghidra 12.1.4 headless, full auto-analysis, all functions decompiled. |
| Also downloaded, not analysed | `F108PRO firmware.exe` (2.2 MB, Sonix ISP updater). "F108 PRO V2" has no Windows driver on aulastar (web hub only). |

**The installed `config.xml` names your exact dongle** (`docs/protocol-sources/config.xml`):

```xml
<mode value="0" desc="USB"         vid="0C45" pid="800A" product_name="AULA F108Pro"  hid_interface="VID_0C45&PID_800A&MI_00"/>
<mode value="2" desc="2.4G TYPE-A" vid="05AC" pid="024F" product_name="F108Pro Dongle" hid_interface="VID_05AC&PID_024F&MI_03"/>
```

So this driver was written for the same 05AC:024F "F108Pro Dongle", interface 3. Function
addresses match parsiya's notes, so this is the same build they reversed. Their work covers
the wired path; **the 2.4G path below is new** (their doc calls it "partial" and misses the
checksum and the reply check).

Key facts from `layouts/rgb-keyboard.xml` [code]:

```xml
<menu          macro="1" light_mode="1" sidelight="0" user_light="1" custom_light="1" music="1" screen="1" />
<menu_wireless macro="1" light_mode="1" sidelight="0" user_light="1"                  music="1" screen="0" />
<function fn_layer="1" sleep_time="1" key_respondtime="1" />
<firmware version="120" />
<cmd_delaytime value="35" />
<screen gif_headlength="256" gif_maxframes="141" gif_count="1" width="240" height="135" />
<light default_mode="11" default_brightness="5" default_speed="3" brightness_max="5" speed_max="5" />
```

`menu_wireless screen="0"`: the official app hides the screen (image upload) page when on
the dongle, even though a 2.4G LCD upload routine exists in the binary (section 5.9).

## 2. Device discovery and interface selection

`FUN_0044f960` enumerates HID interfaces, opens each (`FUN_00450f70`, `CreateFileA` +
`HidP_GetCaps`) and classifies it **only by report lengths** (Windows lengths include the
report-ID byte) [code]:

| Condition (HIDP_CAPS) | Role | Stored at |
|-----------------------|------|-----------|
| FeatureReportByteLength == 0x41 | Wired config channel (64-byte feature reports) | device list, type 0/1 |
| OutputReportByteLength == 0x21 **and** InputReportByteLength == 0x21 | **2.4G dongle channel (32-byte out + 32-byte in, report ID 0)** | device list, type 2 |
| usage page 0xFFFF, usage 0x0001 | Notification channel (read only) | `dev+0x28` |
| OutputReportByteLength == 0x1001 | Wired LCD bulk channel (4096-byte output) | `dev+0x2c` |

Your dongle's iface 3 (0xFF60/0x61, 32-byte in/out, no report ID) matches the type-2 rule
exactly. The 64-byte 0xFF60 collection on iface 4 would match none of the rules and is never
used by this driver [code].

After opening a type-2 handle the driver immediately sends the probe in 5.1 (`FUN_0044f680`)
and stores the result as the "keyboard online behind dongle" flag.

**Firmware version** is not a HID command: `FUN_0044f850` returns `HIDD_ATTRIBUTES.VersionNumber`
(bcdDevice), the app formats it with `"%x"` and `_wtoi`s it, then compares with
`<firmware version="120">` (`FUN_00415200`, firmware-update check) [code].
So bcdDevice 0x0120 means firmware "120".

## 3. 2.4G transport (dongle, `FUN_0044f4e0`)

All 2.4G commands go through one routine [code]:

1. Caller builds a 0x41-byte zeroed buffer `buf`, `buf[0]` = report ID 0, payload from `buf[1]`.
2. **Checksum:** `buf[32] = (sum of buf[0..len-1]) & 0xFF` (callers pass len 0x41 or 0x21;
   bytes past the payload are zero). In payload terms:
   `payload[31] = sum(payload[0..30]) & 0xFF`.
3. `WriteFile(handle, buf, 0x21)` (report ID + 32 bytes; `FUN_00451110` pads to
   OutputReportByteLength). On failure: `Sleep(10)` and one retry.
4. `Sleep(5)`.
5. Up to 20 times: `ReadFile` with 5 ms timeout (`FUN_004511f0`, which strips a leading 0x00
   report-ID byte). Accept when `reply[0..2] == payload[0..2]` (echo of cmd, byte1, byte2).
   Otherwise `Sleep(10)` and read again. On accept, the reply is copied back over the caller's
   buffer (callers then read reply fields, e.g. battery).

There is **no** `AA 55` frame header on the dongle path, no begin/apply/finalize
transaction, and no separate save command: every packet is self-contained [code].

### 3.1 Packet shape (32-byte output report, no report ID on the wire)

```
off  0    : cmd
off  1    : len / sub   (number of data bytes for chunked writes; 0x10 for 16-byte blocks) [inferred name]
off  2    : index / offset (chunk index for chunked writes, else 0)
off  3..30: data (max 28 bytes)
off 31    : checksum = sum(off 0..30) & 0xFF
```

A consistent pattern [code, by side-by-side comparison with the wired senders]: for every
setting, the 2.4G `data` field (offset 3..) carries **byte-for-byte the same data block**
that the wired path sends after its `04 xx` init packet. Examples: lighting (`05 10` vs
`04 13` data), clock (`0C 10` vs `04 28` data), function settings (`07 10` vs `04 17` data).
So the wired layouts in parsiya's notes transfer directly by shifting 3 bytes.

### 3.2 Timing [code]

| Where | Delay |
|-------|-------|
| After each write, before first read | 5 ms |
| Between read retries (max 20) | 10 ms |
| Between chunks of multi-packet transfers | `Sleep(2)` after each acknowledged packet |
| After a factory-reset `0F`, before resending lighting | 50 ms |
| Battery poll | every 15 s (forced on connect) |
| Notification poll (`dev+0x28`) | every 200 ms, 10 ms read timeout |

Wired path instead sleeps `cmd_delaytime` = 35 ms before every feature report.

## 4. 2.4G command table

All offsets are payload offsets (32-byte report). "Sender" is the function in
`docs/protocol-sources/dongle_24g.c`.

| cmd | b1 | b2 | Purpose | Sender | Notes |
|-----|----|----|---------|--------|-------|
| `02` | 00 | 00 | Probe / "keyboard online?" | `FUN_0044f680` | Sent on open. Accept if reply[0]==02 and echo. |
| `20` | 01 | 00 | Get battery | `FUN_004357d0` | reply[3] = battery % (clamped to 100) |
| `07` | 10 | 00 | Function settings | `FUN_004144a0` | task 0xC |
| `05` | 10 | 00 | Main backlight mode/color | `FUN_0042b1e0` | task 9; also used with mode 0x80 as per-key header |
| `05` | 01 | 00 | Sidelight mode | `FUN_00434900` | task 10; sidelight is disabled on F108 Pro |
| `0C` | 10 | 00 | Clock sync | `FUN_00423c40` | on connect and task 0x13 |
| `03` / `0D` | 04 | key_index | Remap one key, normal / FN layer | `FUN_004191c0` | task 7 |
| `10` / `12` | 1C | chunk | Full key table, normal / FN layer (576 B, 21 chunks) | `FUN_00418e80` | task 6 |
| `14` | 1C | chunk | Per-key color table (576 B RGB or 192 B mono) | `FUN_0044bd80` | preceded by `05 10` mode 0x80 |
| `09` | 1C | chunk | Macro table | `FUN_0042dbb0` | task 8 |
| `0B` | 1C | 00 | Music / audio-reactive frame | `FUN_00432b60` | streaming, task mode 7 |
| `7F` | 03 | 00 | LCD upload header | `FUN_004233f0` | task 0x10; hidden in wireless UI |
| `80..FF` | idx lo | idx mid | LCD upload data chunk | `FUN_004233f0` | cmd = 0x80 \| idx bits 16..22 |
| `1F` | 00 | 00 | Reset key mapping ("Reset Keyboard") | `FUN_00434230` task 0xD | queued by `FUN_00414690` |
| `0F` | 00 | 00 | Factory reset | `FUN_00434ee0` task 0xE | then the app re-sends lighting |

The "len" byte is 0x10 for 16-byte settings blocks and the real byte count for chunks. Two
cases break the pattern (`05 01` carries 1 byte in a 16-byte block; `7F 03` carries 4 bytes).
So byte 1 may be a sub-command in some cases [inferred].

## 5. 2.4G commands in detail

Example packets are complete 32-byte payloads with the checksum computed by the rule in
section 3. They were generated by script from the code layout, **not captured**.

### 5.1 Probe `02` [code: FUN_0044f680]

```
TX 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02
RX 02 00 00 ..   (only bytes 0..2 are checked)
```

The result is stored as the online flag of the type-2 device. Treat it as the handshake.

### 5.2 Battery `20 01` [code: FUN_004357d0]

```
TX 20 01 00 00 ... 00 21
RX 20 01 00 <pct> ...     pct = battery percent, UI clamps to 100
```

Called every 15 s while in 2.4G mode and on connect (`FUN_00434700`).

### 5.3 Clock sync `0C 10` [code: FUN_00423c40]

| off | value |
|-----|-------|
| 0-2 | `0C 10 00` |
| 3 | 0x00 |
| 4 | slot = LCD list selection + 1 (normally 1) |
| 5 | 0x5A (magic) |
| 6 | year % 2000 |
| 7 | month 1-12 |
| 8 | day 1-31 |
| 9 | hour 0-23 |
| 10 | minute |
| 11 | second |
| 12 | 0x00 |
| 13 | day of week (`SYSTEMTIME.wDayOfWeek`, 0 = Sunday) |
| 14-16 | 0x00 |
| 17-18 | `AA 55` |
| 31 | checksum |

Example, 2026-09-29 14:30:05 Tuesday:

```
0C 10 00 00 01 5A 1A 09 1D 0E 1E 05 00 02 00 00 00 AA 55 00 00 00 00 00 00 00 00 00 00 00 00 E9
```

Sent on connect when the wired menu has `screen` (`FUN_00434750`) and from the "sync time"
task 0x13 (`FUN_00434ec0`). Offsets 3..18 are the same bytes as the wired `04 28` data packet.

### 5.4 Main backlight `05 10` [code: FUN_0042b1e0]

| off | field | source |
|-----|-------|--------|
| 3 | mode (0 = off, 1..19 effects, see below) | `t_light_data.mode` |
| 4, 5, 6 | R, G, B | `color_value` bytes 0, 1, 2 |
| 7-10 | 0 | |
| 11 | colorful (0 single color, 1 rainbow) | `t_light_data` +0x1c |
| 12 | brightness 0-5 | +0x10 |
| 13 | speed 0-5 | +0x14 |
| 14 | direction | +0x18 |
| 15-16 | 0 | |
| 17-18 | `AA 55` | |

When mode == 0, offsets 4..14 are left zero [code]. Field names for 11..14 come from the SQLite
column order (`mode, brightness, speed, direction, colorful, ...`) matched to the struct offsets
[inferred, consistent with parsiya's hardware tests of the wired `04 13` block].

Mode ids (from `language/1033.lan` + parsiya, default 11): 1 Static, 2 SingleOn, 3 SingleOff,
4 Glittering, 5 Falling, 6 Colourful, 7 Breath, 8 Spectrum, 9 Outward, 10 Scrolling, 11 Rolling,
12 Rotating, 13 Explode, 14 Launch, 15 Ripples, 16 Flowing, 17 Pulsating, 18 Tilt, 19 Shuttle;
0x80 = user-defined per-key (5.7).

Example, static red, brightness 5, speed 3:

```
05 10 00 01 FF 00 00 00 00 00 00 00 05 03 00 00 00 AA 55 00 00 00 00 00 00 00 00 00 00 00 00 1C
```

### 5.5 Function settings `07 10` [code: FUN_004144a0]

| off | field |
|-----|-------|
| 3 | 0x00 |
| 4 | 0x01 |
| 5 | Disable Alt+Tab checkbox (`this+0x678`) |
| 6 | Disable Alt+F4 checkbox (`this+0x67c`) |
| 7 | Disable Windows key checkbox (`this+0x680`) |
| 8 | `fn_switch` (DB setting) |
| 9 | `sleep_time` (DB setting, UI index) |
| 10 | 0 |
| 11 | `key_respondtime` (DB setting, UI index) |
| 17-18 | `AA 55` |

Checkbox-to-label mapping is [inferred] from the UI build order in `FUN_0043b420` (strings 160
"Disable Windows Key", 161 "Disable ALT + F4", 162 "Disable ALT + TAB" assigned to `+0x680`,
`+0x67c`, `+0x678`). Units of sleep time / response time are not in the code (combo indices).

### 5.6 Key remapping [code: FUN_004191c0, FUN_00418e80, FUN_00418230]

Key slots are 4 bytes, indexed by `key_index` from `rgb-keyboard.xml` (slot offset =
key_index * 4 in a 576-byte table, last 2 bytes of the table = `AA 55`).

Slot encodings built by `FUN_00418230` [code]:

| UI type | Slot bytes | Meaning |
|---------|-----------|---------|
| default | `02 00 <hid> 00` | plain key (single-key sender fills this first) |
| 1 | `05 03 00 00` | disable key [inferred] |
| 2 (key / combo) | `02 <mod-bits> <hid> 00`; modifier-only keys 0xE0-0xE7 become `02 <bit> 00 00` | keyboard |
| 3 (macro) | `06 <macro list position> <p2> <p3>` | run macro, p2/p3 = play mode/count [inferred] |
| 5 (mouse) | `01 01 01`, `01 01 04`, `01 01 02`, `01 01 03`, `01 03 01`, `01 03 FF`, `01 01 08`, `01 01 10` for sub-ids 1..8 | mouse buttons / wheel up/down [inferred; parsiya reads these as lock keys] |
| 6 (media) | `03 CD`, `03 B7`, `03 B6`, `03 B5`, `03 E9`, `03 EA`, `03 E2` | consumer usage low byte: play, stop, prev, next, vol+, vol-, mute |
| 7 (shortcut) | `02 08 07` Win+D, `02 08 08` Win+E, `02 08 0F` Win+L, `02 01 1A`, `02 04 2B` Alt+Tab, `02 01 06` Ctrl+C, `02 01 19` Ctrl+V, `02 01 1B` Ctrl+X, `02 01`, `02 02` | |
| 8-11 | `05 02 <v>` | app-side functions [inferred] |
| 12 | `03 <lo> <hi>` | 16-bit consumer usage |
| 13 | `07 <a> <b> <c>` | raw passthrough |

**Single key** (`FUN_004191c0`, task 7):

```
off 0   : 03 (normal layer) or 0D (FN layer)
off 1   : 04
off 2   : position byte from key map (0x2C substituted when map value is 'V' 0x56)
off 3-6 : 4-byte slot
off 31  : checksum
```

Example, key_index 1 (Esc) -> A:

```
03 04 01 02 00 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0E
```

**Whole layer** (`FUN_00418e80`, task 6 and "Reset Keyboard"): 576-byte table sent as 21
chunks: `cmd = 0x10` (normal) or `0x12` (FN), `off1 = 0x1C` (0x10 for the last chunk, index
20), `off2 = chunk index 0..20`, `off3..30 = table[28*i .. 28*i+27]`. 2 ms between chunks.

### 5.7 Per-key RGB [code: FUN_0044bd80]

1. Header: backlight packet with mode 0x80 and brightness from `this+0x814`:
   `05 10 00 80 00 00 00 00 00 00 00 00 <bri> 00 00 00 00 AA 55 ... cks`.
2. Table, `cmd 14`, `off1 1C`, `off2 = chunk`:
   - RGB keyboards (`this+0x7ac != 0`): 576-byte table, entry at key_index*4 = `<key_index> R G B`,
     21 chunks, last chunk len 0x10.
   - Mono: 192-byte table, one byte per key_index (0xFF on, 0 off), 7 chunks, last len 0x18.
   - Last two table bytes are `AA 55`.

Example, first chunk, key 1 red, key 2 green:

```
14 1C 00 00 00 00 00 01 FF 00 00 02 00 FF 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 31
```

### 5.8 Macros `09` [code: FUN_0042dbb0]

Buffer (max 0xE00 bytes, size check `(macros + events) * 8 <= 0xE10`):

- 0x000-0x18F: 100 entries of 4 bytes. `off_lo off_hi 00 00`, or `FF FF FF FF` for a macro with no events.
- At each offset: `count_lo count_hi 00 00 00 00 00 00`, then `count` events of 4 bytes:
  - key down `00 00 <hid> B0`, key up `00 00 <hid> 30`
  - mouse down `00 00 <btn> 90`, up `00 00 <btn> 10` (btn: left 01, right 04, middle 02)
  - delay `<ms_lo> <ms_hi> 00 50` (min 10 ms)
- Keys converted from Windows VK to HID by `FUN_00451460`.

Transfer: chunks of 28 bytes, `09 1C <index>`; last chunk's len byte = `total % 28`.
Quirk [code]: chunk count is `total/28 + 1 + (total%28 != 0)`, so there is always one extra
chunk, and `AA 55` is written into the last 2 bytes of that last chunk. Wired macro path
uses `04 19` / `04 15` (parsiya).

### 5.9 LCD image/GIF upload over 2.4G [code: FUN_004233f0]

Present in the binary but **the F108 Pro wireless menu hides it** (`menu_wireless screen="0"`).
Whether the dongle firmware accepts it is unknown.

Image buffer (same as wired):

- `total = gif_headlength + width*height*2*frames` = `256 + 64800*frames`, frames <= 141
  (`gif_maxframes`), allocated `total + 28` and pre-filled with 0xFF.
- `buf[0]` = frame count; `buf[1+i]` = max(1, frame_delay/2) (frame record field +0xC;
  aula-studio documents the byte as 20 ms units) [code for /2, units inferred].
- Frames as RGB565 from `mui.dll LCDViewList::GetImageRGB565Data`, 240x135, packed from offset
  256. Little-endian byte order [prior-hw].
- `chunks = ceil(total / 28)`, for one frame 2324 (0x0914); for 141 frames 326,324.

Packets:

```
header: 7F 03 00 <slot> <chunks b0> <chunks b1> <chunks b2> 00 ... cks
data i: (0x80 | (i>>16)) (i & 0xFF) ((i>>8) & 0xFF) <28 bytes of buffer[28*i ..]> cks
```

No trailer and no apply packet. Each chunk waits for its echo, then `Sleep(2)`. Expect
roughly 10 s per frame, which explains why AULA restricts the screen page to wired.

Example header (1 frame, slot 1) and first chunk:

```
7F 03 00 01 14 09 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 A0
80 00 00 01 05 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 6C
```

### 5.10 Music mode `0B 1C` [code: FUN_00432b60]

`0B 1C 00 <combo 0x618> <combo 0x630> <slider value> <21 bytes spectrum levels>` + checksum.
Streamed while the music page is active. The field meanings (effect, color, sensitivity)
are [inferred] from the UI control types.

### 5.11 Resets

- `1F` (task 0xD): "Reset Keyboard" dialog (strings 165/166) in 2.4G mode. Wired mode instead
  re-sends the key tables (task 6). [code: FUN_00414690, FUN_00434230]
- `0F` (task 0xE): "Factory Reset" (strings 167/168). Then after 50 ms the app re-sends
  lighting and sidelight. [code: FUN_00434ee0]

## 6. Notifications (keyboard to host) [code: FUN_00435160]

Polled every 200 ms on the usage page 0xFFFF / usage 1 collection (report ID 5):

| Input report | Meaning |
|--------------|---------|
| `05 A6 FF 01` | keyboard came online (behind the dongle) |
| `05 A6 FE 02` | keyboard went offline |
| `05 A6 <n> ..` | user custom-key event n, handled by `FUN_00419300` (launch program, open URL, switch profile) [inferred from the handler] |

Your dongle descriptor has no 0xFFFF collection in the facts given, so this may not apply.

## 7. Wired USB path (for comparison, 0C45:800A)

Verified on hardware (Alma F108 Pro, 2026-10-01) with `almactl` over Linux hidraw: backlight
and clock transactions exactly as listed below, on interface 3 (usage page 0xFF13, the
report descriptor declares 64-byte input, output and feature reports with no report ID),
sent with `HIDIOCSFEATURE`/`HIDIOCGFEATURE` and a leading 0x00 byte. The begin, apply
and finalize packets carry **no** `AA 55` trailer, as in the vendor driver; parsiya's notes
add one, but it is not needed. Interface 2 (usage page 0xFF68) is the LCD channel.

Transport [code: FUN_0044edc0, FUN_00451330, FUN_004513d0]: 64-byte **feature** reports
(`HidD_SetFeature` 0x41 bytes with report ID 0), optional readback by `IOCTL_HID_GET_FEATURE`
(0xB0192). `Sleep(35)` before every packet. Payloads > 65 bytes are sent as consecutive
64-byte feature reports. No checksum. Transactions:

```
04 18 (begin, readback)  ->  04 <init> (readback)  ->  data block(s)  ->  04 02 (apply, readback)  ->  04 F0 (finalize)
```

| Init | Data | Feature |
|------|------|---------|
| `04 13`, byte 8 = 1 | 16-byte block + `AA 55` at 14-15 | backlight (mode 0x80 = per-key header, fixing parsiya's "00 80") |
| `04 23`, byte 8 = 3/9 | 192/576-byte table | per-key color |
| `04 11` / `04 27`, byte 8 = 9 | 576-byte table | key remap normal / FN |
| `04 17`, byte 2 = 1, byte 8 = 1 | `00 01 ...`, `AA 55` at 62-63 | function settings |
| `04 28`, byte 8 = 1 | `00 slot 5A yy mm dd hh mi ss 00 dow`, `AA 55` at 62-63 | clock (no `04 F0`) |
| `04 19`, then `04 15` byte 8 = n | n x 64 bytes | macros |
| `04 72`, byte 2 = slot, bytes 8-9 = page count | 4096-byte **output** reports on the 0x1001 interface, 300 ms read ack each | LCD image [prior-hw] |
| `04 20` | 0xC0/0x200 bytes (`FUN_0044efb0`) | real-time custom light |
| `04 F5` | readback (`FUN_0044f290`) | read key colors |

Full wired detail and hardware notes: parsiya/f108-pro `ai-docs/hid-protocol.md`.

## 8. Wired vs 2.4G differences

| Aspect | Wired (Sonix, 0C45:800A) | 2.4G dongle (05AC:024F MI_03) |
|--------|--------------------------|-------------------------------|
| Report type | Feature, 64 B | Output + Input, 32 B |
| Framing | `04 xx` init + data blocks | single `cmd len idx data[28] cks` |
| Checksum | none | 8-bit sum at byte 31 |
| Ack | GET_FEATURE readback | input report echoing bytes 0..2 |
| Transaction | begin / apply / finalize | none, each packet applies |
| Pacing | 35 ms per packet | 5 ms + ack + 2 ms |
| LCD | 4096-byte pages on separate interface | 28-byte chunks, 24-bit index, hidden in UI |
| Battery | n/a | `20 01` |
| Firmware version | bcdDevice | bcdDevice of the dongle |

## 9. Which protocol does the Alma dongle speak?

Two unrelated protocols now exist for 05AC:024F with a 32-byte vendor interface:

1. This AULA/Sonix dongle protocol (`cmd len idx .. cks`, no header), from the official
   AULA F108Pro driver whose config names "F108Pro Dongle" MI_03.
2. The Huafenda (HFD) protocol (`AA cmd len .. AA 55`, replies `55`), used by Epomaker TH108
   Pro on the same VID:PID with 0xFF60/0x61 (see `protocol-hfd-web.md`).

The facts you gave (0xFF60/0x61 32-byte collection plus a second 64-byte 0xFF60 collection,
product string "F108Pro Dongle") fit both at the transport level. The HFD SDK lists a 64-byte
2.4G variant, and this AULA driver ignores 64-byte interfaces, which slightly favours HFD for
the Alma unit [inferred]. The safest first probes (not run here) would be the read-only
battery query of each protocol, since neither writes flash: AULA `20 01 00 .. 21`, HFD's
battery/info command from `protocol-hfd-web.md`. A correct reply identifies the family.

## 10. Not found / open questions

- Knob: no host protocol. The knob sends consumer codes from firmware only (parsiya); no
  knob strings or commands in the binary.
- No "get firmware version", "get settings" or "read keymap" commands on either path;
  the app keeps state in its SQLite DB and pushes it.
- Unit semantics of sleep time, response time and frame delay.
- Whether the dongle accepts the 2.4G LCD commands `7F` / `80+`.
- Bluetooth: unsupported by the software.
- The `menu_wireless` flags mean lighting, per-key, macros, remap, music and clock work over
  the dongle in the official app; screen upload does not.

## 11. Saved sources (`docs/protocol-sources/`)

These files are third-party code (a decompiled vendor driver and vendor web bundles). They
are kept locally for reference and are **not** published in this repository; the
reproduction steps below regenerate them.

| File | Content |
|------|---------|
| `config.xml` | device table (VID/PID/MI per mode) |
| `rgb-keyboard.xml` | feature flags, screen geometry, key_index / light_index layout |
| `lang-1033-en.txt` | English UI strings (effect names, dialog ids) |
| `dongle_24g.c` | decompiled 2.4G transport, probe, enumeration, all 2.4G senders |
| `wired_usb.c` | decompiled wired transport and main wired senders |
| `dispatcher.c` | worker-thread task dispatcher, reset dialog, VK to HID table |

Reproduce: `innoextract "AULA F108Pro Driver.exe"`, then Ghidra headless
`analyzeHeadless <proj> dd -import app/DeviceDriver.exe -postScript DecompileAll.java out.c`.
