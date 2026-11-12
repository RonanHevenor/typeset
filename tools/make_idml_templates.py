"""Derive Typeset's IDML package templates from the paper's own InDesign file.

InDesign wrote repro/idml/src/septabloid2_FINAL.idml; the parts of it that don't depend on content (document
preferences, swatches, the font list, the empty master, the XML backing story, object/table styles) are kept as
they are, so what Typeset exports is a package InDesign has already shown it accepts. Typeset's paragraph and
character styles replace the Poly's ad hoc "Paragraph Style N" set, and designmap.xml gets markers where the
exporter writes the story list, spreads, sections and stories. Run once; the outputs are committed in
app/Resources/IDML. Needs only the standard library."""
import os, re, sys, uuid, zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))        # septabloid2/
SRC = os.path.join(ROOT, "repro", "idml", "src", "septabloid2_FINAL.idml")
OUT = os.path.join(ROOT, "app", "Resources", "IDML")

z = zipfile.ZipFile(SRC)
def read(name): return z.read(name).decode("utf-8")

os.makedirs(OUT, exist_ok=True)
def write(name, text):
    with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as f: f.write(text)

# ---- verbatim parts -----------------------------------------------------------------------------------------
write("mimetype", read("mimetype"))
write("container.xml", read("META-INF/container.xml"))
write("Graphic.xml", read("Resources/Graphic.xml"))
write("Fonts.xml", read("Resources/Fonts.xml"))
write("Tags.xml", read("XML/Tags.xml"))
write("BackingStory.xml", read("XML/BackingStory.xml"))

# the master: empty, but its margins become the margin guides of every page
master = read("MasterSpreads/MasterSpread_ud6.xml")
master = re.sub(r'<MarginPreference [^>]*/>',
                '<MarginPreference ColumnCount="1" ColumnGutter="12" Top="78" Bottom="36" Left="36" Right="36" ColumnDirection="Horizontal" ColumnsPositions="0 729" />',
                master)
write("MasterSpread_ud6.xml", master)

# ---- preferences: the paper's, with the baseline grid at the body leading ------------------------------------
prefs = read("Resources/Preferences.xml")
prefs = re.sub(r'(<GridPreference [^>]*BaselineStart=")[^"]*(")', r'\g<1>78\g<2>', prefs)
prefs = re.sub(r'(<GridPreference [^>]*BaselineDivision=")[^"]*(")', r'\g<1>14.4\g<2>', prefs)
prefs = re.sub(r'(<MarginPreference [^>]*Top=")[^"]*(")', r'\g<1>78\g<2>', prefs, count=1)
write("Preferences.xml", prefs)

# ---- designmap: everything but the parts the exporter writes --------------------------------------------------
dm = read("designmap.xml")
dm = re.sub(r'StoryList="[^"]*"', 'StoryList="@@STORYLIST@@"', dm, count=1)
dm = re.sub(r'(<Document [^>]*?)Name="[^"]*"', r'\1Name="@@NAME@@"', dm, count=1)
dm = re.sub(r'\t<idPkg:Spread src="[^"]*" />\n', '', dm)
dm = re.sub(r'\t<idPkg:MasterSpread src="[^"]*" />\n', '\t@@SPREADS@@\n', dm)
dm = re.sub(r'\t<Section .*?</Section>\n', '', dm, flags=re.S)
dm = dm.replace('\t<DocumentUser ', '\t@@SECTIONS@@\n\t<DocumentUser ', 1)
dm = re.sub(r'\t<idPkg:Story src="[^"]*" />\n', '', dm)
dm = re.sub(r'\t<idPkg:BackingStory src="[^"]*" />\n', '\t@@STORIES@@\n', dm)
assert all(m in dm for m in ("@@STORYLIST@@", "@@NAME@@", "@@SPREADS@@", "@@SECTIONS@@", "@@STORIES@@")), "designmap markers"
write("designmap.xml", dm)

# ---- styles: Typeset's house styles in place of the Poly's "Paragraph Style N" set ------------------------------
styles = read("Resources/Styles.xml")

def pstyle(name, font, attrs, leading=None):
    sid = uuid.uuid5(uuid.NAMESPACE_URL, "galley-paragraph-style/" + name)
    a = " ".join(f'{k}="{v}"' for k, v in attrs.items())
    props = ('<BasedOn type="string">$ID/[No paragraph style]</BasedOn>'
             '<PreviewColor type="enumeration">Nothing</PreviewColor>')
    if leading is not None: props += f'<Leading type="unit">{leading}</Leading>'
    props += f'<AppliedFont type="string">{font}</AppliedFont>'
    return (f'\t\t<ParagraphStyle Self="ParagraphStyle/{name}" Name="{name}" Imported="false" NextStyle="ParagraphStyle/{name}" '
            f'SplitDocument="false" EmitCss="true" StyleUniqueId="{sid}" IncludeClass="true" ExtendedKeyboardShortcut="0 0 0" '
            f'EpubAriaRole="" EmptyNestedStyles="true" EmptyLineStyles="true" EmptyGrepStyles="true" KeyboardShortcut="0 0" {a}>\n'
            f'\t\t\t<Properties>{props}</Properties>\n\t\t</ParagraphStyle>\n')

