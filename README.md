# OpenClaude iOS

A modern iOS app for Claude Code functionality supporting multiple LLM providers.

## Features

- **Multi-Provider Support**: OpenAI, Anthropic, Hugging Face, Ollama, Local Models
- **Embedded API Server**: OpenAI-compatible REST API on your device
- **Tool Execution**: Bash, file operations, grep, glob, web fetch/search
- **Model Management**: Download and run GGUF models from Hugging Face

## Requirements

- iOS 26.0+
- Xcode 16.0+
- Swift 6.0

## Building

```bash
xcodebuild archive \
  -project OpenClaude.xcodeproj \
  -scheme OpenClaude \
  -destination "generic/platform=iOS" \
  -archivePath "build/OpenClaude.xcarchive" \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO
```

## Installation

This is an **unsigned IPA**. Install using:
- AltStore
- Sideloadly
- Xcode with your developer certificate

## Configuration

Set API keys in Settings:
- OpenAI: `OPENAI_API_KEY`
- Anthropic: `ANTHROPIC_API_KEY`
- Hugging Face: `HUGGINGFACE_KEY`

## License

MIT License
