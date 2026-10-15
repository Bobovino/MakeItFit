"""Translation catalogs for Make It Fit.

    python tools/i18n.py extract   # rebuild locale/messages.pot, merge it into every locale/*.po
    python tools/i18n.py check     # report untranslated entries; fail on broken placeholders

The catalogs are gettext files keyed by the English text. Strings are
collected from:
  - tr("..."), tr("...", "context"), tr_n("...", "...", n), atr("...") and
    TranslationServer.translate("...") in scripts/ and style/
  - text/tooltip_text/placeholder_text properties in scenes/*.tscn
  - the player-facing fields of data/levels.json and data/furniture.json,
    which scripts show through Loc.data()
  - line texts and resident names in the rental applications, data/tenants/*.tres
Developer-only screens (the level editor, dev screenshots) are not collected.

Run from the project root. No dependencies beyond the standard library.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCALE_DIR = os.path.join(ROOT, "locale")
POT_PATH = os.path.join(LOCALE_DIR, "messages.pot")

SKIP_FILES = {"LevelEditor.gd", "EditorOverlay.gd", "DevScreenshot.gd", "LevelEditor.tscn"}
SCRIPT_GLOBS = ["scripts/*.gd", "scripts/**/*.gd", "style/*.gd", "style/**/*.gd"]
SCENE_GLOBS = ["scenes/*.tscn", "scenes/**/*.tscn"]

STR = r'"((?:[^"\\]|\\.)*)"'
CALL_RE = re.compile(r'(?<![\w.])(?:tr|atr|TranslationServer\.translate)\(\s*' + STR + r'\s*(?:,\s*' + STR + r'\s*)?\)')
PLURAL_RE = re.compile(r'(?<![\w.])(?:tr_n|atr_n|TranslationServer\.translate_plural)\(\s*' + STR + r'\s*,\s*' + STR
                       + r'\s*,[^,()]*(?:\([^()]*\)[^,()]*)*(?:,\s*' + STR + r')?\s*\)')
SCENE_RE = re.compile(r'^(?:text|tooltip_text|placeholder_text) = ' + STR, re.M | re.S)

# Placeholders GDScript's % operator consumes, in order.
FORMAT_RE = re.compile(r'%(?:%|[-+ 0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?[sdifxXoc])')

PLURAL_FORMS = {
    "de": "nplurals=2; plural=(n != 1);",
    "es": "nplurals=2; plural=(n != 1);",
}


def gd_unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(n, "\\" + n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def po_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\t", "\\t").replace("\n", "\\n")


def po_unescape(s):
    return gd_unescape(s)


class Entry:
    def __init__(self, msgid, ctx="", plural=""):
        self.msgid = msgid
        self.ctx = ctx
        self.plural = plural
        self.refs = []
        self.msgstr = ""
        self.msgstr_n = {}
        self.fuzzy = False
        self.comments = []   # translator comments ("# ...")

    @property
    def key(self):
        return (self.ctx, self.msgid)


def strip_comments(text):
    """Blank out GDScript comments (keeping line numbers), so commented-out
    or documented tr() calls are not collected."""
    out = []
    for line in text.split("\n"):
        quote, i = None, 0
        while i < len(line):
            c = line[i]
            if quote:
                if c == "\\":
                    i += 1
                elif c == quote:
                    quote = None
            elif c in "\"'":
                quote = c
            elif c == "#":
                line = line[:i]
                break
            i += 1
        out.append(line)
    return "\n".join(out)


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def collect():
    entries = {}

    def add(msgid, ctx, ref, plural=""):
        if msgid.strip() == "":
            return
        key = (ctx, msgid)
        e = entries.get(key)
        if e is None:
            e = entries[key] = Entry(msgid, ctx, plural)
        if plural and not e.plural:
            e.plural = plural
        if ref not in e.refs:
            e.refs.append(ref)

    def files(globs):
        seen = []
        for g in globs:
            for f in sorted(glob.glob(os.path.join(ROOT, g), recursive=True)):
                if os.path.basename(f) not in SKIP_FILES and f not in seen:
                    seen.append(f)
        return seen

    for path in files(SCRIPT_GLOBS):
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        raw = open(path, encoding="utf-8").read()
        # A constant can't call tr(), so one whose values are shown to the
        # player is marked with a "# i18n-const" comment on the line before
        # it, and translated with tr() where it is used.
        for m in re.finditer(r"#\s*i18n-const[^\n]*\n", raw):
            start, depth, i = m.end(), 0, m.end()
            while i < len(raw):
                c = raw[i]
                if c == '"':
                    j = i + 1
                    while j < len(raw) and raw[j] != '"':
                        j += 2 if raw[j] == "\\" else 1
                    lit = raw[i + 1:j]
                    after = raw[j + 1:].lstrip(" \t")
                    if not after.startswith(":") and re.search(r"[A-Za-z]{2,}", lit):
                        add(gd_unescape(lit), "", "%s:%d" % (rel, line_of(raw, i)))
                    i = j + 1
                    continue
                if c in "[{(":
                    depth += 1
                elif c in "]})":
                    depth -= 1
                    if depth == 0:
                        break
                elif c == "\n" and depth == 0 and i > start + 1 and raw[start:i].strip():
                    break
                i += 1
        text = strip_comments(raw)
        for m in CALL_RE.finditer(text):
            add(gd_unescape(m.group(1)), gd_unescape(m.group(2) or ""), "%s:%d" % (rel, line_of(text, m.start())))
        for m in PLURAL_RE.finditer(text):
            add(gd_unescape(m.group(1)), gd_unescape(m.group(3) or ""), "%s:%d" % (rel, line_of(text, m.start())),
                plural=gd_unescape(m.group(2)))

    for path in files(SCENE_GLOBS):
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        text = open(path, encoding="utf-8").read()
        for m in SCENE_RE.finditer(text):
            s = gd_unescape(m.group(1))
            if re.search(r"[A-Za-z]{2,}", s):
                add(s, "", "%s:%d" % (rel, line_of(text, m.start())))

    levels = json.load(open(os.path.join(ROOT, "data/levels.json"), encoding="utf-8"))
    for b in levels.get("blocks", []):
        for k in ("name", "subtitle", "intro"):
            if b.get(k):
                add(b[k], "", "data/levels.json:blocks/%s/%s" % (b.get("id"), k))
    for lv in levels.get("levels", []):
        lid = lv.get("id", "?")
        if lid.startswith("debug"):
            continue
        ref = "data/levels.json:" + lid
        if lv.get("name"):
            add(lv["name"], "", ref)
        t = lv.get("tenant", {})
        for k in ("name", "flavor"):
            if t.get(k):
                add(t[k], "", ref)
        for r in t.get("sightline_requirements", []):
            for k in ("label", "short"):
                if r.get(k):
                    add(r[k], "", ref)
        mi = lv.get("mechanic_intro") or {}
        for k in ("title", "body"):
            if mi.get(k):
                add(mi[k], "", ref)
        for m in lv.get("moments", []):
            if m.get("label"):
                add(m["label"], "", ref)
        for fl in lv.get("apartment", {}).get("floors", []):
            if fl.get("label"):
                add(fl["label"], "", ref)

    # Rental applications: line texts and resident names, shown through tr().
    tres_re = re.compile(r'^(text|display_name) = ' + STR, re.M | re.S)
    for path in sorted(glob.glob(os.path.join(ROOT, "data/tenants/*.tres"))):
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        text = open(path, encoding="utf-8").read()
        for m in tres_re.finditer(text):
            add(gd_unescape(m.group(2)), "", "%s:%d" % (rel, line_of(text, m.start())))

    furniture = json.load(open(os.path.join(ROOT, "data/furniture.json"), encoding="utf-8"))
    for f in furniture.get("furniture", []):
        if f.get("name"):
            add(f["name"], "", "data/furniture.json:" + f.get("id", "?"))
    for p in furniture.get("paintable", []):
        if p.get("label"):
            add(p["label"], "", "data/furniture.json:" + p.get("id", "?"))

    return list(entries.values())


def write_str(out, keyword, s):
    if "\n" in s[:-1]:
        out.append('%s ""' % keyword)
        for part in s.split("\n")[:-1]:
            out.append('"%s"' % po_escape(part + "\n"))
        last = s.split("\n")[-1]
        if last:
            out.append('"%s"' % po_escape(last))
    else:
        out.append('%s "%s"' % (keyword, po_escape(s)))


def write_po(path, entries, lang=None, obsolete=()):
    out = ['msgid ""', 'msgstr ""', '"Project-Id-Version: Make It Fit\\n"', '"MIME-Version: 1.0\\n"',
           '"Content-Type: text/plain; charset=UTF-8\\n"', '"Content-Transfer-Encoding: 8-bit\\n"']
    if lang:
        out.append('"Language: %s\\n"' % lang)
        out.append('"Plural-Forms: %s\\n"' % PLURAL_FORMS.get(lang, "nplurals=2; plural=(n != 1);"))
    out.append("")
    for e in entries:
        for c in e.comments:
            out.append("# " + c)
        for r in e.refs[:6]:
            out.append("#: " + r)
        if e.fuzzy and lang:
            out.append("#, fuzzy")
        if e.ctx:
            write_str(out, "msgctxt", e.ctx)
        write_str(out, "msgid", e.msgid)
        if e.plural:
            write_str(out, "msgid_plural", e.plural)
            n = 2
            for i in range(n):
                write_str(out, "msgstr[%d]" % i, e.msgstr_n.get(i, "") if lang else "")
        else:
            write_str(out, "msgstr", e.msgstr if lang else "")
        out.append("")
    for e in obsolete:
        if not (e.msgstr or e.msgstr_n):
            continue
        if e.ctx:
            out.append('#~ msgctxt "%s"' % po_escape(e.ctx))
        out.append('#~ msgid "%s"' % po_escape(e.msgid))
        out.append('#~ msgstr "%s"' % po_escape(e.msgstr or e.msgstr_n.get(0, "")))
        out.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))


def read_po(path):
    entries, cur, field, idx = [], None, None, None
    flags, comments = [], []

    def finish():
        nonlocal cur
        if cur is not None and cur.msgid != "":
            entries.append(cur)
        cur = None

    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if line.startswith("#~") or line.strip() == "":
            if line.strip() == "":
                finish()
            continue
        if line.startswith("#,"):
            flags += [x.strip() for x in line[2:].split(",")]
            continue
        if line.startswith("#:") or line.startswith("#."):
            continue
        if line.startswith("#"):
            comments.append(line[1:].strip())
            continue
        m = re.match(r'(msgctxt|msgid_plural|msgid|msgstr(?:\[(\d+)\])?)\s+"(.*)"$', line)
        if m:
            kw = m.group(1)
            if kw in ("msgctxt",) or (kw == "msgid" and (cur is None or field not in ("msgctxt",))):
                finish()
                cur = Entry("")
                cur.fuzzy = "fuzzy" in flags
                cur.comments = comments
                flags, comments = [], []
            field = kw.split("[")[0]
            idx = int(m.group(2)) if m.group(2) else None
            val = po_unescape(m.group(3))
            if field == "msgctxt":
                cur.ctx = val
            elif field == "msgid":
                cur.msgid = val
            elif field == "msgid_plural":
                cur.plural = val
            elif idx is not None:
                cur.msgstr_n[idx] = val
            else:
                cur.msgstr = val
            continue
        m = re.match(r'"(.*)"$', line)
        if m and cur is not None:
            val = po_unescape(m.group(1))
            if field == "msgctxt":
                cur.ctx += val
            elif field == "msgid":
                cur.msgid += val
            elif field == "msgid_plural":
                cur.plural += val
            elif idx is not None:
                cur.msgstr_n[idx] = cur.msgstr_n.get(idx, "") + val
            else:
                cur.msgstr += val
    finish()
    return entries


def extract():
    entries = collect()
    os.makedirs(LOCALE_DIR, exist_ok=True)
    write_po(POT_PATH, entries)
    print("%d strings -> %s" % (len(entries), os.path.relpath(POT_PATH, ROOT)))
    for lang in PLURAL_FORMS:
        path = os.path.join(LOCALE_DIR, lang + ".po")
        old = {e.key: e for e in read_po(path)} if os.path.exists(path) else {}
        merged = []
        for e in entries:
            n = Entry(e.msgid, e.ctx, e.plural)
            n.refs = e.refs
            o = old.pop(e.key, None)
            if o:
                n.msgstr, n.msgstr_n, n.fuzzy, n.comments = o.msgstr, o.msgstr_n, o.fuzzy, o.comments
            merged.append(n)
        write_po(path, merged, lang, obsolete=old.values())
        done = sum(1 for e in merged if is_translated(e))
        print("%s: %d/%d translated, %d obsolete kept" % (lang, done, len(merged), len(old)))


def is_translated(e):
    if e.fuzzy:
        return False
    if e.plural:
        return all(e.msgstr_n.get(i) for i in range(2))
    return bool(e.msgstr)


def placeholders(s):
    return [p for p in FORMAT_RE.findall(s) if p != "%%"]


def check():
    errors = 0
    for lang in PLURAL_FORMS:
        path = os.path.join(LOCALE_DIR, lang + ".po")
        if not os.path.exists(path):
            print("%s: missing (run extract)" % lang)
            errors += 1
            continue
        entries = read_po(path)
        missing = [e for e in entries if not is_translated(e)]
        for e in entries:
            pairs = [(e.msgid, e.msgstr)] if not e.plural else \
                [(e.msgid, e.msgstr_n.get(0, "")), (e.plural, e.msgstr_n.get(1, ""))]
            for src, dst in pairs:
                if dst and placeholders(src) != placeholders(dst):
                    errors += 1
                    print("%s: placeholders differ\n  en: %r\n  %s: %r" % (lang, src, lang, dst))
        print("%s: %d/%d translated" % (lang, len(entries) - len(missing), len(entries)))
        if "-v" in sys.argv:
            for e in missing:
                print("  untranslated: %r" % e.msgid[:80])
    print("RESULT: %s" % ("FAIL" if errors else "OK"))
    return 1 if errors else 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "extract":
        extract()
    elif cmd == "check":
        sys.exit(check())
    else:
        print(__doc__)
        sys.exit(2)
