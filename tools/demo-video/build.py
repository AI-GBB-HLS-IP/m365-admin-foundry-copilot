"""Builds the POC showcase video from the scene recordings, Azure TTS voiceover, and brand assets.

Usage:
    python build.py --sources "<folder with Scene1..Scene4 .webm>" [--workdir <dir>] [--output <file.mp4>]

The working directory must contain assets/ (icon PNGs) and vo_wav/ (one WAV per plan segment).
See README.md in this folder.
"""
import argparse
import json
import os
import shutil
import subprocess
import wave
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FFMPEG = shutil.which("ffmpeg") or str(next(Path.home().glob(
    "AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg*/ffmpeg-*/bin/ffmpeg.exe")))

PLAN_FILE = Path(__file__).parent / "plan.json"
ROOT = Path(os.environ.get("DEMO_VIDEO_WORKDIR", Path(__file__).parent))
ASSETS = ROOT / "assets"
VO = ROOT / "vo_wav"  # Azure TTS output (raw 24 kHz 16-bit mono PCM) wrapped as WAV
SEGS = ROOT / "segs"
GFX = ROOT / "gfx"
SOURCES = {}  # filled from plan.json "sources" + --sources
OUTPUT = None

W, H, FPS = 1920, 1080, 30
LEAD, TAIL = 0.45, 0.9  # seconds of picture before / after narration in each segment
MAX_FLEX_SPEED = 4.5  # keep UI navigation readable; segments may run longer than their narration
FONT_DIR = Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts"
F_REG = str(FONT_DIR / "segoeui.ttf")
F_SEMI = str(FONT_DIR / "seguisb.ttf")
F_BOLD = str(FONT_DIR / "segoeuib.ttf")

NAVY = (11, 31, 58)
INK = (17, 24, 39)
BAND_TOP, BAND_H = 944, 88  # covers the screen-recorder "sharing your screen" bar (~y 970-1000)


def font(path, size):
    return ImageFont.truetype(path, size)


def icon(name, size):
    im = Image.open(ASSETS / f"{name}.png").convert("RGBA")
    im.thumbnail((size, size), Image.LANCZOS)
    return im


