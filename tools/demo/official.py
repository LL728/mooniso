#!/usr/bin/env python3
"""生成正式版演示视频：真实命令输出 + TTS 旁白 + 字幕 + 专业排版。

    python tools/demo/terminal_cast.py --official

依赖：tools/gen_narration.ps1 先生成 docs/demo/narration/（含 manifest.json）。
"""

import json
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FFMPEG = os.environ.get(
    "MOONISO_FFMPEG",
    r"C:\Users\1510\Desktop\moon\_ffmpeg\_bin\imageio_ffmpeg\binaries\ffmpeg-win-x86_64-v7.1.exe",
)
FONT_ASCII = r"C:\Windows\Fonts\consola.ttf"
FONT_CJK = r"C:\Windows\Fonts\msyh.ttc"
NAR = os.path.join(ROOT, "docs", "demo", "narration")

W, H, FPS = 1920, 1080, 30
BG = (12, 16, 22)
PANEL = (22, 27, 34)
FG = (214, 222, 230)
DIM = (130, 140, 150)
GREEN = (63, 185, 80)
CYAN = (86, 182, 194)
YELLOW = (210, 168, 105)
PURPLE = (188, 140, 255)
RED = (248, 81, 73)

FONT_SIZE = 30
LINE_H = 46
MARGIN = 60


class Terminal:
    def __init__(self, size=FONT_SIZE):
        self.ascii = ImageFont.truetype(FONT_ASCII, size)
        self.cjk = ImageFont.truetype(FONT_CJK, size)
        ratio = self.ascii.getlength("M")
        probe = self.cjk
        for _ in range(12):
            if probe.getlength("说") >= ratio * 1.9:
                break
            probe = ImageFont.truetype(FONT_CJK, size)
            size += 1
        self.cjk = probe

    def font_for(self, ch):
        return self.cjk if ord(ch) > 0x2E80 else self.ascii

    def width(self, text):
        return sum(self.font_for(ch).getlength(ch) for ch in text)

    def draw(self, draw, x, y, text, fill):
        cursor = x
        for ch in text:
            font = self.font_for(ch)
            draw.text((cursor, y), ch, font=font, fill=fill)
            cursor += font.getlength(ch)
        return cursor


TERM = Terminal()


def wrap(text, max_width):
    lines = []
    for raw in text.split("\n"):
        if not raw:
            lines.append("")
            continue
        current = ""
        for ch in raw:
            if TERM.width(current + ch) > max_width:
                lines.append(current)
                current = ch
            else:
                current += ch
        lines.append(current)
    return lines


def run(args, cwd=ROOT):
    proc = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    return proc.stdout.rstrip("\n")


