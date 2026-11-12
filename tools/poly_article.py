#!/usr/bin/env python3
"""Fetch a story from poly.rpi.edu and write it in the labelled form Typeset's Paste Article reads.

    tools/poly_article.py <url>          # print it
    tools/poly_article.py --copy <url>   # put it on the clipboard (as rich text, so italics survive), then ⇧⌘V

Fields: Author, Author Title, Title, Kicker, Section, Summary, Article. Photos and captions are left out.
"""
import html
import json
import re
import subprocess
import sys
import urllib.request
from html.parser import HTMLParser


class ArticlePage(HTMLParser):
    """Pulls the kicker, headline, summary, byline titles and body paragraphs out of a story page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []           # (tag, classes) of open elements
        self.kicker = self.headline = self.summary = ""
        self.titles = []          # byline titles, one per author
        self.paragraphs = []      # body paragraphs as small HTML (<em>, <strong> kept)
        self.capture = None       # which field the current text goes to
        self.capture_depth = 0    # stack depth of the element being captured
        self.buf = ""
        self.in_body = 0          # depth of the article-body div, 0 outside it

    def classes(self, attrs):
        return (dict(attrs).get("class") or "").split()

    def handle_startendtag(self, tag, attrs):
        pass                      # <img/>, <path/>: nothing to capture, and nothing to close

    def handle_starttag(self, tag, attrs):
        cls = self.classes(attrs)
        if tag in ("br", "img", "meta", "link", "input", "hr", "source"):
            return
        self.stack.append((tag, cls))
        if tag == "div" and "article-body" in cls:
            self.in_body = len(self.stack)
        if self.capture is None:
            if tag == "span" and "text-accent" in cls and "uppercase" in cls and not self.kicker:
                self.capture, self.buf = "kicker", ""
            elif tag == "h1" and not self.headline:
                self.capture, self.buf = "headline", ""
            elif tag == "h2" and "text-text-muted" in cls and not self.summary:
                self.capture, self.buf = "summary", ""
            elif tag == "p" and "italic" in cls and "text-text-main" in cls and not self.in_body:
                self.capture, self.buf = "title", ""
            elif tag == "p" and "font-copy" in cls and self.in_body:
                self.capture, self.buf = "para", ""
            if self.capture:
                self.capture_depth = len(self.stack)
        elif self.capture == "para" and tag in ("em", "i", "strong", "b"):
            self.buf += "<%s>" % {"i": "em", "b": "strong"}.get(tag, tag)

    def handle_endtag(self, tag):
        if not self.stack:
            return
        depth = len(self.stack)
        self.stack.pop()
        if self.in_body and depth == self.in_body:
            self.in_body = 0
        if self.capture == "para" and tag in ("em", "i", "strong", "b"):
            self.buf += "</%s>" % {"i": "em", "b": "strong"}.get(tag, tag)
            return
        if self.capture and depth == self.capture_depth:
            text = re.sub(r"\s+", " ", self.buf).strip()
            if text:
                if self.capture == "para":
                    self.paragraphs.append(re.sub(r"<(em|strong)>\s*</\1>", "", text))
                elif self.capture == "title":
                    self.titles.append(html.unescape(text))
                else:
                    setattr(self, self.capture, html.unescape(text))
            self.capture = None

    def handle_data(self, data):
        if self.capture:
            self.buf += html.escape(data, quote=False) if self.capture == "para" else data


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Typeset)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def news_article(page):
    for m in re.finditer(r'<script type="application/ld\+json">(.*?)</script>', page, re.S):
        try:
            d = json.loads(m.group(1))
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("@type") in ("NewsArticle", "Article", "OpinionNewsArticle"):
            return d
    return {}


def kicker_case(s):
    # the page sets the kicker in capitals with CSS; the text itself is usually already in title case
    return s.title() if s.isupper() else s


def labelled(url):
    page = fetch(url)
    p = ArticlePage()
    p.feed(page)
    meta = news_article(page)
    authors = [a.get("name", "") for a in meta.get("author", []) if isinstance(a, dict)] if isinstance(meta.get("author"), list) else []
    if not authors:
        m = re.search(r'<meta name="author" content="([^"]*)"', page)
        authors = [html.unescape(m.group(1))] if m else []
    titles = list(dict.fromkeys(p.titles[: len(authors) or None]))
    section = meta.get("articleSection", "")
    head = [
        ("Author", ", ".join(authors)),
        ("Author Title", titles[0] if len(titles) == 1 else ""),
        ("Title", p.headline or meta.get("headline", "")),
        ("Kicker", kicker_case(p.kicker)),
        ("Section", section),
        ("Summary", p.summary or meta.get("description", "")),
    ]
    head = [(k, v) for k, v in head if v]
    return head, p.paragraphs


def plain(fragment):
    return html.unescape(re.sub(r"<[^>]+>", "", fragment))


def main(argv):
    copy = "--copy" in argv
    urls = [a for a in argv if not a.startswith("--")]
    if len(urls) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    head, paras = labelled(urls[0])
    if not paras:
        print("no article body found on that page", file=sys.stderr)
        return 1
    text = "\n".join(f"{k}: {v}" for k, v in head) + "\nArticle:\n" + "\n".join(plain(x) for x in paras) + "\n"
    if not copy:
        sys.stdout.write(text)
        return 0
    doc = "".join(f"<p>{html.escape(k)}: {html.escape(v)}</p>" for k, v in head) + "<p>Article:</p>"
    doc = '<html><head><meta charset="utf-8"></head><body>' + doc + "".join(f"<p>{x}</p>" for x in paras) + "</body></html>"
    rtf = subprocess.run(["textutil", "-convert", "rtf", "-format", "html", "-stdin", "-stdout"],
                         input=doc.encode(), capture_output=True, check=True).stdout
    subprocess.run(["pbcopy"], input=rtf, check=True)
    print("\n".join(f"{k}: {v}" for k, v in head if k != "Summary"))
    print(f"Article: {len(paras)} paragraphs — on the clipboard; press ⇧⌘V in Typeset")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