INK = "Color/C=0 M=0 Y=0 K=100"
BYLINE = "Color/C=10 M=89 Y=99 K=1"
LANG = "$ID/English: USA"
nohyph = {"Hyphenation": "false"}
galley_styles = (
    # body copy: Minion 12/14.4 justified, 18 pt indent, on the frame's baseline grid; the single-line composer
    # breaks lines the way Typeset's engine does, one line at a time
    pstyle("Body", "Minion Pro", {"FontStyle": "Regular", "PointSize": "12", "Justification": "LeftJustified",
            # Typeset's composer fills a line at 100% spacing and only stretches it to justify; it never squeezes.
            # Min = desired = max keeps InDesign to the same line, and hyphenation stays off: the exporter puts a
            # discretionary hyphen exactly where Typeset broke each word, which InDesign takes regardless
            "FirstLineIndent": "18", "FillColor": INK, "Composer": "HL Single", "Hyphenation": "false",
            "HyphenateAfterFirst": "2", "HyphenateBeforeLast": "2", "HyphenateWordsLongerThan": "5",
            "HyphenateLadderLimit": "0", "HyphenateCapitalizedWords": "true", "HyphenateLastWord": "true",
            "MinimumWordSpacing": "100", "DesiredWordSpacing": "100", "MaximumWordSpacing": "100",
            "MinimumLetterSpacing": "0", "DesiredLetterSpacing": "0", "MaximumLetterSpacing": "0",
            "MinimumGlyphScaling": "100", "DesiredGlyphScaling": "100", "MaximumGlyphScaling": "100",
            "GridAlignment": "AlignBaseline", "GridAlignFirstLineOnly": "false",
            "KeepFirstLines": "1", "KeepLastLines": "1", "AppliedLanguage": LANG}, leading=14.4),
    pstyle("Headline", "Utopia Std", {"FontStyle": "Semibold Subhead", "PointSize": "36", "Justification": "LeftAlign",
            "FillColor": INK, "AppliedLanguage": LANG, **nohyph}, leading=37.44),
    pstyle("Byline", "Raleway", {"FontStyle": "SemiBold", "PointSize": "12", "Justification": "LeftAlign",
            "FillColor": BYLINE, **nohyph}, leading=14.8),
    pstyle("Byline Title", "Myriad Pro", {"FontStyle": "Italic", "PointSize": "10", "Justification": "LeftAlign",
            "FillColor": INK, **nohyph}, leading=14.3),
    pstyle("Caption", "Minion Pro", {"FontStyle": "Bold", "PointSize": "9", "Justification": "LeftJustified",
            "FillColor": INK, "Hyphenation": "true", "AppliedLanguage": LANG}, leading=10.8),
    pstyle("Jump Line", "Raleway", {"FontStyle": "Bold", "PointSize": "12", "Justification": "RightAlign",
            "FillColor": INK, **nohyph}, leading=14.4),
    pstyle("Folio", "Raleway", {"FontStyle": "Bold", "PointSize": "12", "Justification": "LeftAlign",
            "FillColor": INK, **nohyph}, leading=14.4),
    pstyle("Teaser", "Utopia Std", {"FontStyle": "Bold Italic", "PointSize": "16", "Justification": "LeftAlign",
            "FillColor": INK, "Hyphenation": "true", "AppliedLanguage": LANG}, leading=19.36),
    pstyle("Teaser Page", "Raleway", {"FontStyle": "SemiBold", "PointSize": "12", "Justification": "LeftAlign",
            "FillColor": "Color/Paper", **nohyph}, leading=14.4),
    pstyle("Dateline", "Raleway", {"FontStyle": "SemiBold", "PointSize": "12", "Justification": "RightAlign",
            "FillColor": "Color/Paper", **nohyph}, leading=14.4),
    pstyle("Pull Quote", "Raleway", {"FontStyle": "Regular", "PointSize": "20", "Justification": "CenterAlign",
            "FillColor": INK, **nohyph}, leading=24),
)

# keep [No paragraph style] and NormalParagraphStyle (InDesign expects both), drop the rest
m = re.search(r'(<RootParagraphStyleGroup [^>]*>\n)(.*?)(\t</RootParagraphStyleGroup>)', styles, re.S)
keep = "".join(re.findall(r'\t\t<ParagraphStyle Self="ParagraphStyle/\$ID/[^"]*"[^>]*(?:/>|>.*?</ParagraphStyle>)\n', m.group(2), re.S))
assert keep.count("<ParagraphStyle ") == 2, "default paragraph styles"
styles = styles[:m.start()] + m.group(1) + keep + "".join(galley_styles) + m.group(3) + styles[m.end():]

m = re.search(r'(<RootCharacterStyleGroup [^>]*>\n)(.*?)(\t</RootCharacterStyleGroup>)', styles, re.S)
keep = "".join(re.findall(r'\t\t<CharacterStyle Self="CharacterStyle/\$ID/[^"]*"[^>]*/>\n', m.group(2)))
assert keep.count("<CharacterStyle ") == 1, "default character style"
styles = styles[:m.start()] + m.group(1) + keep + m.group(3) + styles[m.end():]
write("Styles.xml", styles)

print("wrote", sorted(os.listdir(OUT)))
