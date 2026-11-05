#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
"""Build the reference body in `docs/api.html` from the interfaces MoonBit prints.

The public surface comes from `src/<package>/pkg.generated.mbti`, which `moon info`
writes and nothing here invents. The prose comes from the `///` comments beside the
declarations, so the page cannot describe a signature the compiler does not have, and
a name added to a package shows up here without anybody remembering to add it.

    python3 scripts/gen_api.py
    git diff --exit-code docs/api.html

CI runs the generator and fails on a difference, so the page and the interfaces move
together. Derived methods and trait implementations are listed by name under the type
that has them, rather than as entries of their own: they are part of the surface, and
forty rows of `equal` would bury the eight that a reader came for.

Only the Python standard library is used.
"""

from __future__ import annotations

import html
import pathlib
import re
import sys
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGET = ROOT / "docs" / "api.html"
# The name a section is anchored under, and the directory its interface is read
# from. They differ where a package is nested: an anchor with a slash in it is not
# something a URL can carry.
PACKAGES = (
    ("trace", "trace"),
    ("propagate", "propagate"),
    ("asgi", "asgi"),
    ("log", "log"),
    ("semconv", "semconv"),
    ("otlp", "otlp"),
    ("otlp-http", "otlp/http"),
    ("otlp-grpc", "otlp/grpc"),
    ("otlp-p8s", "otlp/p8s"),
    ("log-moonlog", "log/moonlog_bridge"),
)

# Methods every type with a derive or an implementation has, in no useful order.
NOISE = {"equal", "not_equal", "to_repr", "to_string", "output"}

DECL = re.compile(
    r"^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?"
    r"(fn|struct|enum|suberror|trait|type|let)\s+([A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)?)"
)
IMPL = re.compile(r"^(?:pub\s+)?impl\s+(.+?)\s+for\s+([A-Za-z0-9_@.]+)")
TYPE_DECL = re.compile(
    r"^pub(?:\([^)]*\))?\s+(struct|enum|suberror|trait)\s+([A-Za-z0-9_]+)\s*\{"
)
METHOD = re.compile(r"^pub fn ([A-Za-z0-9_]+)::([A-Za-z0-9_]+)(\(.*)$")
VALUE_LET = re.compile(r"^pub let ([A-Za-z0-9_]+) : (.+)$")
VALUE_FN = re.compile(r"^pub fn ([A-Za-z0-9_]+)(\(.*)$")
DERIVE = re.compile(r"derive\((.*)\)")


@dataclass
class Method:
    name: str
    short: str
    signature: str
    doc: str = ""


@dataclass
class Entry:
    kind: str
    name: str
    signature: str = ""
    doc: str = ""
    fields: list[tuple[str, str, str]] = field(default_factory=list)
    variants: list[tuple[str, str, str]] = field(default_factory=list)
    methods: list[Method] = field(default_factory=list)
    hidden: list[Method] = field(default_factory=list)
    derives: list[str] = field(default_factory=list)
    impls: list[str] = field(default_factory=list)


def read_doc(lines: list[str], start: int) -> tuple[str, int]:
    """The doc comment that begins at `start`, and the index after it."""
    block: list[str] = []
    index = start
    while index < len(lines) and lines[index].lstrip().startswith("///"):
        text = lines[index].lstrip()[3:]
        if text == "|":
            block.append("")
        elif text.startswith(" "):
            block.append(text[1:])
        else:
            block.append(text)
        index += 1
    return "\n".join(block).strip("\n"), index