def wav_seconds(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def text_width(draw, text, fnt):
    return draw.textbbox((0, 0), text, font=fnt)[2]


def make_band(seg_id, chip_icon, chip_label, caption):
    """Lower-third: product chip on the left, caption on the right."""
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle([0, BAND_TOP, W, BAND_TOP + BAND_H], fill=(12, 20, 36, 252))
    d.rectangle([0, BAND_TOP, W, BAND_TOP + 4], fill=(0, 120, 212, 255))  # Microsoft blue accent
    f_chip = font(F_SEMI, 28)
    ico = icon(chip_icon, 48)
    chip_w = 24 + ico.width + 14 + text_width(d, chip_label, f_chip) + 26
    cx, cy, ch = 28, BAND_TOP + 16, 60
    d.rounded_rectangle([cx, cy, cx + chip_w, cy + ch], radius=14, fill=(255, 255, 255, 250))
    im.alpha_composite(ico, (cx + 22, cy + (ch - ico.height) // 2))
    d.text((cx + 22 + ico.width + 14, cy + ch // 2), chip_label, font=f_chip, fill=INK, anchor="lm")
    d.text((cx + chip_w + 34, BAND_TOP + BAND_H // 2 + 2), caption, font=font(F_REG, 31), fill=(255, 255, 255), anchor="lm")
    out = GFX / f"band_{seg_id}.png"
    im.save(out)
    return out


def card_background():
    bg = Image.new("RGB", (W, H), NAVY)
    top, bottom = (14, 42, 82), (6, 18, 38)
    px = bg.load()
    for y in range(H):
        t = y / H
        c = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(W):
            px[x, y] = c
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([W - 900, -500, W + 300, 600], fill=(0, 120, 212, 70))
    bg = bg.convert("RGBA")
    bg.alpha_composite(glow.filter(ImageFilter.GaussianBlur(120)))
    return bg


def ms_header(im):
    d = ImageDraw.Draw(im)
    im.alpha_composite(icon("microsoft", 44), (96, 72))
    d.text((152, 94), "Microsoft", font=font(F_SEMI, 34), fill=(255, 255, 255), anchor="lm")


def icon_row(im, names, y, size=96, gap=56):
    total = len(names) * size + (len(names) - 1) * gap
    x = (W - total) // 2
    for n in names:
        ico = icon(n, size)
        im.alpha_composite(ico, (x + (size - ico.width) // 2, y + (size - ico.height) // 2))
        x += size + gap


def make_intro():
    im = card_background()
    ms_header(im)
    d = ImageDraw.Draw(im)
    d.text((W // 2, 380), "Private Microsoft Foundry agents", font=font(F_BOLD, 78), fill=(255, 255, 255), anchor="mm")
    d.text((W // 2, 480), "in Microsoft 365 Copilot and Teams", font=font(F_SEMI, 64), fill=(160, 206, 255), anchor="mm")
    d.text((W // 2, 580), "Proof of concept for Johnson & Johnson", font=font(F_REG, 38), fill=(220, 228, 240), anchor="mm")
    icon_row(im, ["foundry", "vnet", "privatelink", "firewall", "bot", "teams"], 700)
    d.text((W // 2, 900), "Hosted agent  |  VNet injection  |  Private endpoints  |  Governed egress  |  Admin-approved rollout",
           font=font(F_REG, 28), fill=(190, 204, 224), anchor="mm")
    out = GFX / "card_intro.png"
    im.convert("RGB").save(out)
    return out


def make_outro():
    im = card_background()
    ms_header(im)
    d = ImageDraw.Draw(im)
    d.text((W // 2, 250), "Private Foundry agent  >  Microsoft 365 Copilot and Teams", font=font(F_BOLD, 58),
           fill=(255, 255, 255), anchor="mm")
    bullets = [
        ("vnet", "Standard Agent Setup: VNet injection, private endpoints, BYO Cosmos DB, AI Search, Storage"),
        ("firewall", "Governed egress: Azure Firewall FQDN allow-list  |  MCP tool via Foundry toolbox"),
        ("bot", "One filtered Activity Protocol route for Microsoft 365; all other APIs stay private"),
        ("entra", "Microsoft 365 admin approval  |  Entra group-scoped access in Copilot and Teams"),
    ]
    y = 380
    for ic, text in bullets:
        im.alpha_composite(icon(ic, 64), (230, y - 32))
        d.text((330, y), text, font=font(F_REG, 34), fill=(232, 238, 246), anchor="lm")
        y += 110
    pill = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(pill).rounded_rectangle([470, 850, W - 470, 930], radius=40, fill=(255, 255, 255, 28),
                                           outline=(120, 170, 230, 255), width=2)
    im.alpha_composite(pill)
    d = ImageDraw.Draw(im)
    d.text((W // 2, 890), "github.com/AI-GBB-HLS-IP/m365-admin-foundry-copilot", font=font(F_SEMI, 34),
           fill=(255, 255, 255), anchor="mm")
    icon_row(im, ["foundry", "vnet", "firewall", "bot", "teams", "vscode-logo"], 960, size=64, gap=48)
    out = GFX / "card_outro.png"
    im.convert("RGB").save(out)
    return out


def make_scopes_overlay():
    """Dimmed screen with a Shared vs Tenant comparison card."""
    im = Image.new("RGBA", (W, H), (6, 14, 28, 150))
    d = ImageDraw.Draw(im)
    x0, y0, x1, y1 = 140, 150, W - 140, 860
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([x0 + 8, y0 + 14, x1 + 8, y1 + 14], radius=28, fill=(0, 0, 0, 120))
    im.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    d.rounded_rectangle([x0, y0, x1, y1], radius=28, fill=(255, 255, 255, 250))
    d.text((W // 2, y0 + 70), "Two ways to publish a Foundry agent", font=font(F_BOLD, 50), fill=INK, anchor="mm")
    cols = [
        ("Shared", (0, 120, 212), [
            "No admin approval: the developer publishes",
            "Visible only to the publisher (share by link)",
            "Callers need Foundry RBAC (BotServiceRbac)",
            "Best for dev / test and small pilots",
        ]),
        ("Tenant", (16, 124, 16), [
            "Microsoft 365 admin approval required",
            "Admin assigns users, groups, or everyone",
            "Any tenant user with the app (BotServiceTenant)",
            "Best for organization-wide rollout",
        ]),
    ]
    cw = (x1 - x0 - 120) // 2
    max_text = cw - 100
    size = 32
    while size > 22 and max(text_width(d, "\u2022  " + l, font(F_REG, size)) for _, _, ls in cols for l in ls) > max_text:
        size -= 1
    f_line = font(F_REG, size)
    for i, (title, color, lines) in enumerate(cols):
        cx = x0 + 40 + i * (cw + 40)
        d.rounded_rectangle([cx, y0 + 150, cx + cw, y1 - 40], radius=20, fill=(245, 248, 252), outline=color, width=4)
        d.rounded_rectangle([cx, y0 + 150, cx + cw, y0 + 240], radius=20, fill=color)
        d.rectangle([cx, y0 + 210, cx + cw, y0 + 240], fill=color)
        d.text((cx + cw // 2, y0 + 195), title, font=font(F_BOLD, 44), fill=(255, 255, 255), anchor="mm")
        ly = y0 + 310
        for line in lines:
            d.text((cx + 40, ly), "\u2022  " + line, font=f_line, fill=INK, anchor="lm")
            ly += 92
    out = GFX / "overlay_scopes.png"
    im.save(out)
    return out


def run(cmd):
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"ffmpeg failed:\n{' '.join(cmd)}\n{res.stderr[-3000:]}")


def audio_filter(idx, total):
    return (f"[{idx}:a]aresample=48000,pan=stereo|c0=c0|c1=c0,adelay={int(LEAD*1000)}|{int(LEAD*1000)},"
            f"loudnorm=I=-16:TP=-1.5:LRA=11,apad,atrim=0:{total:.3f},asetpts=PTS-STARTPTS[a]")


ENC = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-r", str(FPS),
       "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart"]


def build_card(seg, card_png, out):
    vo = VO / f"{seg['id']}.wav"
    total = wav_seconds(vo) + LEAD + TAIL + 0.6
    fade = f"fade=t=in:st=0:d=0.5,fade=t=out:st={total-0.5:.3f}:d=0.5"
    cmd = [FFMPEG, "-v", "error", "-y", "-loop", "1", "-framerate", str(FPS), "-t", f"{total:.3f}", "-i", str(card_png),
           "-i", str(vo), "-filter_complex",
           f"[0:v]scale={W}:{H},format=yuv420p,{fade}[v];" + audio_filter(1, total),
           "-map", "[v]", "-map", "[a]", "-t", f"{total:.3f}", *ENC, str(out)]
    run(cmd)
    return total


def build_scene(seg, out):
    vo = VO / f"{seg['id']}.wav"
    vo_len = wav_seconds(vo)
    target = vo_len + LEAD + TAIL
    pieces = seg["pieces"]
    fixed = sum((e - s) / sp for s, e, sp in pieces if sp != "flex")
    flex_nat = sum(e - s for s, e, sp in pieces if sp == "flex")
    flex_speed = 1.0
    if flex_nat:
        flex_speed = min(max(flex_nat / max(target - fixed, 2.0), 1.0), MAX_FLEX_SPEED)
    speeds = [flex_speed if sp == "flex" else sp for _, _, sp in pieces]
    natural = sum((e - s) / sp for (s, e, _), sp in zip(pieces, speeds))
    total = max(natural, target)
    pad = total - natural

    inputs, chains = [], []
    for i, ((s, e, _), sp) in enumerate(zip(pieces, speeds)):
        inputs += ["-ss", f"{s:.3f}", "-t", f"{e - s:.3f}", "-i", str(SOURCES[seg["src"]])]
        chains.append(f"[{i}:v]setpts=(PTS-STARTPTS)/{sp:.4f},fps={FPS},scale={W}:{H},setsar=1,format=yuv420p[p{i}]")
    n = len(pieces)
    graph = ";".join(chains) + ";" + "".join(f"[p{i}]" for i in range(n)) + f"concat=n={n}:v=1:a=0[cat];"
    graph += f"[cat]tpad=stop_mode=clone:stop_duration={pad:.3f}[base];"
    k = n
    layer = "base"
    if seg.get("overlay"):
        inputs += ["-loop", "1", "-i", str(GFX / f"overlay_{seg['overlay']}.png")]
        graph += f"[{k}:v]format=rgba,fade=t=in:st=0.3:d=0.6:alpha=1[ov];[{layer}][ov]overlay=0:0:shortest=1[l{k}];"
        layer, k = f"l{k}", k + 1
    band = make_band(seg["id"], seg["chip"][0], seg["chip"][1], seg["caption"])
    inputs += ["-loop", "1", "-i", str(band)]
    graph += f"[{k}:v]format=rgba[band];[{layer}][band]overlay=0:0:shortest=1,"
    graph += f"fade=t=in:st=0:d=0.35,fade=t=out:st={total-0.35:.3f}:d=0.35,format=yuv420p[v];"
    k += 1
    inputs += ["-i", str(vo)]
    graph += audio_filter(k, total)
    cmd = [FFMPEG, "-v", "error", "-y", *inputs, "-filter_complex", graph, "-map", "[v]", "-map", "[a]",
           "-t", f"{total:.3f}", *ENC, str(out)]
    run(cmd)
    return total, speeds


def main():
    global OUTPUT
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sources", required=True, help="Folder containing the scene recordings listed in plan.json")
    parser.add_argument("--output", help="Output MP4 (default: <sources>/<plan output name>)")
    args = parser.parse_args()

    plan = json.loads(PLAN_FILE.read_text(encoding="utf-8"))
    src_dir = Path(args.sources)
    for key, name in plan["sources"].items():
        SOURCES[key] = src_dir / name
        if not SOURCES[key].exists():
            raise SystemExit(f"Missing recording for {key}: {SOURCES[key]}")
    OUTPUT = Path(args.output) if args.output else src_dir / plan["output"]

    GFX.mkdir(exist_ok=True)
    SEGS.mkdir(exist_ok=True)
    cards = {"intro": make_intro(), "outro": make_outro()}
    make_scopes_overlay()
    outs, timeline, t = [], [], 0.0
    for seg in plan["segments"]:
        out = SEGS / f"{seg['id']}.mp4"
        if "card" in seg:
            dur, info = build_card(seg, cards[seg["card"]], out), "card"
        else:
            dur, speeds = build_scene(seg, out)
            info = "speeds " + ", ".join(f"{s:.2f}x" for s in speeds)
        timeline.append(f"{t:7.1f}s  {seg['id']:<20} {dur:6.1f}s  {info}")
        print(timeline[-1], flush=True)
        outs.append(out)
        t += dur
    lst = SEGS / "concat.txt"
    lst.write_text("".join(f"file '{o.as_posix()}'\n" for o in outs), encoding="utf-8")
    run([FFMPEG, "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy",
         "-movflags", "+faststart", str(OUTPUT)])
    (ROOT / "timeline.txt").write_text("\n".join(timeline) + f"\nTOTAL {t:.1f}s\n", encoding="utf-8")
    print(f"TOTAL {t:.1f}s -> {OUTPUT}")


if __name__ == "__main__":
    main()
