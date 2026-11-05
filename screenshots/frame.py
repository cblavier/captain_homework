"""Add the documentation frame to the original PNGs (requires ImageMagick)."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
out = root / 'alice'
out.mkdir(exist_ok=True)
for source in sorted((root / 'originaux/alice').glob('*.png')):
    width, height = map(int, subprocess.check_output(
        ['magick', 'identify', '-format', '%w %h', str(source)], text=True).split())
    margin, top, radius = (20, 48, 12) if width < 600 else (32, 40, 12)
    with tempfile.TemporaryDirectory() as temp:
        rounded = Path(temp) / 'rounded.png'
        subprocess.run(['magick', str(source), '(', '-size', f'{width}x{height}',
            'xc:none', '-fill', 'white', '-draw',
            f'roundrectangle 0,0 {width-1},{height-1} {radius},{radius}', ')',
            '-alpha', 'off', '-compose', 'CopyOpacity', '-composite',
            '-fill', 'none', '-stroke', '#d5d9df', '-strokewidth', '1',
            '-draw', f'roundrectangle 0,0 {width-1},{height-1} {radius},{radius}',
            str(rounded)], check=True)
        subprocess.run(['magick', '-size', f'{width+2*margin}x{height+2*top}', 'xc:white',
            '(', str(rounded), '-background', '#263449', '-shadow', '12x10+0+5', ')',
            '-gravity', 'center', '-compose', 'over', '-composite',
            str(rounded), '-gravity', 'center', '-composite', '-strip',
            str(out / source.name)], check=True)
