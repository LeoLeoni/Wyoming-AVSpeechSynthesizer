# Wyoming-AVSpeechSynthesizer

TTS swift application designed to run as a launch agent on macOS. Follows Wyoming protocol to enable integration with Homeassistant. This project was almost entirely vibe-coded save for this README.

## Goal

When interacting with robot assistants via speech, the synthesized voice that you hear back is important to the overall experience. [Piper](https://github.com/OHF-Voice/piper1-gpl) was easy to set up but I wasn't a fan of how the voices sounded. I wanted to see what other self-hosted TTS engines I could use that had voices of the same quality as Apple's Siri and Amazon's Alexa.

## Process

I already had a Mac Mini running [whisper-cpp](https://github.com/ggml-org/whisper.cpp) for the STT part of my homeassistant assist pipeline, and Apple's enhanced and premium TTS voice models are pretty good, so I searched for macOS-native APIs for that would let me use Apple's robot voices for TTS. [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) was perfect for my use case.

## Arguments
`--port` Port to listen on for Wyoming protocol. Default 10200

`--voice` Voice to speak with. Required. Must be one of the installed voices in System Settings.

`--list-voices` CLI to quickly list available voices if working over SSH and not in macOS desktop UI. Don't include the locale in the --voice argument.

## Deployment
1. Build the project and deploy the binary
```bash
swift build -c release
sudo cp .build/release/wyoming-avspeech /usr/local/bin/
```
2. Configure the example .plist by editing the --voice argument to the desired voice. Voice models can be downloaded only from the GUI in System Settings -> Accessibility -> Spoken Content -> System Voice -> Manage Voices.
3. Install the .plist as a user LaunchAgent
```bash
cp com.wyoming.avspeech.plist ~/Library/LaunchAgents
launchctl load ~/Library/LaunchAgents/com.wyoming.avspeech.plist
```

4. (Optional) Change the voice by editing ~/Library/LaunchAgents/com.wyoming.avspeech.plist and reloading the LaunchAgent

```bash
nvim ~/Library/LaunchAgents/com.wyoming.avspeech.plist
launchctl unload ~/Library/LaunchAgents/com.wyoming.avspeech.plist
launchctl load ~/Library/LaunchAgents/com.wyoming.avspeech.plist
```

## Caveats

macOS prevents using the Siri voices in AVSpeechSynthesizer and will either respond with silence or fall back to one of the other defaults when attemping to use them.
