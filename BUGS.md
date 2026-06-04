# Bug Report — zippo

Scope: `src/main.zig`, `src/editor/Editor.zig`, `src/term/RawMode.zig`, `src/util/printer.zig`.
---

## 4. Screen left dirty on any error exit (Medium)

**File:** `src/main.zig:30-60`

The clear-screen + home-cursor sequence is only emitted on the `Ctrl-Q` path. If `refresh()`, `readKey()`, or any other call returns an error, `main` propagates and the user is dropped back to a shell with editor garbage on screen. The terminal mode itself is restored by `defer raw.deinit()`, but the visible state isn’t.

**Fix:** use an `errdefer` (or wrap the loop) that always clears the screen:

```zig
errdefer {
    out.print("\x1b[2J", .{}) catch {};
    out.print("\x1b[H", .{}) catch {};
    out.flush() catch {};
}
```

---

## 5. `getCursorPos` reads uninitialised bytes on early failure (Medium)

**File:** `src/editor/Editor.zig:118-143`

```zig
var buf: [32]u8 = undefined;
var i: u16 = 0;
...
while (i < buf.len - 1) : (i += 1) {
    const n = std.posix.read(self.fd, buf[i .. i + 1]) catch break;
    if (n != 1) break;
    if (buf[i] == 'R') break;
}
buf[i] = 0;

if (i < 2 or buf[0] != '\x1b' or buf[1] != '[') return error.BadEscape;
```

If the very first read fails (or returns 0), the loop breaks with `i == 0`. The guard `i < 2` short-circuits before reading `buf[0]`/`buf[1]`, so this is safe *today* — but it depends on Zig short-circuit semantics, and `buf` is `undefined`. Any future refactor (e.g. logging `buf[..i]` for debugging) would read garbage. Also, the loop terminates on `read` error rather than surfacing it.

**Fix:** initialise `buf = std.mem.zeroes([32]u8)`, and don’t swallow read errors:

```zig
var buf = std.mem.zeroes([32]u8);
var i: u16 = 0;
while (i < buf.len - 1) : (i += 1) {
    const n = try std.posix.read(self.fd, buf[i..i + 1]);
    if (n != 1) break;
    if (buf[i] == 'R') break;
}
```

---

## 6. Duplicated `controlKey` helper (Low — consistency)

`controlKey` is defined in **both** `src/main.zig:8-10` and `src/editor/Editor.zig:24-26`, with identical bodies and identical comments. Only `main.zig` uses it.

**Fix:** delete the copy in `Editor.zig` (or expose it from a shared place and delete the one in `main.zig`).

---

## 7. Constness lies — `readKey` and `refresh` claim `*const Editor` but the writer mutates (Low — best practice)

**File:** `src/editor/Editor.zig:34`, `:73`, `:100`

```zig
pub fn readKey(self: *const Editor) !Key { ... }
fn   drawRows(self: *const Editor) !void { ... }
pub fn refresh(self: *const Editor) !void { ... }
```

These take `*const Editor` but go on to call `self.writer.print(...)` which mutates the buffered writer through a `*Out` pointer stored in the struct. That works because `writer` is a pointer (so the pointer itself doesn’t change), but it’s misleading: callers reading the signature assume nothing observable changes. It also makes it impossible to mutate, e.g., `cy`/`cx` from `readKey` later without a signature churn.

**Fix:** make them `*Editor`. Drop the `*const` on methods that perform I/O.

---

## 8. `main.zig` re-implements arrow-key dispatch by enumeration (Low — style)

**File:** `src/main.zig:49-58`

```zig
.arrow_left => e.moveCursor(c),
.arrow_down => e.moveCursor(c),
.arrow_up => e.moveCursor(c),
.arrow_right => e.moveCursor(c),
.page_down, .page_up => { ... },
```

The first four branches all do the same thing. They can be combined:

```zig
.arrow_left, .arrow_down, .arrow_up, .arrow_right => e.moveCursor(c),
```

---

## 9. `getCursorPos` writes a stray `\r\n` to the screen (Low)

**File:** `src/editor/Editor.zig:124`

```zig
try self.writer.print("\x1b[6n", .{});
try self.writer.print("\r\n", .{});   // <-- prints a newline before reading the response
```

This nudges the cursor one row down (often into the bottom-right corner area where the cursor is already parked from the `999C999B` trick), and the printed `\r\n` is what gets the device-status report flushed in some terminals — but on a fresh terminal it also scrolls the screen one line. On the first refresh after this, `screen_rows` may be off by one, or the row count includes a now-scrolled line.

If the intent is just to flush, replace the `\r\n` with an explicit `try self.writer.flush();` (which is already done two lines later) and drop the print.

---

## 10. Comments are slightly misleading (Low — docs)

- `RawMode.zig:13` — `Shut off Ctrl-M`: `ICRNL` actually disables CR→NL translation. The Ctrl-M effect is a side benefit.
- `RawMode.zig:31` — `Shut off Ctrl-v`: `IEXTEN` disables a broader set of extended functions (Ctrl-V, Ctrl-O on BSD).
- `RawMode.zig:33` — `Shut off Ctrl-C`: `ISIG` disables Ctrl-C **and** Ctrl-Z (and Ctrl-Y, Ctrl-\\). Worth mentioning.

These don’t cause bugs but will mislead the next reader.

---

## Severity summary

| # | Severity | Area | Symptom |
|---|----------|------|---------|
| 1 | Critical | Editor | PgUp/PgDn don’t work, ever |
| 2 | High | Editor | Underflow → freeze on small terminals |
| 3 | Medium | Editor | Underflow when window size is 0 |
| 4 | Medium | main | Screen garbage on error exit |
| 5 | Medium | Editor | Reads from `undefined` buffer (latent) |
| 6 | Low | Editor / main | Duplicated `controlKey` |
| 7 | Low | Editor | `*const Editor` misleads readers |
| 8 | Low | main | Arrow-key branches could be merged |
| 9 | Low | Editor | Stray `\r\n` in cursor-position probe |
| 10 | Low | RawMode | Misleading flag comments |

The first three are worth fixing before the next feature; the rest are cleanup.