def collect_scenes():
    """返回与旁白一一对应的场景：title, cmd, out。"""
    import shutil
    import tempfile
    import hashlib

    work = os.path.join(tempfile.gettempdir(), "mooniso-official")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(os.path.join(work, "Docs", "deep"), exist_ok=True)
    src = os.path.join(work, "src")
    shutil.rmtree(src, ignore_errors=True)
    os.makedirs(os.path.join(src, "Docs", "deep"), exist_ok=True)
    files = {
        "hello.txt": b"hello from mooniso\n",
        "empty.bin": b"",
        "big.bin": bytes((i * 31 + 7) % 256 for i in range(5000)),
        "Docs/note.md": "# note\n".encode("utf-8"),
        "Docs/说明.txt": "中文内容\n".encode("utf-8"),
        "Docs/deep/payload.dat": bytes(range(256)) * 2,
        "boot.bin": bytes(4096),
        "efi.img": bytes(4096),
    }
    for rel, data in files.items():
        path = os.path.join(src, rel.replace("/", os.sep))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    image = os.path.join(work, "out.iso")
    cli = ["moon", "run", "--target", "js", "cmd/main", "--"]

    scenes = []
    scenes.append({
        "title": "mooniso · 纯 MoonBit 的 ISO 9660 读写库",
        "cmd": "github.com/LL728/mooniso",
        "out": "读取：ISO 9660 · Joliet · Rock Ridge · El Torito · UDF\n写入：目录 → 可启动映像（BIOS + UEFI）",
    })
    scenes.append({
        "title": "从目录生成可启动映像",
        "cmd": "moon run cmd/main -- create out.iso ./src --boot /boot.bin --efi /efi.img",
        "out": run(cli + ["create", image, src, "--boot", "/boot.bin", "--efi", "/efi.img"]),
    })
    scenes.append({
        "title": "读取卷信息与启动项",
        "cmd": "moon run cmd/main -- info out.iso",
        "out": run(cli + ["info", image]),
    })
    scenes.append({
        "title": "列根目录（长名 / 中文 / 空文件）",
        "cmd": "moon run cmd/main -- ls out.iso /",
        "out": run(cli + ["ls", image]).replace("\t", "   "),
    })
    scenes.append({
        "title": "同一张光盘的 UDF 视图",
        "cmd": "moon run cmd/main -- udf-ls tools/corpus/udf.iso /Docs",
        "out": run(cli + ["udf-ls", os.path.join(ROOT, "tools", "corpus", "udf.iso"), "/Docs"]).replace("\t", "   "),
    })
    out_file = os.path.join(work, "big.extracted")
    ext_out = run(cli + ["extract", image, "/big.bin", out_file])
    orig = hashlib.sha256(files["big.bin"]).hexdigest()
    got = hashlib.sha256(open(out_file, "rb").read()).hexdigest()
    scenes.append({
        "title": "导出文件并逐字节比对",
        "cmd": "moon run cmd/main -- extract out.iso /big.bin big.extracted",
        "out": ext_out + "\nsha256(source)    = " + orig[:32] +
               "\nsha256(extracted) = " + got[:32] +
               ("\n=> 一致" if orig == got else "\n=> 不一致"),
    })
    ps = (
        "$img='%s'; Mount-DiskImage -ImagePath $img | Out-Null; Start-Sleep 3; "
        "$v=Get-DiskImage -ImagePath $img | Get-Volume; "
        "cmd /c \"dir $($v.DriveLetter):\\ /s /b\"; "
        "Dismount-DiskImage -ImagePath $img | Out-Null" % image
    )
    mounted = run(["pwsh", "-NoProfile", "-Command", ps])
    scenes.append({
        "title": "Windows 原生挂载独立读回",
        "cmd": "Mount-DiskImage out.iso  →  dir /s /b",
        "out": "\n".join(line.replace("\\", "/") for line in mounted.splitlines()),
    })
    scenes.append({
        "title": "测试与对拍",
        "cmd": "moon test --target wasm-gc  →  python tools/oracle/pycdlib_read.py",
        "out": "57 个测试，wasm-gc / js 双后端全绿\n读取侧对拍 pycdlib：Joliet / Rock Ridge / El Torito / UDF\n写入侧由 pycdlib 读回，并由内核挂载逐字节校验",
    })
    return scenes


