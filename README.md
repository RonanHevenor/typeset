# Typeset

A Mac app that lays out a tabloid student newspaper. Paste stories in, rank them, and get a paper; then edit the
pages directly. It exports print-ready PDF, and IDML for anyone who finishes in InDesign.

Typeset was built for *The Polytechnic*, RPI's independent student newspaper. As a result, the app has some very strong opinions. All the settings to change those opinions are in code, so the look of the paper changes by editing `HouseStyle.swift`. The paper's name, website, staff and
nameplate are settings and require no code changes.

## Getting started

You're going to need macOS 14 or later and the Swift toolchain that comes with Xcode or the Command Line Tools.

```bash
git clone https://github.com/RonanHevenor/typeset.git
cd typeset
./build.sh            # swift build, assemble build/Typeset.app, sign ad hoc, open
```

`./build.sh --no-open` builds without opening; `tools/make_dmg.sh` then packages it as `build/Typeset.dmg`. Every push
to `main` is built on GitHub Actions.

### Your paper's own files: `Resources/Private`

Anything in `Resources/Private/`, which is gitignored, is bundled into the app as its defaults:

- `Fonts/`: the fonts above, so a build is ready on any Mac you copy it to
- `paper.json`: `{"name": "…", "website": "…", "staff": [{"name": "…", "role": "…"}]}`
- `nameplate.pdf`
- `seed-issue.json` and `SeedMedia/`: an issue to start from. The self-tests (`--selftest`) and the headless
  `--render` default use it; both say so if it's missing.

Settings made in the app (in `~/Library/Application Support/Typeset`) win over these. `./build.sh --public` leaves
the folder out, to see the app as someone cloning the repository gets it.

*Add Article from Link* and *Update Stories from Website* read stories from The Polytechnic's website through its
API, so they only appear when setup's website is poly.rpi.edu.

### Tools

`tools/make_resources.py` and `tools/make_idml_templates.py` made the original resources from The Polytechnic's
own InDesign file and PDF, which aren't in the repository. They're kept to show where the measurements come from.
`tools/make_resources.py icon` remakes the app icon: a Roman numeral II, for Typeset 2, in the manner of Adobe's
app tiles (a black rounded square at their proportions), the numeral tall (70% of the tile) with bars across its
top and bottom, its stems 3/4 as wide as SF Pro's I at weight 900, the whole a left-to-right rainbow. `ICON_TEXT`,
`ICON_HEIGHT`, `ICON_STEM` and the other `ICON_` settings make the variants tried along the way, such as T2. It needs
Pillow (`pip install pillow`, in a venv).

## The app's look

The app itself looks like Typeset, not like the paper: the top of the Content step's sidebar says "Typeset" in SF Pro
at weight 900 and its left-to-right rainbow, and the rainbow stands in for an accent colour
everywhere in the app's chrome. The step switcher's current step and the window's main action (Done Adding,
Generate Paper, Export PDF) are drawn like the icon, a black tile with rainbow letters, and so are the Priority
step's Front · Lead and Front Page badges; a story's desk, an extra's kind, the front-page
rank numbers, a pull quote's placeholder and the picture drop zone (while something is over it) are in the
rainbow. System controls that take only one colour (the sidebar's selected row, focus rings, links) use the
rainbow's blue. Red in the app means a status or a problem and nothing else: overset text, blank lines, holes,
"too close", the problem badges and counts, a missing library file, a story set tight, the stale-paper banner.
Everything on the pages (the paper's red bar, nameplate, byline colour) and everything exported is the paper's
house style and keeps its red. The colours are `Theme.rainbow` and `Theme.brandSolid`; the pieces are in
`Brand.swift`.

It was called Galley until October 8, 2026. On its first run Typeset copies the old
`~/Library/Application Support/Galley` folder to `~/Library/Application Support/Typeset` and leaves the old one in
place (pictures imported then are referenced by their path there). The bundle identifier is unchanged, so
preferences carry over. The test switches keep their old names: `GALLEY_DATA_DIR`, `GALLEY_DEBUG`, `GALLEY_LINES`.
`TYPESET_SETUP=1` opens setup on launch even in a test run.

## Files

An issue is a `.typeset` file you keep wherever you like: one zip with the stories, the layout and every picture
and ad, so it goes through email or Google Drive as a single file and opens the same on another Mac.

- *File › New Issue* (⌘N) saves the issue you're working on first (to its file, or asking where if it has never
  been saved), then asks which template the new issue starts from (see Templates, below), with the one you used
  last selected, and starts it: the template's pages with its components placed, no stories yet, keeping the
  publication and volume and taking the next edition (III → IV, 12 → 13). A blank Untitled issue isn't saved
  first. *New Article* is ⌥⌘N.
- *Open…* (⌘O), *Open Recent* (the system's recent list), *Save* (⌘S), *Save As…* (⇧⌘S) and *Revert to Saved*
  work as in any Mac app. Double-clicking a `.typeset` file in the Finder opens it. Opening or reverting over
  unsaved changes asks first; if you don't save them, they're kept as `issue-before-open-….json` in
  `~/Library/Application Support/Typeset`.
- Save never drops a picture from a file without asking: if some pictures can't be found and the file is already
  there, it lists them and asks before saving without them. A new file is written either way, with a note of
  what's missing.
- The title bar shows the file's name (Untitled until it's saved) and "Edited" while there are unsaved changes;
  the close button shows its dot too. Undo back to what was saved and the mark goes away. Rename or move the file
  in the Finder while it's open and the title follows when you come back to Typeset; if it was deleted or put in
  the Trash, Save asks where to save it.
- Every edit still autosaves to the working copy, `~/Library/Application Support/Typeset/issue.json`, a moment
  after you make it, so a crash or a quit loses nothing; the next launch comes back to the same issue and file,
  still marked edited. Save is what writes the `.typeset` file. Which file the working copy belongs to is kept
  beside it in `document.json`; when the working copy is missing or unreadable and the sample opens instead, that
  record is reset to Untitled, so Save can't write the sample over your last file.
- *File › Library…* (⇧⌘O) lists every issue you've opened or saved, newest first, with a picture of page 1 and
  where the file is. It's kept in `library.json` (thumbnails in `Thumbnails/`) beside the working copy. Each
  entry keeps a macOS bookmark as well as the path, so it still finds a file you've moved or renamed; a file it
  can't find shows as missing, and *Locate…* points it at where it went. *Show in Finder* and *Remove from
  Library* (which leaves the file where it is) are on the buttons and the right-click menu; double-click opens.
  The Templates tab lists the templates you've opened, saved or started an issue from, the same way (Open there
  opens one in the template editor), and the Components tab the component files you've saved, imported or
  opened (*Open* opens one in the component editor). Save and Open follow a moved file the same way. An entry
  this copy of Typeset can't read (a kind from a newer version) is left in `library.json` untouched, and a
  `library.json` that can't be read at all is kept as `library-unreadable-….json` before a new one starts.
