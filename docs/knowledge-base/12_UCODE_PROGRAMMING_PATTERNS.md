# 12. ucode Programming Patterns & Conventions

A developer's guide to writing safe, high-performance, and idiomatic **ucode** modules for Tachyon on OpenWrt.

---

## 1. ucode vs JavaScript: Critical Distinctions

While ucode syntax resembles JavaScript, its runtime semantics differ significantly:

1. **Variables & Scope**:
   * Always declare variables with `let` or `const`.
   * Unassigned variables are `null` (not `undefined`).
2. **Arrays vs Dictionaries**:
   * Arrays: `[1, 2, 3]`. Iterated with `for (let item in array)`.
   * Dictionaries (Objects): `{"key": "value"}`. Iterated with `for (let key, val in dict)`.
3. **Regular Expressions**:
   * Use `match(str, /regex/)` or `replace(str, /regex/g, "replacement")`.
   * Global flag `/g` works with `replace()`, while `match()` returns capture groups array `[full_match, group1, ...]`.
4. **Boolean Coercion**:
   * Empty strings `""`, `0`, and `null` are falsy. Everything else is truthy.

---

## 2. Mandatory Core Design Patterns

### 2.1. Atomic Configuration Writes
Never overwrite active configuration files in-place. Always write to a temporary file in `/tmp/` and atomically rename:

```ucode
let fs = require("fs");

function write_atomic(path, content) {
    let tmp_path = path + ".tmp." + int(time());
    let f = fs.open(tmp_path, "w");
    if (!f) return false;
    
    f.write(content);
    f.close();
    
    return fs.rename(tmp_path, path);
}
```

### 2.2. Shell Argument Quoting
When executing external shell commands, all user inputs must be quoted safely:

```ucode
function shell_quote(value) {
    return "'" + replace("" + value, /'/g, "'\\''") + "'";
}

function safe_exec(cmd_args) {
    let parts = [];
    for (let arg in cmd_args)
        push(parts, shell_quote(arg));
    return system(join(" ", parts));
}
```

### 2.3. Safe Error Handling (`try-catch`)
All external library loading or file parsing must be wrapped in `try-catch` blocks to avoid unhandled script panics:

```ucode
let uci_data = null;
try {
    let uci = require("uci").cursor();
    uci_data = uci.get_all("tachyon", "settings");
}
catch (e) {
    warn("Failed to load UCI settings: " + e + "\n");
}
```

---

## 3. Performance & Memory Optimization Guidelines

1. **Stream Large Files**: Avoid loading multi-megabyte blocklists entirely into RAM with `fs.readfile()`. Use line-by-line streaming via `fs.open()` and `f.read("line")`.
2. **Avoid Spawning Subprocesses in Loops**: Invoking `system()` or `fs.popen()` spawns a fork-exec sequence in Linux. Use native ucode functions for string manipulation and path operations whenever possible.
3. **Keep Modules Stateless**: Module files under `usr/lib/tachyon/` should export reusable pure functions or class definitions rather than maintaining mutable global state.
