# DelphiBuildBridge

**DelphiBuildBridge** is a tool that enables unattended, automated compilation of Delphi projects directly from the command line, terminal, CI/CD scripts, and AI agents.

Compilation is executed inside a running `bds.exe` process via the **Open Tools API (OTAPI)** .

---

## System Architecture

The system consists of two independent components communicating via a file queue in the `%TEMP%\delphi_build_bridge\` directory:

```
               +--------------------------------------+
               |             RunBuild.exe             |
               |     (Console Client / AI Agent)      |
               +-------------------+------------------+
                                   |
         1. Submit request         |   4. Read result
         queue\<ID>.trigger.json   |   results\<ID>.json.done
                                   v
             +--------------------------------------------+
             | File System (%TEMP%\delphi_build_bridge)   |
             |   queue\  |  queue\processing\  | results\ |
             +---------------------+----------------------+
                                   ^
         2. Polling and locking    |   3. Write results
         queue\processing\         |   results\<ID>.json
                                   |
               +-------------------+---------------------+
               |        BuildBridge.bpl (Plugin)         |
               |      Delphi IDE Process (bds.exe)       |
               |  (OTAPI: IOTAProjectBuilder / Messages) |
               +-----------------------------------------+
```

### Components:

1. **Delphi Plugin (`src/BuildBridge.dpk`)**:
   The plugin runs inside the Delphi IDE environment, where a background thread monitors the file queue, parses requests, and signals process readiness ([BuildBridge.Watcher.pas], [BuildBridge.Types.pas]). In the IDE main thread, it executes unattended compilation of the specified project with suppressed progress dialogs, captures authentic compiler messages from the message view, and atomically writes the result to a JSON file ([BuildBridge.CompileController.pas]).
2. **Console Client (`RunBuild/RunBuild.dpr`)**:
   Native CLI console tool that submits build requests, waits for build completion, and displays formatted results in the console window.

---

## Using the `RunBuild.exe` Tool

### Syntax

```powershell
RunBuild.exe [ProjectName.dproj] [options]
```

If exactly one `.dproj` file is present in the program directory, the project name parameter can be omitted. In case of no project or multiple `.dproj` files, the program displays a list of available projects and requires an explicit project name.

### Command Line Options

| Option | Description | Default Value |
|---|---|---|
| `-p, --project <path>` | Path to the `.dproj` project file | Automatic detection of a single `.dproj` |
| `-c, --config <name>` | Build profile (`Debug` or `Release`) | `Debug` |
| `-t, --platform <name>` | Target platform (`Win32` or `Win64`) | `Win32` |
| `-b, --bds <path>` | Path to `bds.exe` (when IDE is not yet active) | `%BDS%\bin\bds.exe` variable or default Delphi 12 path |
| `--timeout <seconds>` | Build timeout in seconds | `300` |
| `--cleanup` | Delete request files (`<ID>.json` and `<ID>.json.done`) after completion | Disabled (files remain in `results\`) |
| `-h, --help` | Display help and program options | — |

---

## Usage Examples

### 1. Default project compilation in the current folder (Win32, Debug)
```powershell
RunBuild.exe
```

### 2. 64-bit compilation in Debug profile
```powershell
RunBuild.exe -c Debug -t Win64
```

### 3. Compilation with specified project file (positionally or via `-p`)
```powershell
RunBuild.exe MyProject.dproj -c Release -t Win64
RunBuild.exe -p C:\Projects\MyProject\MyProject.dproj -c Release -t Win64
```

### 4. Compilation with automatic cleanup of result files
```powershell
RunBuild.exe -p MyProject.dproj -c Debug -t Win64 --cleanup
```

---

## Example Console Output

### 1. Compilation completed with success (`SUCCESS`):

```text
Project:  MyProject.dproj
Folder:   C:\Projects\MyProject\
Config:   Release | Platform: Win64
Build in progress (RequestId: 3B8C1D2A-94F0-4E31-82D5-0C7A65E198F2)...

============================================================
 Delphi Build Bridge - Compilation Results
============================================================
Status:       SUCCESS
Duration:     1250 ms
Errors:       0
Warnings:     0
------------------------------------------------------------
No compiler messages.
============================================================
```

### 2. Compilation completed with error (`FAILED`):

```text
Project:  MyProject.dproj
Folder:   C:\Projects\MyProject\
Config:   Debug | Platform: Win64
Build in progress (RequestId: 7E4295D3-BC97-4A12-B83F-31BFA70F2841)...

============================================================
 Delphi Build Bridge - Compilation Results
============================================================
Status:       FAILED
Duration:     1840 ms
Errors:       1
Warnings:     0
------------------------------------------------------------
Compiler Messages:
MainUnit.pas(142,22): [ERROR] E2018 Expected ':' but received :=
============================================================
```

---

## Process Exit Codes

| Code | Status | Description |
|:---:|---|---|
| **`0`** | `SUCCESS` | Compilation succeeded without errors (`ErrorCount = 0`). |
| **`1`** | `FAILED` / `ERROR` | Compiler reported errors or compilation failed. |
| **`2`** | Infrastructure Error | Missing project file, timeout exceeded, IDE launch failure, or invalid arguments. |

---

## Configuration via `RunBuild.ini` File

A `RunBuild.ini` (or `BuildBridge.ini`) file can be placed in the `RunBuild.exe` executable directory:

```ini
[Build]
Project=MyProject.dproj
Config=Debug
Platform=Win64
TimeoutSeconds=300
Cleanup=0
```

---
