"""Generate Typeset's bundled resources: seed issue, staff list, fonts, seed images, app icon.
Run once (needs Pillow + fontTools); the outputs are committed in app/Resources so the app builds with Swift alone."""
import json, os, re, shutil, sys, uuid, subprocess, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))       # septabloid2/
APP = os.path.join(ROOT, "app")
RES = os.path.join(APP, "Resources")
FONTS_REAL = os.path.join(ROOT, "repro", "fonts-real")

FONTS = {  # PostScript name -> source file (static Raleway only; the variable instances share one PostScript name)
    "MinionPro-Regular": "normalized/MinionPro-Regular.otf",
    "MinionPro-It": "minion-pro/MinionPro-It.otf",
    "MinionPro-Medium": "minion-pro/MinionPro-Medium.otf",
    "MinionPro-Bold": "minion-pro/MinionPro-Bold.otf",
    "MinionPro-BoldIt": "minion-pro/MinionPro-BoldIt.otf",
    "UtopiaStd-SemiboldSubh": "normalized/Utopia Std Semibold Subhead.otf",
    "UtopiaStd-BoldIt": "utopia-std/Utopia-Std-Bold-Italic-BoldItalic.otf",
    "Raleway": "raleway/user/Raleway Regular.ttf",
    "Raleway-Medium": "raleway/google-static/Raleway-Medium.ttf",
    "Raleway-SemiBold": "raleway/google-static/Raleway-SemiBold.ttf",
    "MyriadPro-Regular": "myriad-pro/MYRIADPRO-REGULAR.OTF",
    "MyriadPro-It": "myriad-pro-2/Myriad Pro Italic.ttf",
}

def fonts():
    d = os.path.join(RES, "Fonts"); os.makedirs(d, exist_ok=True)
    for ps, rel in FONTS.items():
        src = os.path.join(FONTS_REAL, rel)
        shutil.copy(src, os.path.join(d, ps + os.path.splitext(src)[1].lower()))

def raleway_bold():
    """The paper sets folios and jump lines in Raleway at weight 700, an instance of the variable font.
    Cut a static instance with its own names so it registers beside the static weights."""
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
    vf = TTFont(os.path.join(FONTS_REAL, "raleway/google/Raleway[wght].ttf"))
    f = instancer.instantiateVariableFont(vf, {"wght": 700})
    names = {1: "Raleway Bold", 2: "Regular", 4: "Raleway Bold", 6: "Raleway-Bold", 16: "Raleway", 17: "Bold"}
    for rec in list(f["name"].names):
        if rec.nameID in names or rec.nameID in (3, 25): f["name"].removeNames(nameID=rec.nameID)
    for nid, val in names.items(): f["name"].setName(val, nid, 3, 1, 0x409)
    f["name"].setName("Raleway-Bold-Galley", 3, 3, 1, 0x409)
    f["OS/2"].usWeightClass = 700
    f.save(os.path.join(RES, "Fonts", "Raleway-Bold.ttf"))

def nameplate():
    """Crop the nameplate art (a placed SVG in the InDesign file) out of the printed PDF as vector art.
    The issue date printed on its black bar is removed; the app sets each issue's date itself."""
    import pymupdf
    src = pymupdf.open(PDF)
    page = src[0]
    clip = pymupdf.Rect(*NAMEPLATE)
    page.add_redact_annot(pymupdf.Rect(530, 222.4, 758, 238.4), fill=(0.1367, 0.122, 0.1253))
    # drop the photos and type around the nameplate so they don't ride along in the cropped file
    W, H = page.rect.width, page.rect.height
    for r in ((0, 0, W, clip.y0), (0, clip.y1, W, H), (0, 0, clip.x0, H), (clip.x1, 0, W, H)):
        page.add_redact_annot(pymupdf.Rect(*r), fill=False)
    page.apply_redactions(images=pymupdf.PDF_REDACT_IMAGE_REMOVE, graphics=pymupdf.PDF_REDACT_LINE_ART_NONE)
    out = pymupdf.open()
    dst = out.new_page(width=clip.width, height=clip.height)
    dst.show_pdf_page(dst.rect, src, 0, clip=clip)
    out.save(os.path.join(RES, "nameplate.pdf"), garbage=4, deflate=True)

PDF = os.path.expanduser("~/Downloads/septabloid2_FINAL.pdf")
NAMEPLATE = (37.7, 129.1, 766.7, 246.7)   # x0, y0, x1, y1 on page 1, from the IDML

