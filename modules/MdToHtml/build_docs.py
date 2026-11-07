"""MD 원본 -> 디자인이 적용된 HTML 변환기.

사용법 (보통은 상위 폴더의 .bat 파일을 더블클릭하면 됩니다)
  build_docs.py                 상위 폴더의 모든 .md 변환 후 브라우저로 열기
  build_docs.py 파일.md ...      지정한 파일만 변환 (bat에 끌어다 놓기)
  build_docs.py --watch         .md 저장 감시 -> 자동 변환 + 브라우저 자동 새로고침
  build_docs.py --no-open 파일.md  변환만 하고 브라우저는 열지 않음 (AI가 실행할 때)
  build_docs.py --live 파일.md   열린 브라우저가 자동 새로고침되는 HTML로 변환 (UtilMonster 자동 변환용)

UtilMonster 의 'MD → HTML' 탭이 이 파일을 실행합니다. (원본: MDtoHTML 프로젝트의 tools 폴더)
디자인은 같은 폴더의 template.html / style.css / docs.js 에서만 바꿉니다.
"""
import html
import importlib
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent                      # bat 파일과 .md 파일이 있는 폴더
LIB = TOOLS / "_lib"                     # 필요한 부품을 여기에만 설치 (PC 전체에 영향 없음)
DESIGN_FILES = [TOOLS / "template.html", TOOLS / "style.css", TOOLS / "docs.js", Path(__file__).resolve()]
SKIP_NAMES = {"claude.md", "agents.md", "readme.md"}   # 폴더 전체 변환 시 제외

# 표 칸의 내용이 정확히 이 단어면 색상 태그로 표시
TAGS = {
    "높음": "good", "P0": "good", "장기 핵심": "good",
    "중간": "mid", "중상": "mid", "중하": "mid", "P1": "mid", "현실적 과도기": "mid",
    "낮음": "risk", "고위험": "risk", "P2": "risk", "별도 검증": "risk",
}
# 인용문(>) 첫 굵은 글씨에 이 단어가 있으면 노란 '주의' 박스
WARN_WORDS = re.compile(r"주의|경고|위험|미확정|금지|정정")
# GitHub 방식 강조 박스: > [!WARNING]
CALLOUT = re.compile(r"^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*", re.I)
CALLOUT_CLASS = {"NOTE": "note", "TIP": "note", "IMPORTANT": "lead", "WARNING": "note warn", "CAUTION": "note warn"}

sys.path.insert(0, str(LIB))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def ensure_libs():
    try:
        import markdown, mdx_truly_sane_lists  # noqa: F401
    except ImportError:
        print("처음 실행: 변환에 필요한 부품을 설치합니다 (한 번만, 약 10초)...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "--disable-pip-version-check",
                               "--target", str(LIB), "markdown", "mdx_truly_sane_lists"])
        importlib.invalidate_caches()


def text_of(el):
    return "".join(el.itertext()).strip()


