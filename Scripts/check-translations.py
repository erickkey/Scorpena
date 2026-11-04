#!/usr/bin/env python3
"""Every text the app shows has a translation, nothing is doubled, placeholders match, and the
punctuation follows the Russian original (dashes, question marks, ellipses)."""
import glob, re, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Scorpena")
loc = open(os.path.join(SRC, "Localization.swift"), encoding="utf-8").read()
more = open(os.path.join(SRC, "TranslationsMore.swift"), encoding="utf-8").read()
PAIR = r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*\n?\s*"((?:[^"\\]|\\.)*)"\s*,'
problems = []

def section(text, name):
    a = text.index(f"static let {name}:")
    return text[a:text.index("\n    ]", a)]

tables = {"en": re.findall(PAIR, section(loc, "en"), re.M)}
for name in ("zh", "hi", "es"):
    tables[name] = re.findall(PAIR, section(more, name), re.M)

def placeholders(t): return sorted(re.findall(r'%[@d.0-9fl]*[@dfs]|%%', t))
def norm(t): return re.sub('[«»“”"]', "", t)       # quote marks differ by language: they do not count as an ending
def end(t):
    m = re.search(r'(…|[.!?:;,)])\s*$', norm(t).rstrip()); return m.group(1) if m else ""

for name, pairs in tables.items():
    keys = [k for k, _ in pairs]
    for k in set(keys):
        if keys.count(k) > 1: problems.append(f"{name}: duplicate key «{k[:60]}»")   # a duplicate crashes the app
    for k, v in pairs:
        if placeholders(k) != placeholders(v): problems.append(f"{name}: placeholders differ in «{k[:60]}»")
        if name == "en":
            if end(k) != end(v): problems.append(f"en: ending differs in «{k[:60]}»")
            if len(re.findall(r'[—–]', k)) != len(re.findall(r'[—–]', v)): problems.append(f"en: dashes differ in «{k[:60]}»")

# every text used by the code has an English translation
code = "\n".join(open(f, encoding="utf-8").read() for f in glob.glob(os.path.join(SRC, "*.swift"))
                 if not f.endswith(("Localization.swift", "TranslationsMore.swift")))
used = {m.group(1) for m in re.finditer(r'\btrf?\(\s*"((?:[^"\\]|\\.)*)"', code)}
english = {k for k, _ in tables["en"]}
for u in sorted(used):
    if u and u not in english: problems.append(f"no English text for «{u[:60]}»")

# the current «Что нового» is translated everywhere
ver = re.search(r'APP_VERSION="([^"]+)"', open(os.path.join(ROOT, "Scripts", "build-app.sh")).read()).group(1)
block = re.search(r'"%s": \[\n(.*?)\n        \],' % re.escape(ver), code, re.S)
if block:
    for line in re.findall(r'^\s*"((?:[^"\\]|\\.)*)",?$', block.group(1), re.M):
        text = line[3:] if line.startswith("## ") else line
        for name in ("en", "zh", "hi", "es"):
            if text not in {k for k, _ in tables[name]}: problems.append(f"{name}: «Что нового» {ver} not translated: «{text[:50]}»")

for p in problems: print("FAIL ", p)
print("ALL OK" if not problems else f"FAILURES: {len(problems)}")
sys.exit(1 if problems else 0)