# "### Continued on Page 7" lines are where the printed issue jumped, not part of the stories
JUMP_ARTIFACT = re.compile(r"^#{1,6}\s*Continued (on|from) Page \d+\.?$")
JUMP_LEAD = re.compile(r"^\*?Continued from Page \d+\.\*?\s*")

def seed():
    arts = json.load(open(os.path.join(ROOT, "articles.json")))
    media = os.path.join(RES, "SeedMedia"); os.makedirs(media, exist_ok=True)
    out = []
    for a in arts:
        photos = []
        for img in a.get("images") or []:
            src = os.path.join(ROOT, "images", img["file"])
            if os.path.exists(src):
                shutil.copy(src, os.path.join(media, img["file"]))
                photos.append({"id": str(uuid.uuid5(uuid.NAMESPACE_URL, "polytechnic/photo/" + img["file"])).upper(),
                               "path": "seed:" + img["file"], "caption": img["caption"], "credit": img["credit"]})
        out.append({
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, "polytechnic/2026-09-30/" + a["slug"])).upper(),
            "desk": a["section"], "headline": a["headline"],
            "author": a.get("author", ""), "authorTitle": a.get("author_title", ""),
            "body": [JUMP_LEAD.sub("", b) for b in a["body"] if not JUMP_ARTIFACT.match(b)], "pullQuote": (a.get("pull_quotes") or [""])[0],
            "photos": photos, "updated": "2026-09-30T12:00:00Z",
        })
    issue = {"publication": "The Polytechnic", "volume": "CXLIV", "edition": "III", "date": "2026-09-30T12:00:00Z", "articles": out}
    json.dump(issue, open(os.path.join(RES, "seed-issue.json"), "w"), indent=1, ensure_ascii=False)

def staff():
    md = open(os.path.join(ROOT, "staff-box.md")).read()
    people = []                      # the editor in chief, if the staff box leaves them out, goes in by hand
    for role, name, email in re.findall(r"^\| ([^|]+?) \| ([^|]+?) \| ([^|]+?) \|$", md, re.M):
        if role in ("Role", "---"): continue
        people.append({"name": name, "role": role})
    json.dump(people, open(os.path.join(RES, "staff.json"), "w"), indent=1)

