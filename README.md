# OllamaChat

Native macOS app for chatting with local Ollama models. Built with SwiftUI, runs entirely on-device.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.0-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

### Chat
- Stream responses from local **Ollama** models (Gemma 4 26B default)
- **Projects** with separate chats and custom system instructions
- **Thinking mode** — toggle model reasoning (show/hide thought process)
- **Web search** — DuckDuckGo integration, results injected as context
- **Markdown rendering** — code blocks, tables, headers, links, blockquotes
- **Image understanding** — drag & drop or attach photos (multimodal)
- **Cancel generation** — stop mid-response

### Voice
- **Speech-to-Text** — WhisperKit (Whisper large-v3-turbo), 100+ languages including Russian
- **Text-to-Speech** — Apple AVSpeechSynthesizer or Qwen3-TTS 0.6B
- **Sound classification** — Apple MLSoundClassifier (300+ categories)
- **Hands-free mode** — auto-detect speech, transcribe, send to model, speak response, repeat
- **Auto language detection** — model tags response language, TTS picks matching voice

### Telegram Bot
- Full Telegram bot with **streaming responses** (live message updates)
- **Inline mode** — use `@botname query` in any chat
- **Voice messages** — transcribed via Whisper, answered by model
- **Photo messages** — analyzed by multimodal model
- **Threaded chats** — proper forum/topic support
- **User authorization** — approve/deny users from the app
- **Per-user projects** — each Telegram user gets their own project with chat history
- **Commands**: `/thinking`, `/web`, `/cancel`, `/clear`

### Settings
- Model download management (Whisper, Qwen3-TTS)
- TTS engine selection (Apple vs Qwen3) with voice picker and speed control
- Telegram bot configuration and user management

## Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4)
- **[Ollama](https://ollama.com)** running locally with a model pulled
- **ffmpeg** (for Telegram voice messages): `brew install ffmpeg`

## Quick Start

1. Install and start [Ollama](https://ollama.com):
   ```bash
   ollama pull gemma4:26b
   ```

2. Build & run:
   ```bash
   git clone https://github.com/timskap/OllamaChat.git
   cd OllamaChat
   open OllamaChat.xcodeproj
   ```
   Or build from command line:
   ```bash
   xcodebuild -project OllamaChat.xcodeproj -scheme OllamaChat -configuration Release build
   ```

3. Open Settings (gear icon) to download voice models (optional):
   - **Whisper** (~630 MB) — for speech-to-text
   - **Qwen3-TTS** (~600 MB) — for AI voice synthesis

## Telegram Bot Setup

1. Create a bot via [@BotFather](https://t.me/BotFather)
2. Enable inline mode: `/setinline` and `/setinlinefeedback` (set to Enabled)
3. Open Settings in the app → Telegram tab
4. Paste bot token and enable
5. Approve users as they request access

## Architecture

```
OllamaChat/
├── OllamaChatApp.swift        # App entry point
├── Models.swift               # Data models (Project, Chat, Message)
├── ProjectStore.swift         # JSON persistence
├── OllamaService.swift        # Ollama API client with streaming
├── AudioService.swift         # WhisperKit STT + mic recording
├── TTSService.swift           # Apple TTS + Qwen3-TTS
├── SoundClassifierService.swift # Apple MLSoundClassifier
├── WebSearchService.swift     # DuckDuckGo search
├── TelegramService.swift      # Telegram Bot API
├── ContentView.swift          # Main layout (NavigationSplitView)
├── SidebarView.swift          # Projects & chats sidebar
├── ChatView.swift             # Chat UI with toggles
├── InstructionsView.swift     # Project instructions editor
└── SettingsView.swift         # Global settings & model management
```

## Dependencies

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) (includes TTSKit) — speech recognition & synthesis
- [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) — markdown rendering
- Apple frameworks: SoundAnalysis, AVFoundation, AppKit

## License

MIT