# ---------------------------------------------------------------- 문서 구조 가공
def make_layout_extension():
    from markdown.extensions import Extension
    from markdown.treeprocessors import Treeprocessor

    class Layout(Treeprocessor):
        """Markdown 변환 결과를 기존 계획서 디자인 구조(hero / chapter / note ...)로 재배치."""

        def run(self, root):
            kids = list(root)
            for k in kids:
                root.remove(k)
            hero, sections, cur = [], [], None
            for el in kids:
                if el.tag == "hr":                       # 장 사이 --- 는 장 구분선으로 대체
                    continue
                if el.tag == "h2":
                    cur = (el, [])
                    sections.append(cur)
                elif cur is None:
                    hero.append(el)
                else:
                    cur[1].append(el)

            self.md.doc_info = info = {"title": "", "nav": [], "chapters": 0}
            self.build_hero(root, hero, info)
            for h2, items in sections:
                self.build_section(root, h2, items, info)

            for td in list(root.iter("td")):
                word = (td.text or "").strip()
                if len(td) == 0 and word in TAGS:
                    td.text = None
                    ET.SubElement(td, "span", {"class": "tag " + TAGS[word]}).text = word
            for a in root.iter("a"):
                if a.get("href", "").startswith(("http://", "https://")):
                    a.set("target", "_blank")
                    a.set("rel", "noopener")

        def build_hero(self, root, items, info):
            header = ET.SubElement(root, "header", {"class": "hero"})
            rest, has_meta, has_desc = [], False, False
            for el in items:
                if el.tag == "h1" and not info["title"]:
                    info["title"] = text_of(el)
                    header.append(el)
                elif el.tag == "blockquote" and not has_meta:
                    has_meta = True
                    header.append(self.meta_chips(el))
                elif el.tag == "p" and not has_desc:
                    has_desc = True
                    header.append(el)
                else:
                    rest.append(el)
            bar = ET.SubElement(header, "div", {"class": "toolbar"})
            ET.SubElement(bar, "button", {"class": "btn primary", "onclick": "window.print()"}).text = "인쇄 / PDF 저장"
            if rest:
                box = ET.SubElement(root, "div", {"class": "revision-notice"})
                box.extend(rest)

        @staticmethod
        def meta_chips(bq):
            """> 줄1  \n> 줄2 형태의 인용문 -> 둥근 정보 칩."""
            meta = ET.Element("div", {"class": "meta"})
            for p in bq:
                chip = ET.Element("span")
                chip.text = (p.text or "").lstrip()
                for child in list(p):
                    if child.tag == "br":
                        if text_of(chip):
                            meta.append(chip)
                        chip = ET.Element("span")
                        chip.text = (child.tail or "").lstrip()
                    else:
                        chip.append(child)
                if text_of(chip):
                    meta.append(chip)
            return meta

        def build_section(self, root, h2, items, info):
            sid = h2.attrib.pop("id", "") or f"chapter-{len(info['nav']) + 1}"
            sec = ET.SubElement(root, "section", {"class": "chapter", "id": sid})
            head = ET.SubElement(sec, "div", {"class": "chapterhead"})
            # 제목 바로 아래 *기울임 한 줄* -> 제목 위 작은 부제
            if items and self.is_overline(items[0]):
                ET.SubElement(head, "span", {"class": "overline"}).text = text_of(items.pop(0))
            head.append(h2)
            for i, el in enumerate(items):
                if el.tag == "blockquote":
                    self.callout(el, first=(i == 0))
                sec.append(el)
            title = text_of(h2)
            m = re.match(r"^(\d+)\s*[·.:\-]\s*(.+)$", title)
            info["nav"].append((sid, m.group(1) if m else "•", m.group(2) if m else title))
            info["chapters"] += 1

        @staticmethod
        def is_overline(el):
            return (el.tag == "p" and len(el) == 1 and el[0].tag == "em"
                    and not (el.text or "").strip() and not (el[0].tail or "").strip())

        @staticmethod
        def callout(bq, first):
            """인용문(>) -> 강조 박스. [!WARNING] 표시가 있으면 그대로, 없으면 위치·단어로 판단."""
            cls = None
            p0 = bq[0] if len(bq) else None
            if p0 is not None and p0.tag == "p":
                m = CALLOUT.match(p0.text or "")
                if m:
                    cls = CALLOUT_CLASS[m.group(1).upper()]
                    p0.text = p0.text[m.end():]
                    if not (p0.text or "").strip() and len(p0) and p0[0].tag == "br":
                        p0.text = (p0[0].tail or "").lstrip()
                        p0.remove(p0[0])
                    if not text_of(p0) and len(p0) == 0:
                        bq.remove(p0)
            if cls is None:
                label = text_of(p0[0]) if (p0 is not None and len(p0) and p0[0].tag == "strong"
                                             and not (p0.text or "").strip()) else ""
                if WARN_WORDS.search(label):
                    cls = "note warn"
                elif first:
                    cls = "lead"
                else:
                    cls = "note"
            bq.tag = "div"
            bq.set("class", cls)

    class LayoutExtension(Extension):
        def extendMarkdown(self, md):
            md.treeprocessors.register(Layout(md), "doc_layout", -1)   # 다른 처리가 모두 끝난 뒤 실행

    return LayoutExtension()


# ---------------------------------------------------------------- 변환
def read_md(path):
    raw = path.read_bytes()
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        print(f"  (알림) {path.name} 이 UTF-8이 아니라서 한글 Windows 형식(CP949)으로 읽었습니다.")
        return raw.decode("cp949")


def reload_file(out):
    return out.with_name(out.stem + ".reload.js")