- *File › Export Issue as JSON…* still writes the bare `issue.json` (pictures by path, not packed).

## Templates

A template is an issue without stories: pages with components placed on them. It's a `.typesettemplate` file
(plain JSON) with a copy of every component version its pages use, so it opens on any Mac with no component file
around; a page, placement, component or version in it that can't be read is dropped on its own.

- **The Polytechnic** ships with the app: the Header on page 1 and the Folio on the three inside pages, marked to
  repeat on every inside page. It's built from the shipped Header and Folio (`BuiltInTemplates` in
  `Templates.swift`), and it's what an issue made before templates gets, so those lay out as they always did.
- **New Issue** asks for a template: The Polytechnic, the library's templates, or *Other…* to pick a file. The
  issue starts with the template's pages and components, their issue fields filled (page numbers, the date, the
  volume and the new edition). *Generate Paper*, or clicking *Pages* in the step picker once there are stories,
  then lays the stories out in the space the components leave: the
  template's page 1 is the front, and every page after takes the template's page of that number, or past its last
  page, its repeating components. A component placed across the top moves where the stories start; one placed
  lower down, on the front page or inside, is planned around, as an ad is: the stories wrap around it and no
  picture lands on it. The template's pages are kept even when the stories don't reach them,
  except pages that carry nothing but repeating components, which the generator adds only as the stories need
  them. *Clear Pages* puts the template's components back on every page. The issue keeps a copy of its template
  in its file, so *Shuffle Paper* and *Clear Pages* work from it on any Mac.
- **Duplicate on All Pages** and **Duplicate on All Inside Pages** (right-click a placed component, in an issue or
  a template) put a copy, with empty frames, on every page (or every page but the front) that doesn't carry that
  component yet, and mark it as repeating: *Add Page* puts it on every page added after. *Don't Repeat on New
  Pages* takes the mark off; the copies stay, and *Add Page* leaves it off new pages from then on. One undo step
  each. *Add Page* puts only marked components on a new page: a component you removed from every page stays off.
  An issue saved before templates (`format` 2 or older) has its Folio marked as repeating inside when it's
  opened, so *Add Page* still gives a new page its Folio; saved again, it carries `format: 3`.
- **The template editor.** *File › New Template* starts an Untitled template from The Polytechnic; *Open…*, Open
  Recent, the Library or double-clicking a `.typesettemplate` file opens one. It takes the window, as an issue
  does (unsaved work is saved first or kept as a backup, the same way), and shows the Pages canvas without the
  Content and Priority steps, with only components on it: place them from the sidebar's Components section, then
  click, drag, resize and remove them under the same pointer rules as on an issue's pages. *Add Page* (toolbar,
  or right-click a page thumbnail for *Add Page After*), *Move Up*, *Move Down* and *Remove Page* are on the page
  thumbnails, which you can also drag into a new order; whichever page is first is the front. *Save* (⌘S) and
  *Save As…* write the template file and put it in the library; *New Issue* from the editor saves the template
  first.
- **Save as Template…** (File menu) saves the open issue's pages and components as a template: the stories,
  pictures and ads, and whatever fills the frames, are left out, and only the component versions the pages use go
  with it. The issue stays open.

## The three steps

1. **Content** – stories by desk, with a rich-text editor; paste a whole story and the headline and byline are
   picked out. A labelled submission (`Author:`, `Title:`, `Kicker:`, `Article:` …) is read field by field;
   a poly.rpi.edu link (*Add Article from Link*, ⌘L, when setup's website is poly.rpi.edu) brings the story, byline and photos in from the website,
   and *Update Stories from Website* (⇧⌘U) refreshes them. Every field takes ⌘I for italics: the headline (a title
   inside it, in the italic headline face), the kicker, the teaser, the byline's names and title, captions and
   credits, the pull quote, an ad or graphic's caption and credit. Each is stored as *markup* like the body and set
   in its face's italic, or its roman where the face is already italic (a byline title, a teaser, the paper's name
   in a credit); Raleway, which has no italic bundled, slants on screen and in the PDF and goes to InDesign as
   its real italic; the kicker is the small label over the headline, in bold capitals with no rule under it.
   A story's first paragraph is set flush left and every later one indented, on the page, in the editor and in
   the IDML (a paragraph picked up after "Continued from Page N." is indented as before). *Insert* adds ads,
   images and graphics that run on their own (image or PDF files; drop them on the sidebar too). Once a paper
   exists, each row shows where it runs.
