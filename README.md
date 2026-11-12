# Voice Tasks

A personal voice-to-task app for iPhone and Mac. It records speech, uses Groq Whisper and GPT-OSS to extract tasks, and sends reviewed tasks to Todoist or TickTick. Both apps require your own API tokens, entered on the device and saved in the system Keychain. Audio and transcripts are sent to Groq.

## iPhone

Open `VoiceTasks.xcodeproj`, select your Apple account in Signing & Capabilities, connect an iPhone running iOS 17 or later, and press Run. In the app settings enter a Groq key and the token for your chosen task app. Configure the Action button to run the app's Start Voice Capture shortcut. The app stops and discards an unfinished recording when it enters the background.

## Mac

Open `Mac/VoiceTasksMac.xcodeproj`, select My Mac and press Run. Enter API tokens in the Mac app settings; the Mac and iPhone maintain their own credentials. Use the waveform icon in the macOS menu bar and select Start recording, or press Control–Option–Space while the app is running. The window must have been opened once so the shortcut can register. The first recording requires microphone permission. Close the main window to discard an unfinished recording; choose Quit Voice Tasks from the menu bar to exit.

The Mac version is a first prototype: date editing currently uses text fields, and the global shortcut is fixed. The app must be running for the shortcut to work. TickTick's API behavior, particularly Inbox defaults and all-day dates, needs testing against a live account. Review tasks and dates before adding them.

## Tokens

Create a Groq API key at https://console.groq.com/. Todoist offers its API token in Settings > Integrations > Developer. TickTick offers personal API tokens in the TickTick web app under Settings > Account > API Token. Keep tokens private and never commit them.

Free-tier limits and availability can change. With a free Apple Personal Team, iPhone signing expires periodically and the app must be reinstalled.

The app icon uses Lucide's audio-lines icon; see `LUCIDE-LICENSE.txt`.
