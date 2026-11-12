#!/usr/bin/env python3
"""生成演示视频：真实执行 mooniso 的命令，把实际输出渲染成终端动画（MP4）。

    python tools/demo/terminal_cast.py

不依赖录屏：命令是真的跑、输出是真的抓，只是把它们渲染成逐帧动画后用 ffmpeg 编码。
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def _resolve_ffmpeg():
    """优先 MOONISO_FFMPEG，其次 PATH；都不行就交给 subprocess 报错，不写死本机路径。"""
    env = os.environ.get("MOONISO_FFMPEG")
    if env and os.path.isfile(env):
        return env
    found = shutil.which("ffmpeg") or shutil.which("ffmpeg.exe")
    return found or "ffmpeg"


FFMPEG = _resolve_ffmpeg()
_WINDIR = os.environ.get("WINDIR", r"C:\Windows")
FONT_ASCII = os.path.join(_WINDIR, "Fonts", "consola.ttf")
FONT_CJK = os.path.join(_WINDIR, "Fonts", "msyh.ttc")

W, H, FPS = 1600, 900, 30
BG = (13, 17, 23)
PANEL = (22, 27, 34)
FG = (201, 209, 217)
DIM = (139, 148, 158)
GREEN = (63, 185, 80)
CYAN = (86, 182, 194)
YELLOW = (210, 168, 105)
PURPLE = (188, 140, 255)
RED = (248, 81, 73)

FONT_SIZE = 26
LINE_H = 40
MARGIN = 40


def run(args, cwd=ROOT):
    proc = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    return proc.stdout.rstrip("\n"), proc.returncode


class Terminal:
    """等宽 + CJK 回退的终端文字渲染。"""

    def __init__(self, size=FONT_SIZE):
        self.ascii = ImageFont.truetype(FONT_ASCII, size)
        self.size = size
        probe = ImageFont.truetype(FONT_CJK, size)
        # 让 CJK 字宽约等于两个 ASCII 字宽，保证列对齐
        ratio = self.ascii.getlength("M")
        cjk_w = probe.getlength("说")
        cjk_size = size
        for _ in range(12):
            if cjk_w >= ratio * 1.9:
                break
            cjk_size += 1
            probe = ImageFont.truetype(FONT_CJK, cjk_size)
            cjk_w = probe.getlength("说")
        self.cjk = probe

    def font_for(self, ch):
        return self.cjk if ord(ch) > 0x2E80 else self.ascii

    def width(self, text):
        total = 0.0
        for ch in text:
            total += self.font_for(ch).getlength(ch)
        return total

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


def capture_demo():
    """真实执行一遍演示流程，返回 (场景列表, 统计数据)。"""
    work = os.path.join(tempfile.gettempdir(), "mooniso-demo")
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
    }
    for rel, data in files.items():
        path = os.path.join(src, rel.replace("/", os.sep))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    image = os.path.join(work, "out.iso")
    cli = ["moon", "run", "--target", "js", "cmd/main", "--"]

    scenes = []
    scenes.append({"title": "从目录生成可启动 ISO 9660 映像",
                   "cmd": "moon run cmd/main -- create out.iso ./src --boot /boot.bin",
                   "out": run(cli + ["create", image, src, "--boot", "/boot.bin"])[0]})
    scenes.append({"title": "读取卷信息（含 El Torito 启动项检测）",
                   "cmd": "moon run cmd/main -- info out.iso",
                   "out": run(cli + ["info", image])[0]})
    scenes.append({"title": "列根目录：长名、中文名、空文件",
                   "cmd": "moon run cmd/main -- ls out.iso /",
                   "out": run(cli + ["ls", image])[0].replace("\t", "   ")})
    scenes.append({"title": "进入子目录（Joliet / Rock Ridge 名字）",
                   "cmd": "moon run cmd/main -- ls out.iso /Docs",
                   "out": run(cli + ["ls", image, "/Docs"])[0].replace("\t", "   ")})
    scenes.append({"title": "读文件内容",
                   "cmd": "moon run cmd/main -- cat out.iso /hello.txt",
                   "out": run(cli + ["cat", image, "/hello.txt"])[0]})

    out_file = os.path.join(work, "big.extracted")
    extract_out = run(cli + ["extract", image, "/big.bin", out_file])[0]
    original = hashlib.sha256(files["big.bin"]).hexdigest()
    extracted = hashlib.sha256(open(out_file, "rb").read()).hexdigest()
    scenes.append({
        "title": "导出文件并与源文件逐字节比对",
        "cmd": "moon run cmd/main -- extract out.iso /big.bin big.extracted",
        "out": extract_out + "\n" + "sha256(source)    = " + original[:32] +
               "\nsha256(extracted) = " + extracted[:32] +
               ("\n=> 一致" if original == extracted else "\n=> 不一致"),
    })

    udf_fixture = os.path.join(ROOT, "tools", "corpus", "udf.iso")
    if os.path.isfile(udf_fixture):
        scenes.append({
            "title": "同一张映像的另一面：UDF（ECMA-167）读取",
            "cmd": "moon run cmd/main -- udf-ls tools/corpus/udf.iso /Docs",
            "out": run(cli + ["udf-ls", udf_fixture, "/Docs"])[0].replace("\t", "   "),
        })

    ps = (
        "$img = '%s'; Mount-DiskImage -ImagePath $img | Out-Null; Start-Sleep 3; "
        "$v = Get-DiskImage -ImagePath $img | Get-Volume; "
        "cmd /c \"dir $($v.DriveLetter):\\ /s /b\"; "
        "Dismount-DiskImage -ImagePath $img | Out-Null" % image
    )
    mounted, _ = run(["pwsh", "-NoProfile", "-Command", ps])
    mounted = "\n".join(line.replace("\\", "/") for line in mounted.splitlines())
    scenes.append({"title": "生成的映像被 Windows 原生挂载（独立实现读回）",
                   "cmd": "Mount-DiskImage out.iso  →  dir /s /b",
                   "out": mounted})
    return scenes, len(files)


def render(scenes, stats, out_path):
    total_out_lines = sum(len(scene["out"].split("\n")) for scene in scenes)
    proc = subprocess.Popen(
        [FFMPEG, "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (W, H),
         "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "21",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", out_path],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    def emit(img, seconds):
        data = img.tobytes()
        for _ in range(max(1, int(seconds * FPS))):
            proc.stdin.write(data)

    def base_canvas():
        img = Image.new("RGB", (W, H), BG)
        draw = ImageDraw.Draw(img)
        draw.rounded_rectangle([20, 20, W - 20, H - 20], radius=14, fill=PANEL,
                               outline=(48, 54, 61), width=2)
        for i, color in enumerate((RED, YELLOW, GREEN)):
            draw.ellipse([44 + i * 30, 44, 64 + i * 30, 64], fill=color)
        TERM.draw(draw, 150, 42, "mooniso  ·  ISO 9660 读写库", DIM)
        return img, draw

    # 开场
    img, draw = base_canvas()
    big = ImageFont.truetype(FONT_CJK, 64)
    small = ImageFont.truetype(FONT_CJK, 30)
    draw.text((110, 300), "mooniso", font=big, fill=GREEN)
    draw.text((110, 400), "纯 MoonBit 的 ISO 9660 光盘映像读写库", font=small, fill=FG)
    draw.text((110, 470), "零第三方运行依赖 · wasm-gc / js / native", font=small, fill=DIM)
    draw.text((110, 560), "读取：卷描述符 / 目录树 / Joliet / Rock Ridge / El Torito / 多段文件",
              font=small, fill=CYAN)
    draw.text((110, 610), "写入：从目录生成映像（ISO 9660 + Joliet + Rock Ridge）",
              font=small, fill=CYAN)
    emit(img, 4.0)

    for scene in scenes:
        lines = wrap(scene["out"], W - 2 * MARGIN - 60)
        # 命令行：先打标题，再逐字敲出
        cmd = scene["cmd"]
        for step in range(1, len(cmd) + 1):
            img, draw = base_canvas()
            TERM.draw(draw, MARGIN, 110, scene["title"], PURPLE)
            TERM.draw(draw, MARGIN, 170, "$", GREEN)
            TERM.draw(draw, MARGIN + 26, 170, cmd[:step], FG)
            emit(img, 0.03)
        # 输出逐行出现
        for i in range(1, len(lines) + 1):
            img, draw = base_canvas()
            TERM.draw(draw, MARGIN, 110, scene["title"], PURPLE)
            TERM.draw(draw, MARGIN, 170, "$", GREEN)
            TERM.draw(draw, MARGIN + 26, 170, cmd, FG)
            for j, line in enumerate(lines[:i]):
                color = CYAN if "=>" in line else FG
                TERM.draw(draw, MARGIN + 26, 230 + j * LINE_H, line, color)
            emit(img, 0.12)
        # 停留
        img, draw = base_canvas()
        TERM.draw(draw, MARGIN, 110, scene["title"], PURPLE)
        TERM.draw(draw, MARGIN, 170, "$", GREEN)
        TERM.draw(draw, MARGIN + 26, 170, cmd, FG)
        for j, line in enumerate(lines):
            color = CYAN if "=>" in line else FG
            TERM.draw(draw, MARGIN + 26, 230 + j * LINE_H, line, color)
        emit(img, 2.2)

    # 结尾
    img, draw = base_canvas()
    draw.text((110, 300), "验证方式", font=big, fill=GREEN)
    tail = ImageFont.truetype(FONT_CJK, 30)
    for i, text in enumerate([
        "57 个单元测试（wasm-gc / js 双后端）",
        "读取侧对拍 pycdlib：Joliet / Rock Ridge / El Torito",
        "写入侧由 pycdlib 读回比对，并由系统挂载逐字节校验",
        "github.com/LL728/mooniso",
    ]):
        draw.text((110, 400 + i * 60), text, font=tail, fill=FG if i < 3 else CYAN)
    emit(img, 5.0)

    proc.stdin.close()
    proc.wait()
    return total_out_lines


def write_poster(scenes, out_dir):
    """用第一幕的内容做一张封面图。"""
    scene = scenes[1]
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([20, 20, W - 20, H - 20], radius=14, fill=PANEL,
                           outline=(48, 54, 61), width=2)
    for i, color in enumerate((RED, YELLOW, GREEN)):
        draw.ellipse([44 + i * 30, 44, 64 + i * 30, 64], fill=color)
    TERM.draw(draw, 150, 42, "mooniso  ·  ISO 9660 读写库", DIM)
    TERM.draw(draw, MARGIN, 110, scene["title"], PURPLE)
    TERM.draw(draw, MARGIN, 170, "$", GREEN)
    TERM.draw(draw, MARGIN + 26, 170, scene["cmd"], FG)
    for j, line in enumerate(wrap(scene["out"], W - 2 * MARGIN - 60)):
        TERM.draw(draw, MARGIN + 26, 230 + j * LINE_H, line, FG)
    img.save(os.path.join(out_dir, "poster.png"))
    return os.path.join(out_dir, "poster.png")


def main():
    scenes, file_count = capture_demo()
    out_dir = os.path.join(ROOT, "docs", "demo")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "mooniso-demo.mp4")
    render(scenes, file_count, out_path)
    poster = write_poster(scenes, out_dir)
    print("wrote %s" % poster)
    print("wrote %s (%.2f MB)" % (out_path, os.path.getsize(out_path) / 1024 / 1024))
    print("scenes: %d" % (len(scenes) + 2))


if __name__ == "__main__":
    main()