def collect_docs(directory: pathlib.Path) -> dict[str, str]:
    """Every doc comment in the package, keyed the way the generator looks it up."""
    docs: dict[str, str] = {}
    for path in sorted(directory.glob("*.mbt")):
        name = path.name
        if name.endswith(("_test.mbt", "_wbtest.mbt")) or "generated" in name:
            continue
        lines = path.read_text(encoding="utf-8").splitlines()

        # Declarations: a doc block immediately above the thing it documents.
        index = 0
        while index < len(lines):
            if not lines[index].lstrip().startswith("///"):
                index += 1
                continue
            doc, index = read_doc(lines, index)
            # Attributes (`#derive(...)`, `#coverage.skip`, …) sit between a doc
            # block and the declaration it documents; the formatter moves them
            # there, so they must not break the link.
            look = index
            while look < len(lines) and (
                not lines[look].strip() or lines[look].lstrip().startswith("#")
            ):
                look += 1
            if look >= len(lines):
                break
            line = lines[look].strip()
            declaration = DECL.match(line)
            if declaration:
                docs[f"{declaration.group(1)} {declaration.group(2)}"] = doc
            else:
                implementation = IMPL.match(line)
                if implementation:
                    trait = " ".join(implementation.group(1).split())
                    owner = implementation.group(2)
                    docs[f"impl {trait} for {owner}"] = doc
                    # `pub impl Layer for Tracing with fn wrap(...)`: the method a
                    # reader will look up is `wrap`, and this is its documentation.
                    inline = re.search(r"with fn ([A-Za-z0-9_]+)", line)
                    if inline:
                        docs[f"fn {owner}::{inline.group(1)}"] = doc
            index = look

        # Members: a doc block inside a struct, an enum or a trait.
        index = 0
        while index < len(lines):
            line = lines[index].strip()
            declaration = TYPE_DECL.match(line)
            if not declaration:
                index += 1
                continue
            owner = declaration.group(2)
            depth = 1
            index += 1
            while index < len(lines) and depth > 0:
                body = lines[index]
                depth += body.count("{") - body.count("}")
                if depth <= 0:
                    break
                if body.lstrip().startswith("///"):
                    doc, after = read_doc(lines, index)
                    look = after
                    while look < len(lines) and (
                        not lines[look].strip() or lines[look].lstrip().startswith("#")
                    ):
                        look += 1
                    if look < len(lines):
                        member = re.match(
                            r"^(?:fn\s+)?([A-Za-z0-9_]+)", lines[look].strip()
                        )
                        if member:
                            docs.setdefault(f"{owner}::{member.group(1)}", doc)
                    index = look
                    continue
                index += 1
            index += 1
    return docs


def split_derive(line: str) -> list[str]:
    found = DERIVE.search(line)
    if not found:
        return []
    names = []
    for part in found.group(1).split(","):
        name = part.strip().split(".")[-1]
        if name:
            names.append(name)
    return names


def interface_path(directory: str) -> Path:
    """The interface file of one package.

    `moon info` writes the canonical backend's interface and skips a package that
    cannot build for that backend, which is what a native-only package is. `moon
    check --target native` leaves the same file under `_build`, so that is where a
    package like that is read from — which is why the docs are generated after a
    check.
    """
    source = ROOT / "src" / directory / "pkg.generated.mbti"
    if source.exists():
        return source
    found = sorted((ROOT / "_build" / "native").glob(f"*/check/{directory}/*.mbti"))
    if not found:
        raise SystemExit(
            f"no interface for {directory}: run `moon check --target native` first"
        )
    return found[-1]


