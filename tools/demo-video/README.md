# Demo video builder

Assembles the POC showcase video from four screen recordings, then adds an AI voiceover (Azure AI Speech), product branding, captions, title and recap cards, and time compression. The output is a 1080p MP4 of about 5.5 minutes.

[`plan.json`](plan.json) contains the edit decision list. For each segment, it defines:

- The source recording and the time ranges to use.
- Each range's playback speed, either fixed or `flex`. A `flex` range speeds up to fit the narration, to a maximum of 4.5×.
- The product chip, caption, and narration.

[`build.py`](build.py) renders the graphics with Pillow and assembles the video with ffmpeg.

Recordings, voiceover audio, brand assets, and rendered output aren't committed; they're ignored by git.

## Prerequisites

- **Python 3.11+** with Pillow (`pip install pillow`)
- **ffmpeg** (`winget install Gyan.FFmpeg`)
- **Fonts:** Segoe UI, which comes with Windows
- **Speech resource:** an Azure AI Speech resource with a custom subdomain and Microsoft Entra ID access. The signed-in user needs the **Cognitive Services Speech User** role.
- **Recordings:** the four scene recordings named in `plan.json` → `sources`. See [docs/demo-video-script.md](../../docs/demo-video-script.md).

## Working directory layout

`DEMO_VIDEO_WORKDIR` defaults to this folder.

```text
assets/   foundry.png vpn.png firewall.png bot.png vnet.png privatelink.png entra.png
          teams.png vscode-logo.png microsoft.png        (256 px, transparent PNG)
vo_wav/   00_intro.wav … 14_outro.wav                     (one per plan segment id)
gfx/ segs/                                                (generated)
```

### Brand assets

| File | Source |
|---|---|
| `foundry.png` and the other Azure icons | [Azure architecture icons](https://learn.microsoft.com/azure/architecture/icons/): Foundry Agent Service, Virtual Network Gateways, Firewalls, Bot Services, Virtual Networks, Private Link, and Entra Identity Roles and Administrators. Render the SVGs at 256 px; headless Edge works. |
| `vscode-logo.png` | [VS Code brand assets](https://code.visualstudio.com/brand) |
| `teams.png` | Official Teams app logo (Brand Central, or the installed Teams app's `Images` folder) |
| `microsoft.png` | Microsoft logo (Brand Central). Swap in official Microsoft 365 Copilot and Microsoft 365 admin center logos from Brand Central if available. |

### Voiceover

Generate one clip per segment `vo` text in `plan.json`, with the voice in `plan.json` → `voice`. This build used the Azure MCP `speech` tool (`speech_tts_synthesize`). That tool writes **raw 24 kHz, 16-bit, mono PCM** despite the `.wav` name, so wrap each file before building:

```powershell
ffmpeg -f s16le -ar 24000 -ac 1 -i raw\01_blocked.wav vo_wav\01_blocked.wav
```

## Build

```powershell
python build.py --sources "C:\path\to\recordings"
# or: $env:DEMO_VIDEO_WORKDIR = "C:\path\to\workdir"; python build.py --sources ... --output demo.mp4
```

The script prints a timeline with each segment's start time, duration, and applied speeds, and writes it to `timeline.txt`. Every segment's band covers the screen recorder's "sharing your screen" bar at the bottom of the frame.

## Changing the edit

- **Reword narration:** Edit `vo`, regenerate that clip, and rebuild. Segment timing adapts automatically.
- **Retime a scene:** Edit `pieces`, where each entry is `[start_s, end_s, speed|"flex"]` against the source recording.
- **Change branding or captions:** Edit `chip` and `caption`. The graphics are regenerated on every build.
