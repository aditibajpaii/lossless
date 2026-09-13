# LOSSLESS

Dictation for macOS. Hold Right Command, speak, release. Text lands in the app you were typing in.

<img width="1480" height="760" alt="lossless-architecture" src="https://github.com/user-attachments/assets/bde64784-c653-4215-982b-37799d948a83" />


## Run

```
scripts/bundle.sh
open build/Lossless.app
```

Add your AssemblyAI key in Settings. Grant Microphone, Input Monitoring, and Accessibility.

```
build/Lossless.app/Contents/MacOS/Lossless --doctor
scripts/check.sh
```
<img width="620" height="560" alt="inspector" src="https://github.com/user-attachments/assets/07ec6062-baee-414a-afb9-4da3e4818010" />

## Requirements

macOS 15 or later.
