# Voice Tasks

A personal voice-to-task app for iPhone and Mac. It records speech, uses Groq Whisper and GPT-OSS to extract tasks, and sends reviewed tasks to Todoist or TickTick. Both apps require your own API tokens, entered on the device and saved in the system Keychain. Audio and transcripts are sent to Groq.

## iPhone

Open `VoiceTasks.xcodeproj`, select your Apple account in Signing & Capabilities, connect an iPhone running iOS 17 or later, and press Run. In the app settings enter a Groq key and the token for your chosen task app. Configure the Action button to run the app's Start Voice Capture shortcut. The app stops and discards an unfinished recording when it enters the background.

## Mac

Open `Mac/VoiceTasksMac.xcodeproj`, select My Mac, and press Run. The app runs in the menu bar and requests launch at login the first time it runs. You can change this in the app Settings or macOS Login Items & Extensions. From its waveform menu choose Open Voice Tasks, open Settings, and enter a Groq key and the token for your task app. Grant Microphone and Input Monitoring permissions if macOS asks; Input Monitoring is needed to detect the Right Command key across apps. After granting permission, quit and reopen the app or choose Enable Right Command from its menu.

Press and hold **Right Command** to show the small listening panel. Release it to transcribe and review tasks. Use Add tasks after reviewing. The first microphone permission prompt can interrupt the initial attempt, so grant it and try again. The app must be running for the key to work. A brief press is ignored; pressing another key while holding Right Command cancels the capture so ordinary shortcuts can continue. This is a listen-only key monitor; macOS still sends key events to other apps.

The Mac version is a prototype: the hold gesture, floating panel, and microphone need testing on a real Mac; dates can be edited from the task card. TickTick Inbox defaults and all-day dates also need live-account testing. The review panel hides when you switch to another app and retains unadded tasks; closing the panel discards any unfinished recording. Use the menu-bar item to quit the app.

## Tokens

Create a Groq API key at https://console.groq.com/. Todoist offers its API token in Settings > Integrations > Developer. TickTick offers personal API tokens in the TickTick web app under Settings > Account > API Token. Keep tokens private and never commit them.

Free-tier limits and availability can change. With a free Apple Personal Team, iPhone signing expires periodically and the app must be reinstalled.

The app icon uses Lucide's audio-lines icon; see `LUCIDE-LICENSE.txt`.
