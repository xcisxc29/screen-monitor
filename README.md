# Screen Monitor Assistant

Real-time screen analysis for Windows. It watches your display, extracts text and questions with **local OCR** (zero cloud cost, no rate limits), answers them with **DeepSeek AI**, and shows results in a **floating overlay window** — all managed from a small **GUI console**.

![Platform](https://img.shields.io/badge/Platform-Windows-blue)
![Language](https://img.shields.io/badge/Language-PowerShell-blueviolet)
![OCR](https://img.shields.io/badge/OCR-Local%20(Windows.Media.Ocr)-green)
![AI](https://img.shields.io/badge/AI-DeepSeek-orange)

---

## Features

- 🖥️ **Real-time screen monitoring** — captures the screen every 3 s, analyzes only when content changes (debounced 2 s)
- 📝 **Local OCR** — built-in Windows OCR engine (`Windows.Media.Ocr`), fully offline, free, never rate-limited
- 🤖 **AI answering** — quiz questions are answered by DeepSeek (OpenAI-compatible API), with per-question answers and reasons
- 🪟 **Floating overlay window** — draggable, semi-transparent, large color-coded answer letters, always on top
- 🎛️ **GUI console** — one-click start/stop of the whole stack, API key management, live status, run log
- ⌨️ **Global hotkey** — `Ctrl+Shift+S` analyzes the current screen instantly
- 🧠 **Smart caching** — LLM answers are cached persistently (LRU) with fuzzy matching for OCR jitter; saves tokens and money
- 📂 **Clean output** — all results delivered to a dedicated `result/` folder (`result.json`, history, cost stats)
- 🧹 **Privacy controls** — optional region-restricted analysis (`analyzeRegion`), overlay auto-excluded from analysis

## Screenshots

*(Add screenshots of the console and floating window here — replace this block with `![console](docs/console.png)`)*

## Quick Start

1. **Clone or download** this repository.
2. **Run** `启动屏幕监测助手.bat` (or `monitor-console.ps1`) to open the console.
3. **Enter your DeepSeek API key** (get one at <https://platform.deepseek.com>), click **Save Key**.
4. Click **▶ Start Service** — monitoring begins, the floating window appears (top-right).
5. Done. Show a quiz/any text on screen; answers appear in the floating window within seconds.

> First run only: the config `apiKey` field is empty by design — the console prompts you to fill it.

## Usage

| Action | How |
|---|---|
| Start monitoring | Console → **▶ Start Service** |
| Stop monitoring (closes overlay too) | Console → **■ Stop Service** |
| Analyze screen right now | Press **Ctrl+Shift+S** |
| Move overlay | Drag the top bar |
| Overlay opacity | `PgUp` / `PgDn` (30%–100%) |
| Close overlay | `Esc` |
| View results | Console → **📂 Open result folder** |

## Configuration

All settings live in `config.json`:

| Key | Description |
|---|---|
| `intervalSec` | Capture interval (s) |
| `debounceSec` / `maxWaitSec` | Analyze after screen settles / force cap |
| `analyzeRegion` | Restrict analysis to a screen region (`enabled`, `x`, `y`, `w`, `h`) |
| `excludeRegion` | Area to ignore (the overlay itself, synced automatically) |
| `llm.enabled` / `apiKey` / `model` | DeepSeek settings |
| `llm.cacheMax` / `cacheSimilarity` | LLM cache size / fuzzy-match threshold (0 = exact hash only) |
| `llmCost.*` | Price per million tokens (USD) for cost estimation |

## Project Structure

```
screen-monitor/
├── monitor-console.ps1     # GUI control panel
├── monitor-service.ps1     # Core service (capture / OCR / LLM / publish)
├── overlay-window.ps1      # Floating overlay window
├── hotkey.ps1              # Global hotkey listener (Ctrl+Shift+S)
├── ocr.ps1                 # Standalone local-OCR utility
├── config.json             # Configuration (API key empty by default)
├── 启动屏幕监测助手.bat       # Console launcher
├── quiz-full.html          # Test quiz page (6 questions)
└── result/                 # Output: result.json, history.jsonl, stats.json, overlay.txt/html
```

## How It Works

```
Screen ──(capture every 3 s)──> change detection ──(debounce 2 s)──> local OCR
    ──> heuristic quiz detection ──> DeepSeek LLM (cached) ──> overlay + result/
```

- **Text questions only.** Image-based questions ("see the picture") are not supported yet.
- Scrolling: only what is visible on screen is analyzed; scroll and pause 2 s to continue.
- Privacy: screen data is processed locally; OCR text is sent to DeepSeek only in quiz mode.

## Disclaimer

- This tool captures your screen. Use it responsibly — do not run it on sensitive content you do not want processed.
- Automated answering may violate the terms of exam/quiz platforms. You are responsible for how you use it.
- Your API key is stored in plain text in `config.json` (local only). Do not commit it to any public repository.

## License

MIT — free to use, modify and share.
