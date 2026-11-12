# Voice Tasks

A personal voice-to-task app for iPhone and Mac. It records speech, uses Groq Whisper and GPT-OSS to extract tasks, and sends reviewed tasks to Todoist or TickTick. Both apps require your own API tokens, entered on the device and saved in the system Keychain. Audio and transcripts are sent to Groq.

## iPhone

Open `VoiceTasks.xcodeproj`, select your Apple account in Signing & Capabilities, connect an iPhone running iOS 17 or later, and press Run. In the app settings enter a Groq key and the token for your chosen task app. Configure the Action button to run the app's Start Voice Capture shortcut. The app stops and discards an unfinished recording when it enters the background.

## Mac

Open `Mac/VoiceTasksMac.xcodeproj`, select My Mac, and press Run. The app lives in the menu bar and requests launch at login. Left-click its waveform icon to open the panel and start recording; click Stop & review when finished. Review and add your tasks. Clicking away cancels an unfinished recording while keeping previously extracted tasks. Right-click the menu-bar icon to open the panel without recording or quit the app.

The first recording requires Microphone permission. Use the panel's Settings to enter a Groq key and the token for your task app. You can turn off launch at login there. The app no longer monitors keyboard input. TickTick Inbox defaults and all-day dates need testing against a live account.

## Tokens

Create a Groq API key at https://console.groq.com/. Todoist offers its API token in Settings > Integrations > Developer. TickTick offers personal API tokens in the TickTick web app under Settings > Account > API Token. Keep tokens private and never commit them.

Free-tier limits and availability can change. With a free Apple Personal Team, iPhone signing expires periodically and the app must be reinstalled.

The app icon uses Lucide's audio-lines icon; see `LUCIDE-LICENSE.txt`.