2. **Priority** – drag stories into order. The top two lead the front page, the rest fill the inside pages in
   order. Nothing is teased above the nameplate on its own any more: the Header's three teaser frames start
   empty (filling them by hand comes with phase 5's sidebar).
3. **Pages** – the generated paper on a canvas. Everything is editable in place.

## Pages

- The pointer follows six rules on every page, at every zoom. Clicking selects, and nothing else does: a click
  (down and up within 4 screen points) selects what is under the pointer or, on empty paper, clears the
  selection; hovering, scrolling, undo and a drag that ends somewhere else never change it. Dragging an
  unselected item picks it up and selects it as it goes, like Keynote; a drag from empty paper draws a marquee and
  grabs nothing.
  Hit areas are what is drawn: a photo is its picture and caption, a pull quote its box, an ad its fitted
  picture and caption, a story block its frame less the pictures and quotes on it. The topmost thing wins, in
  draw order (what you moved last is on top), and click, hover, cursor, drag and right-click all agree. Resize
  edges belong to the selected item only, 8 screen points either side of the edge at any zoom; they yield
  wherever something drawn over the item covers them, but not to the story a picture sits on, and they reach
  past the page edge. Every drag is one undo step, opened only once the pointer has really moved. A drag
  whose mouse-up is lost (the window loses focus mid-drag, you press Escape, or the mouse moves on with the
  button already up) leaves the item where it is and
  closes cleanly; the next press starts fresh. Clicking a page doesn't scroll the canvas; choosing a page in
  the navigator or a menu does.
- **Several at once.** ⇧-click adds an item to the selection, or takes it out; ⇧-click on empty paper keeps the
  selection. A drag from empty paper draws a marquee and selects what it fully encloses, by the same shapes the
  hit test uses (an item it only brushes is left out; one that encloses nothing selects nothing); with ⇧ it adds
  to the selection. A selection is on one page: ⇧-clicking an item on another page starts a new one there. Drag
  any selected item to move them all (snapped as one box, with the guides; onto another page, they all go,
  shown as one dashed outline; into the inspector, the stories go on hold and the rest comes off the page); the
  arrow keys nudge them and stop at the page edge as one; Delete removes them. Each is one undo step. A click
  on one of them selects it alone; dragging an item outside the selection selects and moves just that item. With
  several selected, no item shows edges or takes a resize, crop or byline pull. Right-click one of them, or use
  the inspector, for *Make Component…* and *Delete*.
- **Make Component…** asks for a name, then turns the selected items into a new component placed where they
  are. It's on the right-click menu of a single block, picture, pull quote or ad too, for a component of one
  item. Each item becomes typed frames, each where the item drew that part: a story block becomes kicker,
  headline, author, author title and body frames linked as one story (A for the first story, B for the next…; a
  part the story doesn't have, such as a kicker, gets no frame); a photo becomes an image frame and a caption
  frame; a pull quote a pull-quote frame; an ad an ad frame (and a caption frame if it has a caption). A story's
  photo and pull quote lying on its block come along even if you didn't select them, and share its letter, so
  dropping another story on the component fills them too; a second photo of the same story, or a picture of a
  story that isn't in the selection, takes its own fill. The component is as wide and tall as the box round the
  items and has the page's columns that box lies across, at the page's widths. It's saved with its frames empty
  (in this issue, under its name in the sidebar; *Save as New Version* asks for a file) and placed filled with
  what was there, so the page sets as it did: the body frame starts where the block's text started and keeps its
  width, wraps around the component's own picture and byline frames, and a story that continues from or jumps to
  another page keeps its "Continued from" and jump line. The items come off the page. One undo step; then the
  in-place editor opens on the new component. A headline frame sets its lines as a block's headline does; the
  stories round the component keep clear of it as of a story, not a picture (see below), a neighbour's byline
  stays level with the made story's, and the hairlines between stories run against it as they did. A body frame
  that lies exactly on the page's columns sets in them, even when the box round the selection ends mid-column
  and the component's own columns come out narrower. An item with nothing to draw (a pull quote whose story has
  none, a photo no longer in its story) isn't made into a frame and stays on the page.
- Click a story block, picture, pull quote or ad to select it; drag to move, pull anywhere along an edge or corner
  to resize (the edge under the pointer lights up). Frames snap to columns, margins and neighbours with alignment
  guides, and to the lines inside a story: the byline's top and bottom rules and where the body starts. Those
  pull from further away, so a picture dragged near a story drops in under its headline instead of into it. A
  picture snapped to a rule lands with its outline's stroke on the rule's stroke, one line, not a frame edge
  0.375 pt off it.
  ⇧ holds a drag to one axis, ⌘ turns snapping off. Pictures keep their proportions from any edge; ⌥ crops
  instead. A pull quote's height follows its text, so only its sides move.
- Drag anything onto another page: it stays on its own page while a dashed outline, snapped against the other
  page with its guides, shows where it will land. Drag it off the canvas into the inspector to put the story on
  hold or take the picture off the page. That counts once the pointer is 24 points past the canvas's edge, even
  when a zoomed-in page runs on under the inspector.
- Drag out of the inspector onto a page: a story (its block starts where you let go and runs down to whatever is
  below), one of its photos or its pull quote (the chips under each story), or an ad or graphic. A dashed outline
  shows where it will land before you drop, with the same guides as a drag on the page; ⌘ turns snapping off. A photo or quote already on a page moves rather than running twice;
  one dropped into its own story's block lets the block run down to take the displaced lines. Right-click a block
  for *Add Photo* and *Add Pull Quote*, which use the house spots (photo top right under the headline, quote a
  column in the middle).
- Image and PDF files dropped onto a page come in as pictures (PDFs as ads) and run where they land.
- A headline wraps around a picture only when the picture is really in its way: display type keeps 4 pt clear
  of a picture's edge and tests its glyph box, where body text keeps the full wrap margins (8 pt above, 4 pt
  below) and a photo a line below a headline used to force it into one column. `--headline-probe` in the harness
  reports where the wrap starts.
- Whatever you move sits on top; the story underneath wraps around it. Reading order follows position, so
  "See X, Page N" and "Continued from Page M" keep themselves right. The jump line sits right-aligned at the
  foot of the last column the text reaches the bottom of: a picture or graphic over the last columns' feet sends
  it left, under the text, rather than into the picture's corner.
- Every picture has the house hairline (0.75 pt, stroked inside): photos, ads and graphics (round the ad as
  fitted in its frame), and every image frame in a component, on the page, in the PDF and in the IDML.
- The rules above and below a byline are the first snap: dragging or resizing a picture (or anything else), an
  edge that comes within reach of one lands on it, whatever else is nearer. Under a picture's caption the text
  starts on the first line that clears it (an exact fit is no longer pushed a line down by rounding).
- *Issue › Export PDF…* (⇧⌘E) prints the paper; *Export for InDesign…* (⌥⌘E) writes an IDML package (see below).
- Double-click a block to fit it to its text. Right-click for columns, headline size, Fill Down, Fill Space,
  Move to Page, Continue on Page, Dismiss to Sidebar. Delete removes; arrow keys nudge (⇧ for 10 pt); ⌘Z undoes.
- Bylines wrap inside their column, so a shared byline is never cut off; its title sits under the last line of
  names. A selected block shows a grip on the byline's right edge: drag it across the columns (or right-click,
  *Byline Width*) to run a long byline wider; like an edge, the grip gives way to anything drawn over it. Stories that sit against each other get a hairline between them,
  across the gap or down the gutter; a block closer than the 20 pt house gap to another story says so in red.
- Pictures sit on the story's line grid: the line above ends 8 pt over the picture, and the picture's height is
  trimmed by less than a line (the crop absorbs it) so the text under its caption starts exactly 4 pt below,
  on a line. Generated layouts, the *Width* menu, an edge pull and a drag all land there; the page margins and
  the house gap to a neighbouring story pull from further away than other edges.
- A photo is cropped to fill its frame. Select it and ⌘-drag inside it to slide the picture in the frame (the
  crop goes to the PDF and to InDesign as placed); right-click, *Center the Crop* puts it back.
- Stories set side by side start their bylines on one line, and their tops stay level: each kicker or headline
  starts at its block's top, so the top things line up across the page, and a shorter headline's extra air goes
  between it and its byline. Dragging a story beside another snaps it level with the other's top first.