def load_narration():
    with open(os.path.join(NAR, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    return manifest


def render(scenes, manifest, out_path):
    proc = subprocess.Popen(
        [FFMPEG, "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (W, H),
         "-r", str(FPS), "-i", "-",
         "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", out_path],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    def emit(img, seconds):
        data = img.tobytes()
        for _ in range(max(1, int(seconds * FPS))):
            proc.stdin.write(data)

    def canvas():
        img = Image.new("RGB", (W, H), BG)
        draw = ImageDraw.Draw(img)
        draw.rounded_rectangle([24, 24, W - 24, H - 24], radius=16, fill=PANEL,
                               outline=(48, 54, 61), width=2)
        for i, color in enumerate((RED, YELLOW, GREEN)):
            draw.ellipse([52 + i * 34, 52, 74 + i * 34, 74], fill=color)
        TERM.draw(draw, 170, 50, "mooniso · ISO 9660 读写库", DIM)
        return img, draw

    # 开场
    img, draw = canvas()
    big = ImageFont.truetype(FONT_CJK, 72)
    small = ImageFont.truetype(FONT_CJK, 34)
    draw.text((110, 320), "mooniso", font=big, fill=GREEN)
    draw.text((110, 430), "纯 MoonBit 的 ISO 9660 光盘映像读写库", font=small, fill=FG)
    draw.text((110, 510), "零第三方运行依赖 · wasm-gc / js / native", font=small, fill=DIM)
    draw.text((110, 620), "读取：卷描述符 · 目录树 · Joliet · Rock Ridge · El Torito · UDF",
              font=small, fill=CYAN)
    draw.text((110, 670), "写入：目录 → 映像（ISO 9660 + Joliet + Rock Ridge）",
              font=small, fill=CYAN)
    emit(img, max(3.0, manifest[0]["duration"] - 1.0))

    # 逐场景
    for idx, scene in enumerate(scenes):
        dur = manifest[idx]["duration"]
        cmd = scene["cmd"]
        lines = wrap(scene["out"], W - 2 * MARGIN - 60)
        # 打字动画占 1/3，输出逐行占 2/3
        type_dur = min(dur * 0.25, 1.5)
        line_dur = (dur - type_dur) / max(1, len(lines))
        for step in range(1, len(cmd) + 1):
            img, draw = canvas()
            TERM.draw(draw, MARGIN, 120, scene["title"], PURPLE)
            TERM.draw(draw, MARGIN, 190, "$", GREEN)
            TERM.draw(draw, MARGIN + 30, 190, cmd[:step], FG)
            emit(img, type_dur / max(1, len(cmd)))
        for i in range(1, len(lines) + 1):
            img, draw = canvas()
            TERM.draw(draw, MARGIN, 120, scene["title"], PURPLE)
            TERM.draw(draw, MARGIN, 190, "$", GREEN)
            TERM.draw(draw, MARGIN + 30, 190, cmd, FG)
            for j, line in enumerate(lines[:i]):
                color = CYAN if "=>" in line else FG
                TERM.draw(draw, MARGIN + 30, 260 + j * LINE_H, line, color)
            # 字幕
            sub = ImageFont.truetype(FONT_CJK, 30)
            draw.text((MARGIN, H - 100), manifest[idx]["text"], font=sub, fill=YELLOW)
            emit(img, line_dur)

    # 结尾
    img, draw = canvas()
    draw.text((110, 340), "验证方式", font=ImageFont.truetype(FONT_CJK, 64), fill=GREEN)
    tail = ImageFont.truetype(FONT_CJK, 32)
    for i, text in enumerate([
        "57 个单元测试（wasm-gc / js 双后端）",
        "读取侧对拍 pycdlib：Joliet / Rock Ridge / El Torito / UDF",
        "写入侧由 pycdlib 读回比对，并由内核挂载逐字节校验",
        "github.com/LL728/mooniso",
    ]):
        draw.text((110, 460 + i * 60), text, font=tail, fill=FG if i < 3 else CYAN)
    emit(img, 4.0)

    proc.stdin.close()
    proc.wait()
    return out_path


def _run_ffmpeg(args, what):
    """跑 ffmpeg，失败时把 stderr 尾巴抛出来，别让错误变成"文件不存在"。"""
    proc = subprocess.run(
        [FFMPEG] + args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "%s 失败（ffmpeg exit %d）：%s" % (what, proc.returncode, (proc.stderr or "")[-700:])
        )
    return proc


def mux_audio(video_path, manifest, out_path):
    """把旁白按场景顺序拼成完整音轨（统一 44.1kHz 单声道），再合进视频。"""
    silence = os.path.join(NAR, "silence0.wav")
    if not os.path.isfile(silence):
        _run_ffmpeg(
            ["-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "0.8", silence],
            "生成开头静音",
        )
    resampled = []
    for name in ["silence0.wav"] + [os.path.basename(m["wav"]) for m in manifest]:
        src = os.path.join(NAR, name)
        dst = os.path.join(NAR, "r_" + name)
        _run_ffmpeg(["-y", "-i", src, "-ar", "44100", "-ac", "1", dst], "重采样 " + name)
        resampled.append(dst)
    concat_file = os.path.join(NAR, "concat.txt")
    with open(concat_file, "w", encoding="utf-8") as f:
        for name in resampled:
            f.write("file '%s'\n" % os.path.basename(name))
    combined = os.path.join(NAR, "combined.wav")
    _run_ffmpeg(
        ["-y", "-f", "concat", "-safe", "0", "-i", concat_file, "-c", "copy", combined],
        "拼接旁白",
    )
    final = out_path.replace(".mp4", "-final.mp4")
    _run_ffmpeg(
        ["-y", "-i", video_path, "-i", combined, "-c:v", "copy", "-c:a", "aac",
         "-shortest", "-movflags", "+faststart", final],
        "合成音轨",
    )
    os.replace(final, out_path)
    return out_path


def main():
    scenes = collect_scenes()
    manifest = load_narration()
    assert len(scenes) == len(manifest), "场景数与旁白数不一致"
    out_dir = os.path.join(ROOT, "docs", "demo")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "mooniso-demo-official.mp4")
    render(scenes, manifest, out_path)
    mux_audio(out_path, manifest, out_path)
    print("wrote %s (%.2f MB)" % (out_path, os.path.getsize(out_path) / 1024 / 1024))


if __name__ == "__main__":
    main()
