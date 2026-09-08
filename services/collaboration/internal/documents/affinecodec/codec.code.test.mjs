import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as Y from "yjs";
import {
  canonicalSnapshot,
  canonicalJSON,
  codeProfile,
  profile,
} from "./codec.mjs";

const bytes = fs.readFileSync(
  new URL("../testdata/native/archive-affine-import.bin", import.meta.url),
);
const source = fs.readFileSync(
  new URL("../testdata/native/archive.md", import.meta.url),
  "utf8",
);
const title =
  "人机执行档案 · 76dedd18-1ddf-4fc0-abfa-19aee795b034 · 游标 5 · 1";
const read = (b = bytes) => canonicalSnapshot(b, title, codeProfile);
const mutate = (fn) => {
  const doc = new Y.Doc();
  Y.applyUpdate(doc, bytes);
  const blocks = doc.getMap("blocks");
  const code = [...blocks.values()].find(
    (b) => b.get("sys:flavour") === "affine:code",
  );
  fn(code, doc, blocks);
  const result = Y.encodeStateAsUpdate(doc);
  doc.destroy();
  return result;
};

test("v2 reads six real official-import code blocks with exact Chinese, language and terminal LF; v1 stays closed", () => {
  assert.throws(() => canonicalSnapshot(bytes, title, profile));
  const native = read();
  const codes = native.tree.children.filter((n) => n.type === "codeBlock");
  const chunks = [...source.matchAll(/^```json\n([\s\S]*?)^```$/gm)].map(
    (m) => m[1],
  );
  assert.equal(codes.length, 6);
  assert.equal(chunks.length, 6);
  for (let i = 0; i < 6; i++) {
    assert.equal(codes[i].language, "json");
    assert.equal(codes[i].text, chunks[i]);
    assert.ok(codes[i].text.endsWith("\n"));
  }
  assert.equal(native.visitedBlocks, 24);
});

test("code v2 refuses fake shared text, marks, unknown schema/props, children and collapsed content", () => {
  const invalid = [
    (b) => b.set("sys:version", 2),
    (b) => b.set("prop:future-code-property", false),
    (b) => b.set("prop:caption", "unrepresented caption"),
    (b) => b.set("prop:collapsed", true),
    (b) => b.set("prop:preview", true),
    (b) => b.set("prop:language", "json extra"),
    (b) => b.get("sys:children").push(["unexpected-child"]),
    (b) => b.get("prop:text").format(0, 1, { bold: true }),
    (b) => {
      const fake = new Y.Map();
      fake.set("text", b.get("prop:text").toString());
      fake.set("delta", b.get("prop:text").toDelta());
      b.set("prop:text", fake);
    },
  ];
  for (const change of invalid) assert.throws(() => read(mutate(change)));
});

test("code v2 cannot flatten changed language, Chinese bytes or trailing newline into an equal proof", () => {
  const before = canonicalJSON(read().tree);
  for (const change of [
    (b) => b.set("prop:language", "yaml"),
    (b) => {
      const t = b.get("prop:text");
      t.delete(t.length - 1, 1);
    },
    (b) => {
      const t = b.get("prop:text");
      t.insert(t.length, "\n");
    },
    (b) => b.get("prop:text").insert(0, "不同中文"),
  ])
    assert.notEqual(canonicalJSON(read(mutate(change)).tree), before);
});

test("code v2 keeps empty, Unicode, CRLF and absent EOF newline exactly", () => {
  for (const text of ["", "中文🚀\r\n", "中文\n\n", "末行无换行"]) {
    const actual = read(
      mutate((b) => {
        const t = b.get("prop:text");
        t.delete(0, t.length);
        t.insert(0, text);
      }),
    ).tree.children.find((n) => n.type === "codeBlock");
    assert.equal(actual.text, text);
  }
});