- When a picture is in a headline's way, the headline may be set up to a quarter smaller rather than squeezed a
  word to a line into the strip beside it: each size is costed by the lines squeezed beside the picture, the
  empty space beside them and the size given up, and the largest of the lowest cost is used (on the page and in
  the IDML). The copyfit spreads its tightening or loosening over
  the whole story first and only then touches runs of words at paragraph ends, and never pushes a run past the
  comfortable range on its own.
- Front-page stories only jump inside when they really don't fit: a story that nearly fits is set tight, its
  picture shrunk, or ended on the front, rather than leaving a headline with nothing under it inside.
- *Fill Space* (⇧⌘L) is Fill Down plus the composing editor's tricks, in the generator's order: the story's lead
  photo sized to the gap, its pull quote, a bigger headline (to 48 pt), a taller photo. What the text still can't
  fill stays flagged; that is where an ad, a brief or another story goes. *Fill Holes* on a page does the same for
  each block it stretches.
- The inspector says what each block is doing ("whole story · 2 empty lines", "39 lines continue on page 2",
  "nothing left to run here: the story ended on page 1") and, for the story, how it's set, blank lines, room,
  and blocks it never reaches. Those last are drawn in red on the page too.
- Problems are drawn in red on the page: overset text, blank lines a story can't fill even set loose, and holes
  nothing covers (with their size in square inches). *Fill Holes* runs the story above each hole down into it.
- Layout menu (the dice): shuffle the paper, add a page, clear every page to build by hand. Thumbnails have a
  context menu for the same per page.

## Copyfitting

Every story is set to fill its blocks exactly, the way a composing editor tightens or loosens copy
(`Fit` in `Composer.swift`). The levers, and how far they go at the limit:

| lever | tightest | loosest | source |
|---|---|---|---|
| word spacing | 75% of a space | 133% | Bringhurst's M/5 … M/3; InDesign's 133% maximum |
| tracking | −15/1000 em | +12/1000 em | InDesign: ±10 is "barely noticeable" |
| leading | 14.0 pt | 14.9 pt | kept small; it shows across columns |
| glyph scaling | 97% | 103% | Adobe's 97–103% guidance, used only past half way |

Those are the comfortable limits, the band on the gauge; together they move a story's footprint about −10% to
+13%. Past them is an emergency range, the same levers pushed about twice as far (leading 13.6–15.4, tracking
−25…+20, word spacing 65–145%, glyph scaling 95–105%), used only when the comfortable range can't make a story
fit or fill. The gauge turns orange there, the inspector says "Very tight" or "Very loose", and the status bar
counts stories set hard.

While you pull a block's top or bottom edge, a green band shows where the edge can land for a comfortable fit
and a green line marks the house-style height: the box height at which the story, with nothing changed, ends
flush at the bottom of its last column. The edge snaps to that line. The text reflows live at whatever the
current height asks for, so the line can sit above or below where the text ends right now.

**The fit's priorities, in order.**

1. Every column ends on the same line. The story must come to exactly the lines its blocks hold, so the last
   line of the last column lands flush with the others. A story that runs on gives its last slot to the jump
   line; one that ends in the block keeps it.
2. As many words in the box as possible. The story ends in the earliest block that can hold it within the
   limits, and only runs on when none can.
3. The least noticeable change. Runs of words at the ends of paragraphs (the last one, two or three lines, or
   the whole paragraph) set tighter or looser, each pushed only as far as it takes to move a line; a uniform
   setting for the whole story, leading included, only when those can't reach the count. Cost is strength
   squared times the words touched, so a big run moved a little always beats a small run moved a lot; the end
   of the story goes first. The real layout is measured and corrected where the paragraph model is a line off.
   The inspector reports "House style · 2 places tightened to lose 2 lines".