def build(md_path, live=False):
    import markdown
    from markdown.extensions.toc import slugify_unicode

    started = time.perf_counter()
    md = markdown.Markdown(
        extensions=["tables", "fenced_code", "toc", "mdx_truly_sane_lists", make_layout_extension()],
        extension_configs={"toc": {"slugify": slugify_unicode},
                           "mdx_truly_sane_lists": {"nested_indent": 2}},
    )
    body = md.convert(read_md(md_path))
    info = md.doc_info
    title = info["title"] or md_path.stem
    out = md_path.with_suffix(".html")
    # 감시 창이 켜져 있으면(신호 파일 존재) 일반 변환도 자동 새로고침 기능을 유지
    live = live or reload_file(out).exists()

    nav = "".join(f'<a href="#{html.escape(sid)}"><span>{html.escape(num)}</span>{html.escape(label)}</a>'
                  for sid, num, label in info["nav"])
    values = {
        "NOTICE": f"자동 생성 파일입니다. 원본: {md_path.name} - 이 HTML을 직접 고치지 마세요 (다음 변환 때 덮어써집니다).",
        "TITLE": html.escape(title),
        "STYLE": (TOOLS / "style.css").read_text(encoding="utf-8"),
        "SCRIPT": (TOOLS / "docs.js").read_text(encoding="utf-8"),
        "NAV": nav,
        "CONTENT": body,
        "BUILD_NOTE": html.escape(f"{md_path.name} 에서 자동 생성 · {datetime.now():%Y-%m-%d %H:%M}"),
        "BODY_ATTR": f' data-reload="{html.escape(reload_file(out).name)}"' if live else "",
    }
    template = (TOOLS / "template.html").read_text(encoding="utf-8")
    page = re.sub(r"\{\{(\w+)\}\}", lambda m: values.get(m.group(1), m.group(0)), template)

    tmp = out.with_name(out.name + ".tmp")          # 브라우저가 반쯤 쓴 파일을 읽지 않도록
    tmp.write_text(page, encoding="utf-8", newline="\n")
    os.replace(tmp, out)
    if live:
        reload_file(out).write_text(f'window.__mdStamp="{time.time_ns()}";\n', encoding="utf-8")
    print(f"[완료] {out.name}  (장 {info['chapters']}개, {time.perf_counter() - started:.1f}초)")
    return out


def folder_md_files():
    return sorted(p for p in ROOT.glob("*.md") if p.name.lower() not in SKIP_NAMES)


def safe_build(path, live=False):
    try:
        return build(path, live)
    except Exception as e:  # 한 파일이 실패해도 나머지는 계속
        print(f"[실패] {path.name}: {type(e).__name__}: {e}")
        return None


def open_in_browser(paths):
    for p in paths[:3]:
        os.startfile(p)


# ---------------------------------------------------------------- 감시 모드
def watch():
    def snapshot():
        files = folder_md_files() + DESIGN_FILES
        return {p: p.stat().st_mtime_ns for p in files if p.exists()}

    print(f"감시 폴더: {ROOT}")
    outs = [o for o in (safe_build(p, live=True) for p in folder_md_files()) if o]
    open_in_browser(outs)
    print("\nMD 파일을 저장하면 HTML이 자동으로 다시 만들어지고, 열린 브라우저도 자동 새로고침됩니다.")
    print("끝내려면 이 창을 닫으세요.\n")
    last = snapshot()
    try:
        while True:
            time.sleep(1)
            try:
                now = snapshot()
            except OSError:          # 저장 도중 파일이 잠깐 사라지는 경우
                continue
            if now == last:
                continue
            time.sleep(0.4)          # 저장이 끝날 때까지 잠깐 대기
            try:
                now = snapshot()
            except OSError:
                continue
            design_changed = any(now.get(p) != last.get(p) for p in DESIGN_FILES)
            targets = folder_md_files() if design_changed else [p for p in now if p.suffix == ".md" and now[p] != last.get(p)]
            stamp = datetime.now().strftime("%H:%M:%S")
            for p in targets:
                print(f"{stamp} 변경 감지: {p.name}")
                safe_build(p, live=True)
            last = now
    except KeyboardInterrupt:
        pass
    finally:
        for p in folder_md_files():
            reload_file(p.with_suffix(".html")).unlink(missing_ok=True)


# ---------------------------------------------------------------- 시작
def main(args):
    ensure_libs()
    if "--watch" in args:
        watch()
        return 0
    no_open = "--no-open" in args            # AI가 실행할 때: 브라우저를 열지 않음
    live = "--live" in args                  # 감시는 UtilMonster 가 하고, 변환만 자동 새로고침 방식으로
    args = [a for a in args if not a.startswith("--")]
    if args:
        paths = [Path(a) for a in args]
        bad = [p for p in paths if p.suffix.lower() != ".md" or not p.exists()]
        for p in bad:
            print(f"[건너뜀] .md 파일이 아닙니다: {p.name}")
        paths = [p.resolve() for p in paths if p not in bad]
    else:
        paths = folder_md_files()
        if not paths:
            print(f"변환할 .md 파일이 없습니다: {ROOT}")
            return 1
    outs = [safe_build(p, live) for p in paths]
    ok = [o for o in outs if o]
    if not no_open:
        open_in_browser(ok)
    return 0 if len(ok) == len(outs) and ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