def icon():
    """II, for Typeset 2: the app's icon in the manner of Adobe's app tiles. A black rounded square at their
    proportions (corner radius 18% of the tile) and a tall Roman numeral II centred on it, with bars across its
    top and bottom, the whole a left-to-right rainbow: 70% of the tile tall, its stems 3/4 the width of SF Pro's
    I at weight 900. (Typeset 1's icon was "Ts", the s tucked under the T's arm; to set letters instead, as
    T2 was: ICON_TEXT=T2 ICON_KERN=-0.03 ICON_BARS=0 ICON_HEIGHT=0.461.)"""
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
    S = 1024
    TILE = (100, 100, 924, 924)                       # macOS icon grid: 824 of 1024
    T = TILE[2] - TILE[0]
    FACE = tuple(json.loads(os.environ["ICON_FACE"])) if os.environ.get("ICON_FACE") else ("/System/Library/Fonts/SFNS.ttf", 0, 900)   # SF Pro at weight 900
    TEXT = os.environ.get("ICON_TEXT", "II")          # the first character, then the rest set after it
    KERN = float(os.environ.get("ICON_KERN", "1.0"))  # space between them, as a fraction of the first's width
    HEIGHT = float(os.environ.get("ICON_HEIGHT", "0.70"))  # cap height, as a fraction of the tile
    BARS = float(os.environ.get("ICON_BARS", "0.3"))   # a Roman numeral's bars: how far past the strokes, in stems
    RAINBOW = [(255, 59, 48), (255, 149, 0), (255, 204, 0), (52, 199, 89), (10, 132, 255), (175, 82, 222)]

    def font(size):
        f = ImageFont.truetype(FACE[0], size, index=FACE[1])
        if len(FACE) > 2:                              # a variable face: set its weight, the other axes at default
            f.set_variation_by_axes([FACE[2] if a["name"] in (b"Weight", "Weight") else a["default"] for a in f.get_variation_axes()])
        return f

    def numeral(scale):
        """II with a Roman numeral's bars across the top and bottom: the stems as wide as SF Pro's I at weight 900
        and Adobe's cap height, as tall as ICON_HEIGHT, centred on the tile."""
        n = S * scale
        probe = font(1000)
        ib = probe.getbbox("I")
        heavy = (ib[2] - ib[0]) / (ib[3] - ib[1]) * 0.461 * T * scale
        stem = float(os.environ.get("ICON_STEM", "0.75")) * heavy   # thinner than the face's I by ICON_STEM
        gap, over = KERN * heavy, BARS * heavy
        bar = float(os.environ.get("ICON_BAR_WEIGHT", "0.5")) * stem
        h = HEIGHT * T * scale
        width = 2 * stem + gap + 2 * over
        cx, cy = (TILE[0] + T / 2) * scale, (TILE[1] + T / 2) * scale
        x0, top = cx - width / 2, cy - h / 2
        m = Image.new("L", (int(n), int(n)), 0)
        d = ImageDraw.Draw(m)
        d.rectangle((x0, top, x0 + width, top + bar), fill=255)
        d.rectangle((x0, top + h - bar, x0 + width, top + h), fill=255)
        d.rectangle((x0 + over, top, x0 + over + stem, top + h), fill=255)
        d.rectangle((x0 + width - over - stem, top, x0 + width - over, top + h), fill=255)
        return m, (x0, x0 + width)

    def letters(scale):
        """The two characters as a mask at `scale` (render size / 1024), with the tile's cap height and baseline."""
        n = S * scale
        if BARS:                                      # a Roman numeral II, drawn: two stems as heavy as the face's I
            return numeral(scale)
        cap = HEIGHT * T * scale                      # cap height: Adobe's 46% of the tile unless ICON_HEIGHT says
        probe = font(1000)
        cap_per_size = (probe.getbbox("T")[3] - probe.getbbox("T")[1]) / 1000
        f = font(max(1, round(cap / cap_per_size)))
        baseline = (TILE[1] + 0.7264 * T) * scale if HEIGHT == 0.461 else (TILE[1] + (T + HEIGHT * T) / 2) * scale  # taller: centred
        ascent = f.getmetrics()[0]
        a, b = TEXT[0], TEXT[1:]
        tb, sb = f.getbbox(a), f.getbbox(b)
        kern = KERN * (tb[2] - tb[0])                 # T2: the 2's bowl sits a little under the T's arm
        width = (tb[2] - tb[0]) + kern + (sb[2] - sb[0])
        x0 = n / 2 - width / 2
        m = Image.new("L", (int(n), int(n)), 0)
        d = ImageDraw.Draw(m)
        d.text((x0 - tb[0], baseline - ascent), a, font=f, fill=255)
        d.text((x0 + (tb[2] - tb[0]) + kern - sb[0], baseline - ascent), b, font=f, fill=255)
        return m, (x0, x0 + width)

    def render(size):
        k = 4 if size <= 64 else 2                    # draw large and reduce, for clean edges
        scale = size * k / S
        n = int(S * scale)
        im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        box = tuple(v * scale for v in TILE)
        r = 0.1793 * T * scale
        sh = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((box[0], box[1] + 12 * scale, box[2], box[3] + 12 * scale), radius=r, fill=(0, 0, 0, 110))
        im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(18 * scale)))
        ImageDraw.Draw(im).rounded_rectangle(box, radius=r, fill=(0, 0, 0, 255))
        mask, (lx, rx) = letters(scale)
        grad = Image.new("RGBA", (n, n))
        gd = ImageDraw.Draw(grad)
        stops = len(RAINBOW) - 1
        for x in range(n):
            t = min(1, max(0, (x - lx) / max(1, rx - lx))) * stops
            i = min(stops - 1, int(t)); f = t - i
            c = tuple(int(RAINBOW[i][j] + (RAINBOW[i + 1][j] - RAINBOW[i][j]) * f) for j in range(3))
            gd.line([(x, 0), (x, n)], fill=c + (255,))
        im.paste(grad, (0, 0), mask)
        return im.resize((size, size), Image.LANCZOS)

    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "AppIcon.iconset"); os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        render(base).save(os.path.join(iconset, f"icon_{base}x{base}.png"))
        render(base * 2).save(os.path.join(iconset, f"icon_{base}x{base}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(RES, "AppIcon.icns")], check=True)
    render(512).save(os.path.join(RES, "AppIcon-preview.png"))

if __name__ == "__main__":
    os.makedirs(RES, exist_ok=True)
    if sys.argv[1:2] == ["icon"]:                    # just the icon (or, with a path, a preview there and nothing else)
        if len(sys.argv) > 2: RES = sys.argv[2]; os.makedirs(RES, exist_ok=True)
        icon(); print("icon written to", RES); sys.exit(0)
    fonts(); raleway_bold(); nameplate(); seed(); staff(); icon()
    print("resources written to", RES)