When flush is out of reach the story is set at house style. A box too tall for the story even set as loose as
allowed shows its blank lines in red. A story that doesn't finish in print even set as tight as allowed ends
its last block with "Read the rest at <website>." (setup's website; "Read the rest online." without one) in the jump line's slot; that is a note in orange, not an
error. To keep it in print instead, right-click the block, or use the selection panel, for *Continue on Page*,
which adds another block of the story on that page. Blocks the story never reaches don't count toward its size
or its room. The same fit runs while you drag a block's edge, so what you see mid-drag is what you get. The inspector shows each story's setting, the space it takes up, and how much it could
still give up ("room for 5.1 in²"): that is how much you can drop onto the page before anything oversets.

## Components

A component is a small page: a sized box of lines, rectangles, ellipses, preset text, placed art (an image or
PDF, embedded) and *frames*, which are typed spots that stay empty until something fills them. A component has a
name and numbered versions; a version keeps its size, its own column count and gutter (both the page's unless it
says otherwise), and its elements. The types are in `Components.swift`. You make and change components in the
component editor, and place, move, resize, fill and remove them on the pages, as below.

### The component editor

*File › New Component* opens an empty one (the page's live width, 200 points high). *Edit…* on a component's
right-click menu in the sidebar, *Edit Component…* on a placed component's, or *Open* in the Library window's
Components tab opens an existing one, at the version picked (the newest by default). Each component has its own
window; opening one that's already open brings its window up, and if you picked another version it opens that
version there, as the history does (*Undo* goes back).

- **The canvas** shows the component at its size on a faded page, so you can see where it would sit: the page's
  margins (dashed), the page's columns (faint blue), and the component's own columns (teal). It sits where it's
  placed in the open issue, or at the top left of the live area. Every frame is outlined and labelled with its
  type and link letter ("Headline · A"); empty frames show their rainbow, and issue fields show what they'd say
  on page 1 of the open issue.
- **Tools**, along the top: *Select*; *Frame*, with its type (the story fields, ad or graphic, or the issue
  fields) and link letter (frames with the same letter take one story between them; an ad or issue-field frame
  isn't linked); *Line*; *Rectangle*; *Ellipse*; *Text* (preset text); the *Fill* colour; the line
  *Weight* (0.25 to 8 pt); and *Place Art…*
  (an image or PDF, embedded and fitted into the middle of the component). Drag with a tool to draw the element,
  or click to put down one of a standard size; the tool then goes back to Select and the new element is
  selected. ⇧ keeps a line level or upright. The fill colour goes on whatever is selected (a shape's fill, a
  line's colour, text's colour, a frame's type colour) and new rectangles and ellipses take it. The weight goes on the
  selected line, or a selected shape's stroke (stroked in ink if it had none), and new lines take it; the
  inspector sets any weight for a line, typed or stepped by a quarter point.
- **The pointer** works as on the pages, through the same hit test and the same rules: a click selects what's
  under it (the component itself on its empty area) and a click off the component clears; hovering never
  selects; dragging an unselected element selects and moves it; a drag from the page outside the component picks
  nothing up. What's under the pointer is what's drawn there: a line along its length (4 screen points either
  side), an ellipse inside its curve, the rest by their boxes, the topmost one winning. The selected item's edges
  resize it, 8 screen points either side at every zoom, and yield where another element is drawn over them; a
  level line lengthens from its ends only. Elements snap to the component's edges and columns and to each other's
  edges, with guides; ⇧ holds a drag to one axis, ⌘ turns snapping off; one undo step per drag. Delete removes
  the selection, the arrow keys nudge it (⇧ for ten points), Escape lets go of a gesture, then the tool, then the
  selection; right-click for *Bring to Front*, *Send to Back*, *Duplicate* and *Delete*.
- **The component's size.** Select the component (click its empty area) and pull its edges: they snap to the
  page's margins, the page's columns and the full page. Pulling the left or top edge trims from that side; what's
  inside stays where it is on the page. The inspector takes a width and height too.
- **The inspector** shows the selected element (its position and size; for a frame its type, link letter, a
  type size and an alignment, both "House style" unless you set them, and a date frame's format; for text its
  words, face, size, alignment and colour; for a shape its fill and stroke; for a line its colour and width),
  then the component (its name, size, columns and gutter, both the page's unless you set them; a gutter too wide
  to leave each column 12 points is cut down to that, here and on the page), then its versions.
- **Versions.** *Save Version*, or ⌘S with the editor in front, makes what's on the canvas the next version
  (numbered after the newest) and writes the component's file; a component that has no file yet (a new one, the
  Header or Folio, or one only in an issue) asks where to save it first. The history lists every version with its
  date; *Open* on an old one shows it, and your next save builds on it. Placed components keep the version they
  were placed with until you switch them (*Switch Version…*).
- **Component files.** A `.typesetcomponent` file holds one component and all its versions. *File › Save
  Component As…* saves the editor in front to a file you pick (with the canvas as a new version if it's
  changed); *File › Import Component…* adds a file to the library, so the sidebar lists it. A component that's
  only in the open issue has *Add to Library…* on its sidebar row, which saves it as a file. Every component file
  you save, import or open is noted in the library. Double-clicking one in the Finder opens it in the editor.
  Closing an editor with unsaved changes asks Save, Don't Save or Cancel.

### On the page

- **The sidebar.** The Components section sits under Ads & Graphics. It lists the Header and the Folio, the
  library's component files, and any component the open issue carries that neither has ("In this issue only").
  The issue keeps a copy of every version its pages use; a copy no page uses any more stays while the issue is
  open (so undo can draw it) and is left out when you save, so it's gone the next time you open the file.
  Each row has a thumbnail (its frames drawn as empty), where it runs in this issue ("Page 1 · v1", "Page 2 ·
  custom", or "Not in this issue"), and a version picker set to the latest. Drag the row onto a page to place
  that version there, with the same dashed preview, snapping and guides as any drag in from the sidebar (⌘ turns
  snapping off); or right-click it, *Place on Page*. Clicking the row selects where it runs.
- **On the canvas** a component follows the same pointer rules as stories and pictures. Its hit area is its
  frame: a click anywhere on it, frames included, selects the component, not the frame. Where a component and a
  story's frame overlap, the component is on top (the story's text wraps around it), and a picture is on top of
  both. Drag it to move it, onto another page to move it there, or into the sidebar to take it off the page;
  Delete removes the selected one; arrow keys nudge it. Its edges resize it, snapping to the margins, the page's
  columns and what's on the page: the boxes, lines and shapes inside stretch with it, the type keeps its size and
  re-sets in the new boxes. The selected component's edges reach a few points outside its frame even over the
  story it sits on, as a picture's do over the story or component under it. The selection box reads "Header
  v1", or "Header custom" for a copy edited in place.
  One undo step per gesture.
- **Editing in place.** Double-click a placed component (or right-click, *Edit in Place*, or the inspector's
  button) and it opens for editing where it sits: the component in full colour, its frames shown as frames, the
  rest of the paper greyscale and faded. The component editor's tools run along the top of the canvas and its
  inspector replaces the sidebar; the pointer, snapping, Delete, the arrow keys and right-click work as in the
  editor, at the pages' zoom. The paper takes no clicks, hovers or drops until you're done; a component placed
  stretched opens as it's drawn (its boxes stretched, its type at its size). Edits are undone one by one with
  ⌘Z while it's open. *Done* (or Escape with nothing selected, or leaving the Pages step) keeps the changes on
  this page only: the component reads "Header custom", in one undo step. Done with nothing changed leaves it as
  it was. The name isn't changed in place. Until you're done the stories still wrap around the component where
  it was. A ⌘Z that goes past the editor's own edits undoes the page's last step; if that moves or changes the
  component, the editor starts again from it as it is now. The drawing tools draw inside the component only: a
  press on the faded paper draws nothing, and a shape dragged or put down near the edge stops at it. If the
  window loses the mouse mid-gesture, the editor's gesture closes as the pages' does (rule 6).
- **A custom component** has *Save as New Version* and *Revert to vN* on its right-click menu and in the
  inspector. Save as New Version makes the copy the component's next version and writes it to the component's
  file (asking where if it has none, as *Save Version* does), and the placement shows that version ("Header
  v4"). Revert to vN draws the version it was made from again, at the size it has now; fills carry over as
  Switch Version's do. Each is one undo step (the file Save as New Version wrote stays written).
- **Filling frames.** Drop a story, one of its photos, its pull quote, or an ad on a frame. The dashed preview
  turns into the frame when it's over one that takes what you're dragging; let go and the frame fills instead of
  a block or picture being placed. A story fills any story frame with the field the frame asks for (its headline
  in a headline frame, its body in a body frame, its first photo in an image frame); a photo fills an image frame;
  a pull quote a pull-quote frame; an ad an ad frame or an image frame that isn't linked (a linked image frame
  shows its group's story, so it doesn't take an ad). Frames with the same link letter take one
  story between them: drop on any of them and all of them fill. A point exactly on the line between two frames
  belongs to the frame right of it (or below it). The inspector lists the selected component's frames and what
  fills each, with a button to clear one.
- **Taking content out.** With the component selected, ⌥-drag a filled frame: let go off the component (or in
  the sidebar) and the frame is cleared, its story or picture going back where it was in the sidebar; let go on
  another frame that takes it and it moves there; let go over a frame that doesn't take it, or anywhere else on
  the component, and nothing changes. Right-click a frame for *Clear … Frame*.
- **Pictures in image frames** crop as photos do: ⌘-drag inside the picture of a selected component slides it in
  its frame; right-click, *Center the Crop* puts it back in the middle.
- **Switch Version…** (right-click, or in the inspector) moves a placed component to another version after a
  warning that it might break things, listing the stories that would go back to On Hold (they run nowhere else)
  and anything else its frames would let go of. Fills carry over by frame and link letter (a frame that's linked
  in the new version and not in the old, or the other way round, keeps what it showed); the component keeps
  its place and its stretch. The issue keeps its copy of the old version, so undo draws it again.
- **A story in a body frame** starts there and runs on: if it doesn't fit, it jumps ("See X, Page N") to its next
  block in reading order, and that block opens "Continued from Page N". You see it on the page, in the jump line
  at the foot of the frame, and in the sidebar, where the story's row lists every page it runs on, the body
  frame's page included (a story set only in a component's body or whole-story frame isn't On Hold; one shown
  only in a headline, teaser, caption or image frame still is, and the Switch Version warning counts it the same
  way). Deleting a story or an ad empties the frames it filled.
- **Empty frames** show on screen only: an image or ad frame is filled with the icon's rainbow, diagonally, as behind
  the app icon's letters; a text frame shows stacked wavy rainbow lines, fat for a headline, thin and many for
  body. *Export PDF…* and *Export for InDesign…* say how many frames are empty and ask first; the export leaves
  them blank.

### The Header and the Folio

Nothing is drawn on a page behind your back any more. What the app used to draw itself, the front page's header
and the inside pages' folio, are two components it ships in `Resources/Components` (`Header.typesetcomponent`,
`Folio.typesetcomponent`; `tools/make_components.sh` remakes them from `HouseStyle.Front` and `HouseStyle.Folio`
with the built app). The Polytechnic template places the Header on page 1 and the Folio on every other page, and
the generator lays the stories out under them; *Clear Pages* and *Add Page* do the same (see Templates). They're selected, moved, resized, filled
and removed like any placed component (above); the harness can fill the Header too (`--render --fill-header`,
below).

- **Header** (one version): the red bar; three teaser-page frames ("Page 5", or "Inside" while the story is on
  no page, in the bar) and three teaser-headline frames under them, linked A, B and C in the three teaser
  columns; the teaser photo's image frame; the nameplate from setup as placed art (none if setup has none; the
  shipped file carries no nameplate and no website, and `BuiltInComponents.withPaper` puts setup's in); and the dateline as a
  date frame with the format `MMMM d, yyyy` and the template `{date} | Vol. {volume} Ed. {edition}`, white,
  right-aligned.
- **Folio** (one version): the rule, the paper's website (from setup) as preset text, a date frame (`EEEE, MMMM d, yyyy`) centred,
  and a page-number frame at the right with the template `[{desk}  •  ]{page}`: "Sports  •  6", or "6" on a mixed
  page.
- The teaser setting is how a group of teaser-headline frames sets: every teaser-headline frame in one placed
  component takes one size and line count. The house 16 pt (or the frames' own size) wherever the headlines
  allow, two lines each, or three (set a little tighter, started 6.5 pt higher) when one needs them; only a
  headline that won't go in three lines brings the size down, half a point at a time; never an ellipsis. A
  story's own teaser text (the Content step's teaser field) keeps a long headline from doing that.
- An issue saved before this (no `format` key in its file) opens with the Header on page 1, filled with the
  stories it teased and its teaser photo (crop and all), and the Folio on every inside page, so it looks as it
  did; saved again, it carries `format: 3` (2 before templates) and no `teasers` key. An issue already in the new format keeps a
  front page you cleared of its Header. With the Header filled by stories 3–5 by hand, the seed paper renders
  pixel for pixel as it did before (`repro/compare.sh`; `repro/compare.sh --migrated` checks the migration the
  same way).
- The front page's teaser photo is no longer a picture of its own kind on the canvas (the `.teaser` inset, whose
  box couldn't be resized and whose crop slid with a plain drag, is gone); it's the Header's image frame, which
  phase 5 puts under the same pointer rules as everything else.

- A frame's type says what fills it. Story fields: headline, kicker, author, author title, body, image, caption,
  credit, pull quote, teaser headline, or a whole story (the house module: kicker, headline, byline and body).
  Teaser page (where a teased story runs). Ad or graphic. Issue fields fill themselves on every page: page
  number, date (with a `DateFormatter` format, `EEEE, MMMM d, yyyy` unless the frame gives one), volume, edition,
  and desk (the page's desk; empty on a mixed page; the stories in a page's component frames count towards its
  desk, as its blocks do). An issue field may carry a template, words around its value with `{page}`, `{date}`,
  `{volume}`, `{edition}` and `{desk}` standing for the facts; a part in square brackets is left out when a fact
  inside it is empty. A frame may set a type size, an alignment, a colour and (issue fields and teaser pages) a
  face; otherwise text takes the house style for its type: Raleway Bold 12 for the fields, set on the frame's
  first baseline. Frames with the same link letter ("A") take one story between them.
- A placed component (`PageLayout.components`) records the component, the version it was placed with, or a
  custom copy of one, its frame on the page, and its fills: a story, one of its pictures, or an ad, keyed by frame
  or by link letter. Its frame may be a different size from the version's: the boxes stretch with it, the type
  doesn't.
- The issue keeps a copy of every version its pages use (`Issue.componentVersions`), so a `.typeset` file opens
  with no component file around. A placement whose version is missing draws nothing. As with the rest of the
  layout, an element, version, component or placement that can't be read is dropped on its own.
- The composer draws a placed component element by element, in order, and stories on the page wrap around its
  frame as they do a picture. A component with a body or whole-story frame is the exception: the page's stories
  keep clear of its picture, ad and pull-quote frames (with their captions) as of pictures, and of the rest only
  where a block overlaps it, as of a block lying on it; its stories line up with their neighbours' bylines and
  take part in the hairlines between stories, as the blocks they were made from. Body and whole-story frames are set with the story-block code, in the component's
  own columns: a body frame takes the body alone, a whole-story frame the whole module, and the story copyfits
  and jumps between frames and blocks in reading order like any other. A story set in a component keeps clear
  of the pictures on the page and of the components placed after (on top of) its own, not of one underneath it,
  such as a background panel. A page with no components draws exactly as before.
- *Shuffle Page* keeps a page's components where they are, with what fills them, and plans the page's own
  stories and pictures around them, as it does an ad.
- *Export for InDesign…* writes each placed component as one group, named as its selection box reads ("Header
  v1"), with its elements inside where the page draws them: its lines, rectangles and ellipses, preset text,
  placed art, and its frames as filled (issue fields for that page, teaser headlines set as a group with the page
  each runs on, pictures with their crop). So the Header carries its teasers and teaser photo, a page without its
  Folio has none, and nothing is written for a component that isn't placed. A story in a body or whole-story
  frame is threaded with the story's other frames in reading order, in the component's columns and gutter; those
  text frames sit with the page's other story frames, outside the group, so the thread stays whole. Still not:
  colours other than the paper's red, white and black, which go as the nearest of the three (see
  `repro/notes/parked-bugs.md (kept locally, not in git)`).

## InDesign (IDML)

`.indd` is Adobe's closed binary format; nothing outside InDesign writes it. IDML is Adobe's documented XML
interchange format, which InDesign opens directly and saves as `.indd`, and it is what the September issue was
read from in the first place. Typeset writes it (`IDMLExport.swift`): *Issue › Export for InDesign…* (⌥⌘E) saves
one `.idml` with the pictures inside and shows it in the Finder; InDesign opens it with File › Open. The harness
does the same:

```bash
Typeset --render --issue issue.json --as-is --idml paper.idml      # the paper as laid out in the app
Typeset --render --seed 3 --idml paper.idml [--link-images]        # a generated layout
```

What goes across, so the paper opens in InDesign as the same paper:

- Each page is a spread of the paper's size, with margin and column guides on Typeset's grid. The skeleton of
  the package (document preferences, swatches, the font list, the empty parent page, object and table styles)
  is taken from the Poly's own InDesign file (`Resources/IDML`, made by `tools/make_idml_templates.py`), so the
  parts InDesign is particular about are its own.
- Every story block is a text frame with the block's columns, threaded through the story's blocks in reading
  order, so the story is one InDesign story. "Continued from Page N." is set in italics at the point where
  Typeset's break fell. The jump line ("See ROBOTICS, Page 5." or the website line) is a frame of its own in the
  last column's last slot that the body jumps over. A story that doesn't finish in print shows as overset in
  InDesign, which is the truth of it.
- Each body frame carries its own baseline grid, starting at Typeset's first baseline and stepping at the story's
  leading, and the Body style aligns to it, so lines land where Typeset put them even after a text wrap.
- Every line breaks where Typeset broke it. Typeset's composer fills a line at its word spacing and only ever
  stretches to justify; InDesign by default squeezes spaces to 80% and takes another word, which is why the
  first export broke differently and ran 27 lines short. So the Body style's word spacing is minimum = desired
  = maximum, automatic hyphenation is off, and a discretionary hyphen sits exactly where Typeset hyphenated each
  word (InDesign honours those with hyphenation off). The rest matches TextKit's own measure: the hyphen is
  untracked and may overhang a quarter point, as TextKit lets it; spaces in scaled or locally set runs are written
  at 100% with their exact width as tracking; tracking is divided by the glyph scale; and places Typeset never
  breaks (a hyphen before a digit, "7-3"; a space before a word-initial apostrophe, "Li ’30") are No Break.
  If you edit copy in InDesign, turn hyphenation back on in the Body style for the new text.
- Wraps are written the way InDesign reads them. InDesign tests a line as the strip one leading tall ending at
  its baseline; Typeset as the same strip starting at its first-baseline offset, 3 pt lower. Every wrap therefore
  sits 3 pt higher in the export (photos 11 above and 7 below, for Typeset's 8 and 10). Where a picture leaves
  less than half a column beside it, Typeset drops the line below rather than set a sliver, so the wrap covers
  the sliver; text wraps on the larger side only.
- Where a story continues in a later block, its paragraph is split there: the part before is justified to its
  last line, and the rest starts in the next frame (Keep Options › Start in Next Frame) with "Continued from
  Page N." and the indent Typeset gives it.
- The copyfit travels as InDesign settings. A story's uniform level becomes tracking, horizontal scale and
  leading on its runs and word-spacing (minimum/desired/maximum) overrides on its paragraphs; a whole paragraph
  set on its own is done the same way; the end of a paragraph set on its own carries its tracking and scale on
  that run, with each space also carrying the word-space change as tracking, which is the engine's own model.
  Settings InDesign shows in its panels, nothing baked in.
- Point sizes are character attributes on each run (InDesign ignores them on a paragraph range).
- Headline, byline (between its two rules), caption, pull quote (its box stroked inside, 10 pt inset), and the
  Header's and Folio's teasers, dateline, folio and nameplate (a placed PDF) are frames in Typeset's house styles: Body, Headline,
  Byline, Byline Title, Caption, Jump Line, Folio, Teaser, Teaser Page, Dateline, Pull Quote. Colours are the
  Poly's CMYK swatches. Every frame's first baseline is pinned where Typeset's falls.
- Pictures travel inside the package, embedded the way InDesign embeds a link (the file's bytes, base64, in the
  image element; the Links panel shows them as embedded, and *Unembed* writes them back out). `--link-images`
  writes linked files into a `Links` folder beside the package instead. Either way they are cropped to fill
  their frame (photos, with the 0.75 pt outline inside) or fitted whole (ads), with the same text wrap body
  copy keeps in Typeset (8 pt above, 4 below, a gutter either side, caption included). The byline keeps 4 pt clear below it.
  Headlines only mind wraps when a picture really is in their band, as Typeset's display type does.
- Not carried: a block lying on top of another block's text (Typeset wraps the one underneath; InDesign has no
  wrap between text frames); the red problem markers.

`--as-is` keeps the layout saved in the issue instead of generating one. With `GALLEY_LINES=lines.tsv`, every
body line Typeset sets is logged (story, width, indent, hyphenated, used width, text), which is how the export's
line breaks are checked against Typeset's: a greedy fill of the exported story under InDesign's rules, measured
with HarfBuzz on the real fonts, ends every logged line where Typeset ended it.

## Headless

The same engine runs without a window, for testing:

```bash
Typeset --render [--issue issue.json] [--out paper.pdf] [--seed N | --as-is] [--fill-header] [--guides] [--json layout.json] [--idml paper.idml [--link-images]]
Typeset --make-components [dir]       # writes the shipped Header and Folio as .typesetcomponent files
GALLEY_DATA_DIR=/tmp/x Typeset --snapshot --stage content|priority|pages [--out shot.png] [--regenerate]
    [--page N] [--select-block K] [--move-block dx,dy] [--resize-block dx,dy --from-edge nw|n|ne|e|se|s|sw|w]
    [--select-inset K] [--resize-inset dx,dy --from-edge e [--crop]] [--carry-block-to page,y]
    [--columns N] [--fit-block] [--fill-block] [--fill-space] [--remove-block] [--park] [--drop-outside]
    [--add-story K --on-page P] [--add-photo K --photo-index N --on-page P --place-at x,y] [--add-quote K --on-page P]
    [--preview-story K --on-page P --place-at x,y] [--drop-story K --on-page P --place-at x,y] [--drag-image out.png]
    [--scan-fit] [--profile-drag] [--mid-drag]      (GALLEY_DEBUG=1 reports what every compose cost on stderr)
    [--add-extra file --extra-kind Ad --extra-columns N --extra-height pt --place-on P --place-at x,y]
    [--clear-pages] [--clear-page N] [--add-page] [--fill-holes N] [--shuffle N] [--undo N] [--report]
```

`--selftest` includes the canvas checks (`SelfTest+canvas.swift`): they drive the store's pointer state machine
(`pointerDown`, `pointerMoved`, `pointerUp`, `pointerCancelled` in `Store+Pointer.swift`) at page points and
check the selection and the frames, one check per bug in `repro/notes/interaction-bugs.md (kept locally, not in git)`. `--probe x,y` answers
from the same hit test (`CanvasHitTest.swift`) the canvas uses.
The component editor's checks (`SelfTest+editor.swift`) drive its state machine the same way: each tool, the six
pointer rules on its canvas, saving versions and the history, the `.typesetcomponent` round trip, and importing
a component and placing it in an issue. They use a library of their own in `GALLEY_DATA_DIR`, never yours.
Phase 7's checks (`SelfTest+inline.swift`) drive both state machines for multi-select (⇧-click, a marquee that
encloses or only brushes, moving, nudging and deleting the set, one undo step each, a lost drag) and the in-place
editor (a double-click opens it, the paper takes no clicks, leaving makes the placement custom, Save as New
Version, Revert, undo past where it opened). `SelfTest+make.swift` checks Make Component: the frames, letters
and fills a selection of two stories, a photo, a pull quote and an ad becomes, that the saved version is empty,
that the page draws the same text runs and picture rects before and after, a story that jumps and one that
continues, a selection of nothing but pictures, the in-place editor opening, and one undo step.
`SelfTest+makeFixes.swift` runs Make Component on every page of the generated paper (the whole page, and each
block, picture and pull quote alone) and checks that every line of every headline and column, every label and
every rule is drawn where it was; a box ending mid-column; items with nothing to draw; one item alone; and in
place, an undo that reaches the page, drawing on the faded paper, and a lost mouse-up.

