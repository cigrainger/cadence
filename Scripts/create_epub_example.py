"""Create an original, offline EPUB fixture; no commercial book content."""
from pathlib import Path
from zipfile import ZipFile
from io import BytesIO
from PIL import Image, ImageDraw

base = Path(__file__).resolve().parents[1] / "Resources/ImportExamples"
image = Image.new("RGB", (550, 140), "white")
draw = ImageDraw.Draw(image)
for i in range(14):
    x = 10 + i * 38
    draw.rectangle((x, 10, x + 38, 110), outline="#354e43", width=2)
    if i in (0, 2, 4):
        draw.ellipse((x + 12, 82, x + 26, 96), fill="#416c59")
draw.text((14, 120), "Cadence original: C major, root position", fill="black")
buffer = BytesIO()
image.save(buffer, format="PNG")
sections = [
    ("inversions", "THREE CHORDS FROM ONE - INVERSIONS", "A triad keeps its chord tones when you change their order. Compare C E G, E G C and G C E. Listen for what changes, then play each shape slowly."),
    ("writing", "SECTION 3 - Write a phrase", "Choose three chords. Find nearby shapes. Give your phrase a rhythm and listen for the movement of the top note."),
    ("application", "Make it your own", "Write four bars. Listen back and describe one musical choice you made."),
]
with ZipFile(base / "pathway.epub", "w") as archive:
    archive.writestr("mimetype", "application/epub+zip")
    archive.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="Book/package.opf"/></rootfiles></container>')
    manifest = "".join(f'<item id="{i}" href="{i}.xhtml" media-type="application/xhtml+xml"/>' for i, _, _ in sections)
    spine = "".join(f'<itemref idref="{i}"/>' for i, _, _ in sections)
    archive.writestr("Book/package.opf", f'<package version="3.0"><metadata><title>Cadence: chord shapes and a phrase</title><creator>Cadence original example</creator></metadata><manifest>{manifest}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="image" href="keys.png" media-type="image/png"/></manifest><spine>{spine}</spine></package>')
    archive.writestr("Book/nav.xhtml", '<html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>' + "".join(f'<li><a href="{i}.xhtml">{title}</a></li>' for i, title, _ in sections) + '</ol></nav></body></html>')
    for i, title, text in sections:
        archive.writestr(f"Book/{i}.xhtml", f'<html><body><h1>{title}</h1><p>{text}</p><img src="keys.png" alt="C major keyboard diagram"/><p>This is an original fixture for Cadence. It contains no commercial book content.</p></body></html>')
    archive.writestr("Book/keys.png", buffer.getvalue())
