import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as Y from "yjs";
import { canonicalSnapshot, canonicalJSON } from "./codec.mjs";

const repaired = fs.readFileSync(new URL("../testdata/native/affine-database.bin", import.meta.url));
const original = fs.readFileSync(new URL("../testdata/native/affine-original.bin", import.meta.url));
const source = JSON.parse(fs.readFileSync(new URL("../testdata/native/marked-source.json", import.meta.url)));
const title = "人机 startup 第一阶段交付 · a9005c0 · 2026-09-09";
function mutate(change) {
  const doc = new Y.Doc();
  try {
    Y.applyUpdate(doc, repaired);
    change(doc.getMap("blocks"));
    return Y.encodeStateAsUpdate(doc);
  } finally { doc.destroy(); }
}
function firstDatabase(blocks) {
  return [...blocks.values()].find(b => b.get("sys:flavour") === "affine:database");
}

function nativeValue(v) {
  if (v instanceof Y.Text) return { kind: "Y.Text", delta: v.toDelta() };
  if (v instanceof Y.Map) return { kind: "Y.Map", entries: [...v.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([k, val]) => [k, nativeValue(val)]) };
  if (v instanceof Y.Array) return { kind: "Y.Array", items: v.toArray().map(nativeValue) };
  return v;
}
function sourceCharacters(cell) {
  assert.equal(cell.children.length, 1);
  assert.equal(cell.children[0].type, "paragraph");
  return cell.children[0].children.flatMap(n => {
    assert.equal(n.type, "text");
    const attrs = Object.fromEntries(n.marks.map(m => [m.type, m.type === "link" ? m.href : true]));
    return [...n.text].map(character => ({ character, attrs }));
  });
}
function nativeCharacters(text) {
  assert.ok(text instanceof Y.Text);
  return text.toDelta().flatMap(op => [...op.insert].map(character => ({ character, attrs: op.attributes ?? {} })));
}

test("review: raw Yjs independently preserves 54 original blocks and every table character/mark in order", () => {
  const before = new Y.Doc(), after = new Y.Doc();
  try {
    Y.applyUpdate(before, original); Y.applyUpdate(after, repaired);
    const a = before.getMap("blocks"), b = after.getMap("blocks");
    const noteID = [...a.keys()].find(id => a.get(id).get("sys:flavour") === "affine:note");
    const tableIDs = a.get(noteID).get("sys:children").toArray().filter(id => a.get(id).get("sys:flavour") === "affine:table");
    assert.equal(tableIDs.length, 4);
    let preserved = 0;
    for (const [id, block] of a.entries()) {
      assert.ok(b.has(id), "no original block ID may disappear");
      if (tableIDs.includes(id)) continue;
      assert.deepEqual(nativeValue(b.get(id)), nativeValue(block), `original ${id} changed`);
      preserved++;
    }
    assert.equal(preserved, 54);
    assert.equal(b.size, 79);
    const expected = source.children.filter(n => n.type === "table");
    for (const [i, id] of tableIDs.entries()) {
      const table = b.get(id), cols = table.get("prop:columns").toArray(), rows = table.get("sys:children").toArray();
      assert.equal(table.get("sys:id"), id);
      assert.equal(table.get("sys:flavour"), "affine:database");
      assert.equal(table.get("sys:version"), 3);
      assert.equal(rows.length + 1, expected[i].children.length);
      assert.equal(cols.length, expected[i].children[0].children.length);
      for (const [c, col] of cols.entries()) {
        const header = [...col.get("name")].map(character => ({ character, attrs: {} }));
        assert.deepEqual(header, sourceCharacters(expected[i].children[0].children[c]));
        for (const [r, rowID] of rows.entries()) {
          const text = c === 0 ? b.get(rowID).get("prop:text") : table.get("prop:cells").get(rowID).get(col.get("id")).get("value");
          assert.deepEqual(nativeCharacters(text), sourceCharacters(expected[i].children[r + 1].children[c]), `table ${i} row ${r} column ${c}`);
        }
      }
    }
  } finally { before.destroy(); after.destroy(); }
});

test("review: database fixture has actual Y.Text cells and all source marks", () => {
  const doc = new Y.Doc();
  try {
    Y.applyUpdate(doc, repaired);
    let cells = 0;
    for (const block of doc.getMap("blocks").values()) {
      if (block.get("sys:flavour") !== "affine:database") continue;
      for (const row of block.get("prop:cells").values()) {
        for (const cell of row.values()) {
          assert.ok(cell.get("value") instanceof Y.Text);
          cells++;
        }
      }
    }
    assert.equal(cells, 46);
    assert.equal(canonicalJSON(canonicalSnapshot(repaired, title).tree), canonicalJSON(source));
  } finally { doc.destroy(); }
});

test("review: a lookalike map must not pass as native Y.Text", () => {
  const bytes = mutate(blocks => {
    const table = firstDatabase(blocks);
    const cell = [...[...table.get("prop:cells").values()][0].values()][0];
    const text = cell.get("value");
    assert.ok(text instanceof Y.Text);
    const fake = new Y.Map();
    fake.set("text", text.toString());
    // Structurally identical JSON is intentionally not a live rich-text type.
    fake.set("delta", text.toDelta());
    cell.set("value", fake);
  });
  assert.throws(() => canonicalSnapshot(bytes, title), "official raw-value schema requires Y.Text, not a text/delta lookalike");
});

for (const flavour of ["affine:page", "affine:surface", "affine:note"]) {
  test(`review: unknown property on ${flavour} cannot be ignored`, () => {
    const bytes = mutate(blocks => {
      [...blocks.values()].find(b => b.get("sys:flavour") === flavour).set("prop:unsupported-review-feature", true);
    });
    assert.throws(() => canonicalSnapshot(bytes, title));
  });
}
test("review: unknown system property cannot be ignored", () => {
  const bytes = mutate(blocks => {
    firstDatabase(blocks).set("sys:unsupported-review-feature", true);
  });
  assert.throws(() => canonicalSnapshot(bytes, title));
});

test("review: database view IDs must remain string identities", () => {
  const bytes = mutate(blocks => {
    firstDatabase(blocks).get("prop:views").get(0).set("id", 42);
  });
  assert.throws(() => canonicalSnapshot(bytes, title));
});

test("review: reserved type property cannot masquerade as the title column", () => {
  const bytes = mutate(blocks => {
    const table = firstDatabase(blocks);
    table.get("prop:columns").get(0).set("id", "type");
    const view = table.get("prop:views").get(0);
    view.get("columns").get(0).set("id", "type");
    view.get("header").set("titleColumn", "type");
  });
  // Same-deployment DatabaseBlockDataSource.propertyTypeGet('type') overrides
  // the declared column type with 'image'; propertyNameGet returns Block Type.
  assert.throws(() => canonicalSnapshot(bytes, title));
});