`--snapshot` renders the window offscreen to a PNG against its own copy of the issue in `GALLEY_DATA_DIR`,
so it never touches the real one in `~/Library/Application Support/Typeset`. `--fill-header` fills the Header's
teaser frames with stories 3–5 and its image frame with the first of their photos, as the generator teased them
before the Header was a component.

## Files

- `HouseStyle.swift` – page, columns, type sizes, colours, the front-page template and the folio's measurements.
- `Composer.swift` – TextKit composition: columns that wrap around pictures, copyfitting, the problem markers, PDF export.
- `Components.swift` – components, versions, elements, frames and placements; `Composer+components.swift` draws
  them and turns body and whole-story frames into blocks for the page; `Composer+teasers.swift` sets a group of
  teaser-headline frames and fills an issue field's template; `BuiltInComponents.swift` builds the shipped Header
  and Folio, places them on new pages, and migrates an issue saved before them. `Store+Components.swift` is
  placing, moving, resizing, filling, clearing and switching versions; `Store+MultiSelect.swift` the selection
  as a set (⇧-click, the marquee, moving, nudging and deleting several items); `Store+MakeComponent.swift`
  Make Component (the frames a selection becomes, from the composer's geometry);
  `Store+InPlace.swift` editing a placed component in place, Save as New Version and Revert;
  `InPlaceViews.swift` their outlines, menus, the in-place canvas, bar and inspector; `ComponentViews.swift` the selection box,
  the right-click menu, the inspector controls and the sidebar's Components section; `EmptyFrameArt.swift` draws
  an empty frame's rainbow. `ComponentEditor.swift` is the component editor's model (the draft, its versions,
  undo), `ComponentEditor+Pointer.swift` its pointer state machine and snapping, `ComponentEditorView.swift` its
  window, canvas and inspector, and `ComponentFiles.swift` `.typesetcomponent` files, the editor windows and the
  File menu's component commands.
- `Templates.swift` – the template (`IssueTemplate`, the `.typesettemplate` file), The Polytechnic, and what a
  template puts on an issue's pages; `IssueStore+Templates.swift` the template editor's steps (open, save, New
  Template, Save as Template, which template New Issue offers, Duplicate on All Pages, moving and removing pages)
  and their menu commands; `TemplateViews.swift` its toolbar and menus.
- `Generator.swift` – the layout generator: front page from the template, inside pages packed in priority order.
- `Store.swift` – the issue, autosave, undo, snapping, every layout edit.
- `IssueStore+Files.swift` – the issue's file: Save, Save As, Open, Revert, New Issue, the edited mark, the title
  bar. The steps take URLs, so the self-tests drive them without panels; the menu commands add the panels.
- `IssueFile.swift` – the `.typeset` zip: packing and unpacking the issue and its pictures.
- `Library.swift`, `LibraryView.swift` – the library (`library.json`, bookmarks, thumbnails) and its window.
- `PagesScreen.swift` – the canvas, the handles (they only draw), the right-click menus, the inspector.
- `Dragging.swift` – inspector-to-page drags (AppKit drag source over each row; SwiftUI's own drag and drop never
  fired here), the drop preview, resizing by the edges, and `PageDropView`, the one AppKit view over each page.
  It takes every left press, drag and release on the page and 8 screen points past its edge, hands them to the
  store's pointer state machine in page points, and sets the cursor from the hit test; it's also the page's drop
  target. Right-clicks, scrolls and pinches pass through it.
  `--drop-story` fakes a session against the drop target; `--probe x,y` says what the pointer would do there.
- `CanvasPointer.swift` – what the page views share: the hovered item (for the hover outline and the
  right-click menu), the page under a dragged pointer (`PointerRouting`), and the rule that a click doesn't scroll.
- `IDMLExport.swift` – the IDML package: spreads, threaded frames, stories with the copyfit as overrides, links.
- `Headless.swift` – `--render` and `--snapshot`.