def parse_mbti(path: pathlib.Path, docs: dict[str, str]) -> dict[str, list[Entry]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    out: dict[str, list[Entry]] = {
        "values": [],
        "errors": [],
        "types": [],
        "traits": [],
    }
    section = None
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("// "):
            heading = line[3:].strip()
            section = {
                "Values": "values",
                "Errors": "errors",
                "Types and methods": "types",
                "Traits": "traits",
            }.get(heading)
            index += 1
            continue
        if not line.strip():
            index += 1
            continue

        if section == "values":
            block = []
            while index < len(lines) and lines[index].strip() and not lines[index].startswith("//"):
                block.append(lines[index].strip())
                index += 1
            text = " ".join(block)
            let = VALUE_LET.match(text)
            if let:
                name, rest = let.group(1), let.group(2)
                out["values"].append(
                    Entry(
                        kind="let",
                        name=name,
                        signature=f": {rest}",
                        doc=docs.get(f"let {name}", ""),
                    )
                )
                continue
            function = VALUE_FN.match(text)
            if function:
                name, rest = function.group(1), function.group(2)
                out["values"].append(
                    Entry(
                        kind="fn",
                        name=name,
                        signature=rest,
                        doc=docs.get(f"fn {name}", ""),
                    )
                )
                continue

        if section in ("errors", "types"):
            declaration = TYPE_DECL.match(line.strip())
            if not declaration:
                index += 1
                continue
            kind, name = declaration.group(1), declaration.group(2)
            decl_index = index
            body: list[str] = []
            depth = 1
            index += 1
            closing = ""
            while index < len(lines) and depth > 0:
                current = lines[index]
                depth += current.count("{") - current.count("}")
                if depth <= 0:
                    closing = current
                    break
                body.append(current)
                index += 1

            # `moon info` prints a derived trait set as `#derive(...)` on the line
            # above the declaration rather than after the closing brace; read both
            # spellings so the meta line survives a formatter run.
            derives = split_derive(closing)
            probe = decl_index - 1
            while probe >= 0 and not lines[probe].strip():
                probe -= 1
            if probe >= 0 and lines[probe].lstrip().startswith("#derive("):
                for trait in split_derive(lines[probe]):
                    if trait not in derives:
                        derives.append(trait)

            entry = Entry(
                kind="suberror" if kind == "suberror" else kind,
                name=name,
                doc=docs.get(f"{kind} {name}", ""),
                derives=derives,
            )
            for member in body:
                text = member.strip()
                if not text:
                    continue
                if kind == "enum" or kind == "suberror":
                    variant = re.match(r"^([A-Za-z0-9_]+)(.*)$", text)
                    if variant:
                        entry.variants.append(
                            (
                                variant.group(1),
                                variant.group(2).strip(),
                                docs.get(f"{name}::{variant.group(1)}", ""),
                            )
                        )
                else:
                    field_match = re.match(r"^([A-Za-z0-9_]+)\s*:\s*(.*)$", text)
                    if field_match:
                        entry.fields.append(
                            (
                                field_match.group(1),
                                field_match.group(2).strip(),
                                docs.get(f"{name}::{field_match.group(1)}", ""),
                            )
                        )

            index += 1
            while index < len(lines) and lines[index].strip() and not lines[index].startswith("//"):
                text = lines[index].strip()
                method = METHOD.match(text)
                if method:
                    owner, short, signature = (
                        method.group(1),
                        method.group(2),
                        method.group(3),
                    )
                    entry.methods.append(
                        Method(
                            name=f"{owner}::{short}",
                            short=short,
                            signature=signature,
                            doc=docs.get(f"fn {owner}::{short}", ""),
                        )
                    )
                implementation = re.match(r"^pub impl (.+)$", text)
                if implementation:
                    entry.impls.append(implementation.group(1).strip())
                index += 1

            bucket = "errors" if kind == "suberror" else "types"
            out[bucket].append(entry)
            continue

        if section == "traits":
            declaration = TYPE_DECL.match(line.strip())
            if not declaration:
                index += 1
                continue
            name = declaration.group(2)
            entry = Entry(kind="trait", name=name, doc=docs.get(f"trait {name}", ""))
            index += 1
            depth = 1
            while index < len(lines) and depth > 0:
                text = lines[index].strip()
                depth += text.count("{") - text.count("}")
                if depth <= 0:
                    break
                method = re.match(r"^fn ([A-Za-z0-9_]+)(\(.*)$", text)
                if method:
                    short, signature = method.group(1), method.group(2)
                    entry.methods.append(
                        Method(
                            name=f"{name}::{short}",
                            short=short,
                            signature=signature,
                            doc=docs.get(f"{name}::{short}")
                            or docs.get(f"fn {short}", ""),
                        )
                    )
                index += 1
            index += 1
            out["traits"].append(entry)
            continue

        index += 1
    return out


class Anchors:
    """Every entry's id, and which bare name is unambiguous enough to link."""

    def __init__(self) -> None:
        self.by_package: dict[tuple[str, str], str] = {}
        self.unique: dict[str, str | None] = {}

    def add(self, package: str, key: str, anchor: str) -> None:
        self.by_package[(package, key)] = anchor
        if key not in self.unique:
            self.unique[key] = anchor
        elif self.unique[key] != anchor:
            self.unique[key] = None

    def resolve(self, package: str, key: str) -> str | None:
        key = key.strip()
        if key.startswith("@"):
            key = key.split(".", 1)[-1]
        if (package, key) in self.by_package:
            return self.by_package[(package, key)]
        if key in self.unique and self.unique[key]:
            return self.unique[key]
        short = key.split("::")[-1]
        if (package, short) in self.by_package:
            return self.by_package[(package, short)]
        if short in self.unique and self.unique[short]:
            return self.unique[short]
        return None


def inline(
    text: str, package: str, anchors: Anchors, exclude: str | None = None
) -> str:
    """A paragraph or a comment line, with inline code and links."""
    text = html.escape(text, quote=False)

    def code(match: re.Match[str]) -> str:
        raw = match.group(1)
        target = anchors.resolve(package, raw)
        inner = html.escape(raw, quote=False)
        if target and target != exclude:
            return f'<a href="#{target}"><code>{inner}</code></a>'
        return f"<code>{inner}</code>"

    text = re.sub(r"`([^`]+)`", code, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text


def paragraphs(
    doc: str, package: str, anchors: Anchors, exclude: str | None = None
) -> str:
    if not doc.strip():
        return ""
    chunks = re.split(r"\n\s*\n", doc.strip())
    return "\n".join(
        f"<p>{inline(chunk.replace(chr(10), ' '), package, anchors, exclude)}</p>"
        for chunk in chunks
    )


def entry_id(package: str, name: str) -> str:
    return f"{package}-{name.replace('::', '-')}"


def render_entry(
    entry: Entry,
    package: str,
    anchors: Anchors,
    *,
    method: bool = False,
    group_title: str | None = None,
) -> str:
    anchor = entry_id(package, entry.name)
    kind = {
        "let": "let",
        "fn": "fn",
        "struct": "struct",
        "enum": "enum",
        "suberror": "error",
        "trait": "trait",
    }.get(entry.kind, entry.kind)
    classes = "api-entry api-method" if method else "api-entry"
    if entry.kind in ("struct", "enum", "suberror", "trait") and not method:
        classes += " api-type"

    meta = ""
    if not method:
        tags = list(entry.derives)
        tags += [impl.split(" for ")[0].replace("pub impl ", "") for impl in entry.impls]
        if tags:
            meta = f'<span class="api-meta">{" · ".join(tags)}</span>'

    signature = html.escape(entry.signature, quote=False)
    call = f'<code class="api-name">{html.escape(entry.name)}</code>'
    if signature:
        call += f'<code class="api-sig">{signature}</code>'
    lines = [
        f'<article class="{classes}" id="{anchor}" data-name="{html.escape(entry.name)}">',
        '  <div class="api-line">',
        f'    <span class="api-kind">{kind}</span>',
        f'    <span class="api-call">{call}</span>',
    ]
    if meta:
        lines.append(f"    {meta}")
    lines.append("  </div>")

    doc = paragraphs(entry.doc, package, anchors, anchor)
    if doc:
        lines.append(f'  <div class="api-doc">{doc}</div>')

    if entry.fields:
        lines.append('  <dl class="api-fields">')
        for name, signature, field_doc in entry.fields:
            lines.append("    <div>")
            lines.append(f'      <dt>{html.escape(name)}</dt>')
            lines.append(f'      <dd>{html.escape(signature, quote=False)}</dd>')
            if field_doc:
                lines.append(
                    f'      <dd class="api-field-doc">{paragraphs(field_doc, package, anchors)}</dd>'
                )
            lines.append("    </div>")
        lines.append("  </dl>")

    if entry.variants:
        lines.append('  <div class="api-variants">')
        for name, signature, variant_doc in entry.variants:
            detail = html.escape(signature, quote=False)
            lines.append('    <div class="api-variant">')
            lines.append(f"      <code>{html.escape(name)}{detail}</code>")
            lines.append(
                f"      <p>{inline(variant_doc, package, anchors) if variant_doc else ''}</p>"
            )
            lines.append("    </div>")
        lines.append("  </div>")

    if entry.methods:
        lines.append('  <div class="api-methods">')
        if group_title:
            lines.append(f'    <h4 class="api-group-title">{group_title}</h4>')
        for child in entry.methods:
            lines.append(
                render_entry(
                    Entry(
                        kind="fn",
                        name=child.name,
                        signature=child.signature,
                        doc=child.doc,
                    ),
                    package,
                    anchors,
                    method=True,
                )
            )
        lines.append("  </div>")

    if not method and entry.hidden:
        names = " · ".join(f"<code>{html.escape(m.short)}</code>" for m in entry.hidden)
        lines.append(
            f'  <p class="api-derived">Also on the type: {names} — derived, '
            f"or required by an implementation above.</p>"
        )

    lines.append("</article>")
    return "\n".join(lines)


def render_group(title: str, entries: list[str]) -> str:
    body = "\n".join(entries)
    return (
        '<div class="api-group">\n'
        f'  <h3 class="api-group-title">{title}</h3>\n'
        f"{body}\n"
        "</div>"
    )


def build_package(parsed: dict[str, list[Entry]], package: str, anchors: Anchors) -> str:
    trait_methods = {
        method.short for entry in parsed["traits"] for method in entry.methods
    }
    groups = []
    if parsed["values"]:
        rendered = [render_entry(entry, package, anchors) for entry in parsed["values"]]
        groups.append(render_group("Values", rendered))
    if parsed["errors"]:
        rendered = []
        for entry in parsed["errors"]:
            entry.hidden = [
                method
                for method in entry.methods
                if method.short in NOISE or method.short in trait_methods
            ]
            entry.methods = [
                method
                for method in entry.methods
                if method.short not in NOISE and method.short not in trait_methods
            ]
            rendered.append(render_entry(entry, package, anchors))
        groups.append(render_group("Errors", rendered))
    if parsed["types"]:
        rendered = []
        for entry in parsed["types"]:
            entry.hidden = [
                method
                for method in entry.methods
                if method.short in NOISE or method.short in trait_methods
            ]
            entry.methods = [
                method
                for method in entry.methods
                if method.short not in NOISE and method.short not in trait_methods
            ]
            rendered.append(render_entry(entry, package, anchors))
        groups.append(render_group("Types and methods", rendered))
    if parsed["traits"]:
        rendered = [render_entry(entry, package, anchors) for entry in parsed["traits"]]
        groups.append(render_group("Traits", rendered))
    return "\n".join(groups)


def register(parsed: dict[str, list[Entry]], package: str, anchors: Anchors) -> None:
    for entry in parsed["values"]:
        anchors.add(package, entry.name, entry_id(package, entry.name))
    for entry in parsed["errors"] + parsed["types"] + parsed["traits"]:
        anchors.add(package, entry.name, entry_id(package, entry.name))
        for child in entry.methods:
            anchors.add(package, child.name, entry_id(package, child.name))


SURFACE = re.compile(
    r"^pub(?:\([^)]*\))?\s+(?:fn|let|struct|enum|suberror|trait)\s+"
    r"([A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)?)",
    re.MULTILINE,
)


def surface_names(path: pathlib.Path) -> list[str]:
    """Every public declaration the interface prints, as its own name."""
    return SURFACE.findall(path.read_text(encoding="utf-8"))


def missing_names(parsed: dict[str, list[Entry]], body: str) -> list[str]:
    """Public names the generated body does not mention.

    Every value, every type and every method has to appear somewhere: as an entry,
    or in the "Also on the type" line that lists what a derive or an implementation
    provided. A name that appears nowhere is a generator bug, and the build should say
    so rather than publish a reference that is quietly a subset.
    """
    missing: list[str] = []
    for entry in parsed["values"]:
        if entry.name not in body:
            missing.append(entry.name)
    for entry in parsed["errors"] + parsed["types"] + parsed["traits"]:
        if entry.name not in body:
            missing.append(entry.name)
        for method in entry.methods + entry.hidden:
            if method.short not in body:
                missing.append(method.name)
    return missing


def main() -> int:
    page = TARGET.read_text(encoding="utf-8")
    parsed = {
        label: parse_mbti(
            interface_path(directory),
            collect_docs(ROOT / "src" / directory),
        )
        for label, directory in PACKAGES
    }

    # `always` is documented on the type it is the value of, which is where a reader
    # looks for it; the value row repeats the sentence rather than sitting bare.
    for package, _directory in PACKAGES:
        by_name = {
            entry.name: entry.doc
            for entry in parsed[package]["errors"] + parsed[package]["types"]
        }
        for entry in parsed[package]["values"]:
            if entry.doc:
                continue
            mentioned = re.match(r":\s*([A-Za-z0-9_]+)", entry.signature)
            if mentioned and by_name.get(mentioned.group(1)):
                entry.doc = by_name[mentioned.group(1)]

    anchors = Anchors()
    for package, _directory in PACKAGES:
        register(parsed[package], package, anchors)

    for package, directory in PACKAGES:
        body = build_package(parsed[package], package, anchors)
        missing = missing_names(parsed[package], body)
        for name in surface_names(interface_path(directory)):
            short = name.split("::")[-1]
            if name not in body and short not in body and name not in missing:
                missing.append(name)
        if missing:
            sys.stderr.write(
                f"{package}: {len(missing)} public names are not in the body: "
                + ", ".join(missing[:8])
                + "\n"
            )
            return 1
        body = (
            "<!-- Generated by scripts/gen_api.py from pkg.generated.mbti and the "
            "documentation comments; do not edit by hand. -->\n" + body
        )
        pattern = re.compile(
            rf"(<!-- BEGIN {package} -->).*?(<!-- END {package} -->)", re.DOTALL
        )
        replacement = rf"\1\n{body}\n\2"
        page, count = pattern.subn(replacement, page)
        if count != 1:
            sys.stderr.write(f"docs/api.html has no unique marker for {package}\n")
            return 1

    # A crude guard against a generator that silently produces nothing: every
    # package section has to carry at least one entry.
    for package, _directory in PACKAGES:
        if f'id="{package}-' not in page:
            sys.stderr.write(f"no entries generated for {package}\n")
            return 1

    TARGET.write_text(page, encoding="utf-8", newline="\n")
    sys.stdout.write(f"wrote {TARGET.relative_to(ROOT)}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
