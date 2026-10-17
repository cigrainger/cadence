#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build the static Pages site with standard-library Python; no network or npm install."""
from html import escape
from html.parser import HTMLParser
from pathlib import Path
import plistlib
import re
import shutil
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
NAV = [("index", "Guide home"), ("getting-started", "Get started"), ("library", "Your library"),
       ("piano", "Piano & MIDI"), ("guitar", "Guitar"), ("learning", "Learning pathways"),
       ("privacy", "Privacy & AI"), ("troubleshooting", "Troubleshooting"), ("contributing", "Contribute")]


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.ids = set()

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        if "id" in values:
            self.ids.add(values["id"])
        for name in ("href", "src"):
            if name in values:
                self.links.append(values[name])


def check_links(output):
    """Check every internal page/asset and fragment, including project-subpath URLs."""
    parsed = {}
    for path in output.rglob("*.html"):
        parser = Links(); parser.feed(path.read_text()); parsed[path.resolve()] = parser
    for path, parser in parsed.items():
        for link in parser.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            if not target.is_relative_to(output.resolve()):
                raise ValueError(f"Link escapes the site: {path.name}: {link}")
            if target.is_dir():
                target /= "index.html"
            if not target.is_file():
                raise ValueError(f"Missing link: {path.name}: {link}")
            if url.fragment and target in parsed and unquote(url.fragment) not in parsed[target].ids:
                raise ValueError(f"Missing anchor: {path.name}: {link}")
    return len(parsed)


def main():
    output = SITE / "dist"
    if output.is_symlink():
        raise ValueError("Refusing to replace a symlink at site/dist")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir()
    for file in (SITE / "assets").rglob("*"):
        if file.is_symlink():
            raise ValueError("Site assets must not be symlinks")
    shutil.copytree(SITE / "assets", output / "assets")
    version = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
    layout = (SITE / "_layout.html").read_text()
    references = []
    for guide in sorted((ROOT / "Docs/Guides").glob("*.txt")):
        slug = re.sub(r"[^a-z0-9]+", "-", guide.stem.lower()).strip("-")
        references.append((slug, guide))
    reference_links = "".join(f'<li data-reference data-search="{escape(p.read_text(), quote=True)}"><a href="reference/{slug}.html">{escape(p.stem)}</a></li>' for slug, p in references)

    def render(relative, title, description, body, guide=False):
        base = "../" * (len(relative.parts) - 1) or "./"
        if guide:
            selected = relative.stem
            nav = '<aside class="docs-nav" aria-label="Guide sections"><p class="eyebrow">Field guide</p>'
            for slug, label in NAV:
                current = ' aria-current="page"' if selected == slug and len(relative.parts) == 2 else ""
                href = base + "docs/" + ("" if slug == "index" else slug + ".html")
                nav += f'<a href="{href}"{current}>{label}</a>'
            nav += '</aside>'
            body = f'<main id="main" class="docs-shell wrap">{nav}<article class="docs-content">{body}</article></main>'
        page = layout.replace("{{TITLE}}", escape(title)).replace("{{DESCRIPTION}}", escape(description, quote=True))
        page = page.replace("{{BODY}}", body).replace("{{REFERENCES}}", reference_links).replace("{{BASE}}", base).replace("{{VERSION}}", version)
        if "{{" in page:
            raise ValueError(f"Unresolved template in {relative}")
        target = output / relative; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(page)

    for source in (SITE / "pages").rglob("*.html"):
        text = source.read_text()
        metadata = dict(re.findall(r"<!-- (title|description): (.*?) -->", text))
        body = re.sub(r"<!-- (title|description): .*? -->\n?", "", text)
        relative = source.relative_to(SITE / "pages")
        render(relative, metadata["title"], metadata["description"], body, "docs" in relative.parts)
    for slug, guide in references:
        text = guide.read_text()
        body = f'<p class="eyebrow">Detailed feature reference</p><h1>{escape(guide.stem)}</h1><pre class="reference-text">{escape(text)}</pre>'
        render(Path("docs/reference") / (slug + ".html"), guide.stem, "Cadence feature controls and supported behaviour.", body, True)
    (output / ".nojekyll").write_text("")
    print(f"Built {check_links(output)} pages; internal links and anchors passed. Output: {output}")


if __name__ == "__main__":
    main()
