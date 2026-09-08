import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as Y from "yjs";
import {
  canonicalSnapshot,
  canonicalJSON,
  hash,
  prepareDatabaseRepair,
} from "./codec.mjs";
const snapshot = fs.readFileSync(
  new URL("../testdata/native/affine-original.bin", import.meta.url),
);
const source = JSON.parse(
  fs.readFileSync(
    new URL("../testdata/native/marked-source.json", import.meta.url),
  ),
);
const title = "人机 startup 第一阶段交付 · a9005c0 · 2026-09-09";
const args = () => ({
  snapshot,
  source: structuredClone(source),
  expectedSnapshotHash: hash(snapshot),
  expectedTitle: title,
});
const prepare = () => prepareDatabaseRepair(args());
function mutated(result, mutate) {
  const d = new Y.Doc();
  Y.applyUpdate(d, result.patched);
  mutate(d, d.getMap("blocks"));
  const b = Y.encodeStateAsUpdate(d);
  d.destroy();
  return b;
}
test("same-ID official database repair preserves complete tree and replays idempotently", () => {
  const r = prepare();
  assert.equal(r.report.preservedOriginalNonTableBlocks, 54);
  assert.equal(r.report.addedRowBlocks, 21);
  assert.equal(r.report.afterBlocks, 79);
  assert.equal(canonicalJSON(r.canonical), canonicalJSON(source));
  const d = new Y.Doc();
  Y.applyUpdate(d, snapshot);
  Y.applyUpdate(d, r.update);
  Y.applyUpdate(d, r.update);
  assert.equal(
    canonicalJSON(canonicalSnapshot(Y.encodeStateAsUpdate(d), title).tree),
    canonicalJSON(source),
  );
  d.destroy();
  const post = canonicalSnapshot(r.patched, title);
  assert.equal(post.tables.length, 4);
  assert.ok(post.tables.every((t) => t.flavour === "affine:database"));
});
test("failed base hash, changed non-table content, pre-repaired base cannot be overwritten", () => {
  assert.throws(() =>
    prepareDatabaseRepair({ ...args(), expectedSnapshotHash: "different" }),
  );
  const input = args();
  input.source.children[0].children[0].text += " ";
  assert.throws(() => prepareDatabaseRepair(input));
  const r = prepare();
  assert.throws(() =>
    prepareDatabaseRepair({
      ...args(),
      snapshot: r.patched,
      expectedSnapshotHash: hash(r.patched),
    }),
  );
});
test("source header styles / alignment cannot be silently dropped", () => {
  for (const kind of ["marks", "align"]) {
    const input = args();
    const table = input.source.children.find((n) => n.type === "table");
    if (kind === "marks")
      table.children[0].children[0].children[0].children[0].marks = [
        { type: "bold" },
      ];
    else table.children[1].children[0].align = "right";
    assert.throws(() => prepareDatabaseRepair(input));
  }
});
test("native header/order/format/hidden/filter/extra blocks fail full comparison", () => {
  const r = prepare();
  const cases = [
    (d, b) => {
      const t = [...b.values()].find(
        (x) => x.get("sys:flavour") === "affine:database",
      );
      t.get("prop:columns").get(0).set("name", "Wrong");
    },
    (d, b) => {
      const t = [...b.values()].find(
        (x) => x.get("sys:flavour") === "affine:database",
      );
      t.get("prop:views").get(0).get("columns").get(0).set("hide", true);
    },
    (d, b) => {
      const t = [...b.values()].find(
        (x) => x.get("sys:flavour") === "affine:database",
      );
      t.get("prop:views").get(0).get("filter").set("op", "or");
    },
    (d, b) => {
      b.set("unexpected", new Y.Map());
    },
    (d, b) => {
      for (const t of b.values()) {
        if (t.get("sys:flavour") !== "affine:database") continue;
        for (const row of t.get("prop:cells").values())
          for (const cell of row.values()) {
            const text = cell.get("value");
            if (text.toDelta().some((op) => op.attributes?.code)) {
              text.format(0, text.length, { code: null });
              return;
            }
          }
      }
    },
    (d, b) => {
      const t = [...b.values()].find(
        (x) => x.get("sys:flavour") === "affine:database",
      );
      const ids = t.get("sys:children").toArray();
      t.get("sys:children").delete(0, ids.length);
      t.get("sys:children").insert(0, [...ids].reverse());
    },
  ];
  for (const mutate of cases) {
    const bytes = mutated(r, mutate);
    let target;
    try {
      target = canonicalSnapshot(bytes, title).tree;
    } catch {
      continue;
    }
    assert.notEqual(
      canonicalJSON(target),
      canonicalJSON(source),
      "mutation accepted",
    );
  }
});
test("map identity and every sampled block schema version are fenced", () => {
  const repaired = prepare();
  for (const flavour of [
    "affine:page",
    "affine:surface",
    "affine:note",
    "affine:paragraph",
    "affine:list",
    "affine:database",
  ]) {
    const bytes = mutated(repaired, (d, b) => {
      const block = [...b.values()].find(
        (x) => x.get("sys:flavour") === flavour,
      );
      assert.ok(block);
      block.set("sys:version", 999);
    });
    assert.throws(() => canonicalSnapshot(bytes, title));
  }
  const wrongID = mutated(repaired, (d, b) => {
    const block = [...b.values()].find(
      (x) => x.get("sys:flavour") === "affine:paragraph",
    );
    block.set("sys:id", "different-map-key");
  });
  assert.throws(() => canonicalSnapshot(wrongID, title));
  const d = new Y.Doc();
  Y.applyUpdate(d, snapshot);
  [...d.getMap("blocks").values()]
    .find((b) => b.get("sys:flavour") === "affine:table")
    .set("sys:version", 2);
  const bytes = Y.encodeStateAsUpdate(d);
  d.destroy();
  assert.throws(() =>
    prepareDatabaseRepair({
      ...args(),
      snapshot: bytes,
      expectedSnapshotHash: hash(bytes),
    }),
  );
});
