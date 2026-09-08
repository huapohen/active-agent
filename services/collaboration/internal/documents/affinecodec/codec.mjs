import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as Y from "yjs";

export const profile = "affine.database-v3.rich-text.b4c8548c0.v1";
export const codeProfile = "affine.database-v3.code-v1.rich-text.b4c8548c0.v2";
export const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const sorted = (x) =>
  Array.isArray(x)
    ? x.map(sorted)
    : x && typeof x === "object"
      ? Object.fromEntries(
          Object.keys(x)
            .sort()
            .map((k) => [k, sorted(x[k])]),
        )
      : x;
export const canonicalJSON = (x) =>
  JSON.stringify(sorted(x)).replace(
    /[<>&\u2028\u2029]/g,
    (c) =>
      ({
        "<": "\\u003c",
        ">": "\\u003e",
        "&": "\\u0026",
        "\u2028": "\\u2028",
        "\u2029": "\\u2029",
      })[c],
  );
const equal = (a, b) => {
  if (canonicalJSON(a) !== canonicalJSON(b))
    throw new Error("native_structure_mismatch");
};
const fail = (code) => {
  throw new Error(code);
};
const nativeText = Symbol("actual Y.Text");
const systemKeys = ["sys:id", "sys:flavour", "sys:version", "sys:children"];
function safeID(value) {
  if (
    typeof value !== "string" ||
    !value ||
    value.length > 160 ||
    !/^[A-Za-z0-9_-]+$/.test(value)
  )
    fail("invalid_native_id");
}
function plain(x) {
  if (x instanceof Y.Text)
    return { text: x.toString(), delta: x.toDelta(), [nativeText]: true };
  if (x instanceof Y.Map)
    return Object.fromEntries([...x.entries()].map(([k, v]) => [k, plain(v)]));
  if (x instanceof Y.Array) return x.toArray().map(plain);
  return x;
}
function load(bytes) {
  if (bytes.length > 2_000_000) fail("snapshot_too_large");
  const d = new Y.Doc();
  Y.applyUpdate(d, bytes);
  return d;
}
const para = (children) => ({
  type: "paragraph",
  indent: 0,
  textAlign: null,
  children,
});
const marksSorted = (marks) =>
  [...marks].sort((a, b) =>
    canonicalJSON(a) < canonicalJSON(b)
      ? -1
      : canonicalJSON(a) > canonicalJSON(b)
        ? 1
        : 0,
  );
function coalesce(nodes) {
  const out = [];
  for (const n of nodes) {
    const p = out.at(-1);
    if (
      p?.type === "text" &&
      n.type === "text" &&
      canonicalJSON(p.marks) === canonicalJSON(n.marks)
    )
      p.text += n.text;
    else out.push(n);
  }
  return out;
}
function delta(v) {
  if (
    !v ||
    v[nativeText] !== true ||
    typeof v.text !== "string" ||
    !Array.isArray(v.delta)
  )
    fail("native_rich_text_required");
  let text = "";
  const nodes = [];
  for (const op of v.delta) {
    if (
      typeof op.insert !== "string" ||
      Object.keys(op).some((k) => k !== "insert" && k !== "attributes")
    )
      fail("unsupported_delta");
    const marks = [];
    for (const [k, val] of Object.entries(op.attributes ?? {})) {
      if (["bold", "italic", "code", "strike"].includes(k) && val === true)
        marks.push({ type: k });
      else if (k === "link" && typeof val === "string")
        marks.push({ type: "link", href: val, title: null });
      else fail("unsupported_delta_attribute");
    }
    text += op.insert;
    nodes.push({ type: "text", text: op.insert, marks: marksSorted(marks) });
  }
  assert.equal(text, v.text, "delta_text_mismatch");
  return coalesce(nodes);
}
function props(b, allowed) {
  for (const key of Object.keys(b))
    if (!systemKeys.includes(key) && !allowed.includes(key))
      fail("unmapped_native_property");
}
const cell = (children, header) => ({
  type: header ? "tableHeader" : "tableCell",
  align: null,
  colspan: 1,
  rowspan: 1,
  colwidth: null,
  backgroundColor: null,
  backgroundColorName: null,
  children: [para(children)],
});

export function canonicalSnapshot(
  bytes,
  expectedTitle,
  selectedProfile = profile,
) {
  if (![profile, codeProfile].includes(selectedProfile))
    fail("unsupported_native_profile");
  const doc = load(bytes);
  try {
    return canonicalDoc(doc, expectedTitle, selectedProfile);
  } finally {
    doc.destroy();
  }
}
function canonicalDoc(doc, expectedTitle, selectedProfile = profile) {
  const rawBlocks = doc.getMap("blocks");
  const blocks = plain(rawBlocks);
  const visited = new Set();
  const tables = [];
  const mappings = [];
  function use(id) {
    if (!blocks[id] || visited.has(id)) fail("invalid_native_ancestry");
    safeID(id);
    const raw = rawBlocks.get(id);
    if (
      !(raw instanceof Y.Map) ||
      !(raw.get("sys:children") instanceof Y.Array)
    )
      fail("native_block_shared_type_required");
    const b = blocks[id];
    for (const key of Object.keys(b))
      if (key.startsWith("sys:") && !systemKeys.includes(key))
        fail("unknown_native_system_property");
    for (const child of b["sys:children"]) safeID(child);
    assert.equal(b["sys:id"], id, "native_block_id_mismatch");
    const versions = {
      "affine:page": 2,
      "affine:surface": 5,
      "affine:note": 1,
      "affine:paragraph": 1,
      "affine:list": 1,
      "affine:table": 1,
      "affine:database": 3,
      ...(selectedProfile === codeProfile ? { "affine:code": 1 } : {}),
    };
    if (
      versions[b["sys:flavour"]] === undefined ||
      b["sys:version"] !== versions[b["sys:flavour"]]
    )
      fail("unsupported_native_block_version");
    visited.add(id);
    return b;
  }
  function sequence(ids) {
    const out = [];
    for (const id of ids) {
      const b = blocks[id];
      if (!b) fail("missing_native_block");
      if (b["sys:flavour"] === "affine:list") {
        const kind =
          b["prop:type"] === "bulleted"
            ? "bulletList"
            : b["prop:type"] === "numbered"
              ? "orderedList"
              : fail("unsupported_native_list");
        let group = out.at(-1);
        if (group?.type !== kind) {
          group = {
            type: kind,
            ...(kind === "orderedList" ? { start: b["prop:order"] ?? 1 } : {}),
            children: [],
          };
          out.push(group);
        }
        use(id);
        props(b, ["prop:type", "prop:text", "prop:order"]);
        group.children.push({
          type: "listItem",
          children: [
            para(delta(b["prop:text"])),
            ...sequence(b["sys:children"] ?? []),
          ],
        });
      } else out.push(convert(id));
    }
    return out;
  }
  function legacyTable(b) {
    const rows = new Map(),
      cols = new Map(),
      cells = new Map();
    for (const [k, v] of Object.entries(b)) {
      if (k.startsWith("sys:")) continue;
      let m = k.match(/^prop:(rows|columns)\.([^.]+)\.(rowId|columnId|order)$/);
      if (m) {
        const map = m[1] === "rows" ? rows : cols;
        map.set(m[2], { ...(map.get(m[2]) ?? {}), [m[3]]: v });
        continue;
      }
      m = k.match(/^prop:cells\.([^:]+):([^.]+)\.text$/);
      if (m) {
        if (typeof v !== "string") fail("unsupported_legacy_cell");
        cells.set(`${m[1]}:${m[2]}`, v);
        continue;
      }
      fail("unmapped_legacy_table_property");
    }
    const ordered = (map, key) =>
      [...map]
        .map(([id, v]) => {
          assert.equal(v[key], id);
          assert.equal(typeof v.order, "string");
          return { id, ...v };
        })
        .sort((a, b) => a.order.localeCompare(b.order));
    const rr = ordered(rows, "rowId"),
      cc = ordered(cols, "columnId");
    assert.equal(new Set(rr.map((r) => r.order)).size, rr.length);
    assert.equal(new Set(cc.map((c) => c.order)).size, cc.length);
    assert.equal(cells.size, rr.length * cc.length);
    equal(b["sys:children"] ?? [], []);
    tables.push({
      id: b["sys:id"],
      flavour: "affine:table",
      rows: rr.length,
      columns: cc.length,
      columnIds: cc.map((c) => c.id),
    });
    return {
      type: "table",
      children: rr.map((r) => ({
        type: "tableRow",
        children: cc.map((c) => {
          const text = cells.get(`${r.id}:${c.id}`);
          if (typeof text !== "string") fail("missing_cell");
          return cell(text ? [{ type: "text", text, marks: [] }] : [], false);
        }),
      })),
    };
  }
  function database(b) {
    props(b, ["prop:title", "prop:columns", "prop:cells", "prop:views"]);
    assert.equal(b["sys:version"], 3, "database_version");
    const raw = rawBlocks.get(b["sys:id"]);
    if (
      !(raw.get("prop:columns") instanceof Y.Array) ||
      !(raw.get("prop:cells") instanceof Y.Map) ||
      !(raw.get("prop:views") instanceof Y.Array)
    )
      fail("native_database_shared_type_required");
    for (const c of raw.get("prop:columns"))
      if (!(c instanceof Y.Map) || !(c.get("data") instanceof Y.Map))
        fail("native_column_shared_type_required");
    for (const row of raw.get("prop:cells").values()) {
      if (!(row instanceof Y.Map)) fail("native_cell_shared_type_required");
      for (const value of row.values())
        if (
          !(value instanceof Y.Map) ||
          !(value.get("value") instanceof Y.Text)
        )
          fail("native_rich_text_required");
    }
    for (const view of raw.get("prop:views")) {
      if (
        !(view instanceof Y.Map) ||
        !(view.get("columns") instanceof Y.Array) ||
        !(view.get("header") instanceof Y.Map) ||
        !(view.get("filter") instanceof Y.Map)
      )
        fail("native_view_shared_type_required");
      for (const c of view.get("columns"))
        if (!(c instanceof Y.Map))
          fail("native_view_column_shared_type_required");
    }
    equal(delta(b["prop:title"]), []);
    const columns = b["prop:columns"],
      cells = b["prop:cells"],
      rows = b["sys:children"];
    if (!Array.isArray(columns) || !columns.length || !Array.isArray(rows))
      fail("invalid_database");
    assert.equal(new Set(columns.map((c) => c.id)).size, columns.length);
    for (const [cidx, c] of columns.entries()) {
      equal(Object.keys(c).sort(), ["data", "id", "name", "type"]);
      safeID(c.id);
      // DatabaseBlockDataSource resolves these special IDs before ordinary
      // column values; accepting them could change rendered type/text.
      if (["type", "title", "created-time", "created-by"].includes(c.id))
        fail("reserved_native_column_id");
      assert.equal(typeof c.name, "string");
      equal(c.data, {});
      assert.equal(c.type, cidx === 0 ? "title" : "rich-text");
    }
    const views = b["prop:views"];
    assert.equal(views.length, 1);
    const v = views[0];
    equal(Object.keys(v).sort(), [
      "columns",
      "filter",
      "header",
      "id",
      "mode",
      "name",
    ]);
    safeID(v.id);
    assert.equal(v.name, "Table View");
    assert.equal(v.mode, "table");
    equal(v.filter, { type: "group", op: "and", conditions: [] });
    equal(v.header, { titleColumn: columns[0].id });
    equal(
      v.columns.map((c) => ({ id: c.id, hide: c.hide })),
      columns.map((c) => ({ id: c.id, hide: false })),
    );
    for (const c of v.columns) {
      equal(Object.keys(c).sort(), ["hide", "id", "width"]);
      if (typeof c.width !== "number" || c.width <= 0)
        fail("invalid_column_width");
    }
    equal(Object.keys(cells).sort(), [...rows].sort());
    const bodyRows = rows.map((rowId) => {
      const row = use(rowId);
      assert.equal(row["sys:flavour"], "affine:paragraph");
      assert.equal(row["prop:type"], "text");
      props(row, ["prop:type", "prop:text"]);
      equal(row["sys:children"] ?? [], []);
      const rowCells = cells[rowId];
      equal(
        Object.keys(rowCells).sort(),
        columns
          .slice(1)
          .map((c) => c.id)
          .sort(),
      );
      return {
        type: "tableRow",
        children: columns.map((c, i) => {
          if (i === 0) return cell(delta(row["prop:text"]), false);
          const value = rowCells[c.id];
          equal(Object.keys(value).sort(), ["columnId", "value"]);
          assert.equal(value.columnId, c.id);
          return cell(delta(value.value), false);
        }),
      };
    });
    tables.push({
      id: b["sys:id"],
      flavour: "affine:database",
      rows: rows.length + 1,
      columns: columns.length,
      columnIds: columns.map((c) => c.id),
    });
    return {
      type: "table",
      children: [
        {
          type: "tableRow",
          children: columns.map((c) =>
            cell(
              c.name ? [{ type: "text", text: c.name, marks: [] }] : [],
              true,
            ),
          ),
        },
        ...bodyRows,
      ],
    };
  }
  function convert(id) {
    const b = use(id);
    mappings.push({ id, flavour: b["sys:flavour"] });
    if (b["sys:flavour"] === "affine:code") {
      if (selectedProfile !== codeProfile) fail("unsupported_native_block");
      props(b, [
        "prop:text",
        "prop:language",
        "prop:wrap",
        "prop:caption",
        "prop:preview",
        "prop:lineNumber",
        "prop:collapsed",
        "prop:comments",
      ]);
      equal(b["sys:children"], []);
      for (const [key, expected] of Object.entries({
        "prop:wrap": false,
        "prop:caption": "",
        "prop:preview": false,
        "prop:lineNumber": true,
        "prop:collapsed": false,
        "prop:comments": {},
      })) {
        if (Object.hasOwn(b, key)) equal(b[key], expected);
      }
      let language = b["prop:language"] ?? null;
      // The official block's absent-language display default is plain text.
      if (language === "" || language === "plain text") language = null;
      if (
        language !== null &&
        (typeof language !== "string" ||
          !/^[A-Za-z0-9_.+#-]{1,80}$/.test(language))
      )
        fail("unsupported_code_language");
      const text = delta(b["prop:text"]);
      for (const n of text)
        if (n.type !== "text" || n.marks.length)
          fail("unsupported_native_code");
      return {
        type: "codeBlock",
        language,
        text: text.map((n) => n.text).join(""),
      };
    }
    if (b["sys:flavour"] === "affine:paragraph") {
      props(b, ["prop:type", "prop:text"]);
      equal(b["sys:children"] ?? [], []);
      const children = delta(b["prop:text"]);
      if (b["prop:type"] === "text") return para(children);
      if (/^h[1-6]$/.test(b["prop:type"]))
        return {
          type: "heading",
          level: Number(b["prop:type"][1]),
          indent: 0,
          textAlign: null,
          children,
        };
      fail("unsupported_paragraph");
    }
    if (b["sys:flavour"] === "affine:table") return legacyTable(b);
    if (b["sys:flavour"] === "affine:database") return database(b);
    fail("unsupported_native_block");
  }
  const pages = Object.entries(blocks).filter(
    ([, b]) => b["sys:flavour"] === "affine:page",
  );
  assert.equal(pages.length, 1);
  const page = use(pages[0][0]);
  props(page, ["prop:title"]);
  equal(delta(page["prop:title"]), [
    { type: "text", text: expectedTitle, marks: [] },
  ]);
  const notes = [];
  for (const id of page["sys:children"] ?? []) {
    const b = blocks[id];
    if (b?.["sys:flavour"] === "affine:surface") {
      use(id);
      props(b, ["prop:elements"]);
      equal(b["sys:children"] ?? [], []);
      equal(b["prop:elements"], {
        type: "$blocksuite:internal:native$",
        value: {},
      });
    } else if (b?.["sys:flavour"] === "affine:note") notes.push(id);
    else fail("unsupported_page_child");
  }
  assert.equal(notes.length, 1);
  const note = use(notes[0]);
  props(note, [
    "prop:background",
    "prop:xywh",
    "prop:index",
    "prop:hidden",
    "prop:displayMode",
  ]);
  if (
    typeof note["prop:xywh"] !== "string" ||
    typeof note["prop:index"] !== "string"
  )
    fail("invalid_note_layout");
  const bounds = JSON.parse(note["prop:xywh"]);
  if (
    !Array.isArray(bounds) ||
    bounds.length !== 4 ||
    bounds.some((n) => !Number.isFinite(n))
  )
    fail("invalid_note_layout");
  const background = note["prop:background"];
  equal(Object.keys(background).sort(), ["dark", "light"]);
  if (
    typeof background.light !== "string" ||
    typeof background.dark !== "string"
  )
    fail("invalid_note_background");
  assert.equal(note["prop:hidden"], false);
  assert.equal(note["prop:displayMode"], "both");
  const tree = { type: "doc", children: sequence(note["sys:children"]) };
  assert.equal(visited.size, Object.keys(blocks).length, "unvisited_blocks");
  return {
    tree,
    blocks,
    tables,
    visitedBlocks: visited.size,
    noteId: notes[0],
    pageId: pages[0][0],
    mappings,
  };
}

function yValue(v) {
  if (v instanceof Y.AbstractType) return v;
  if (Array.isArray(v)) {
    const a = new Y.Array();
    a.insert(0, v.map(yValue));
    return a;
  }
  if (v && typeof v === "object") {
    const m = new Y.Map();
    for (const [k, value] of Object.entries(v)) m.set(k, yValue(value));
    return m;
  }
  return v;
}
function richText(nodes) {
  const value = new Y.Text();
  let offset = 0;
  for (const n of nodes) {
    equal(Object.keys(n).sort(), ["marks", "text", "type"]);
    assert.equal(n.type, "text");
    const attrs = {};
    for (const m of n.marks) {
      if (
        ["bold", "code", "italic", "strike"].includes(m.type) &&
        Object.keys(m).length === 1
      )
        attrs[m.type] = true;
      else if (
        m.type === "link" &&
        m.title === null &&
        typeof m.href === "string"
      )
        attrs.link = m.href;
      else fail("unsupported_source_mark");
    }
    value.insert(offset, n.text, attrs);
    offset += n.text.length;
  }
  return value;
}
function paragraphInline(n) {
  equal(Object.keys(n).sort(), ["children", "indent", "textAlign", "type"]);
  assert.equal(n.type, "paragraph");
  assert.equal(n.indent, 0);
  assert.equal(n.textAlign, null);
  return n.children;
}
function cellInline(n, header) {
  equal(Object.keys(n).sort(), [
    "align",
    "backgroundColor",
    "backgroundColorName",
    "children",
    "colspan",
    "colwidth",
    "rowspan",
    "type",
  ]);
  assert.equal(n.type, header ? "tableHeader" : "tableCell");
  for (const k of [
    "align",
    "backgroundColor",
    "backgroundColorName",
    "colwidth",
  ])
    assert.equal(n[k], null);
  assert.equal(n.colspan, 1);
  assert.equal(n.rowspan, 1);
  assert.equal(n.children.length, 1);
  return paragraphInline(n.children[0]);
}

export function prepareDatabaseRepair({
  snapshot,
  source,
  expectedSnapshotHash,
  expectedTitle,
}) {
  assert.equal(hash(snapshot), expectedSnapshotHash, "snapshot_hash_mismatch");
  assert.equal(source.type, "doc");
  const doc = load(snapshot);
  try {
    const before = canonicalDoc(doc, expectedTitle);
    const sourceTables = source.children.filter((n) => n.type === "table");
    assert.equal(sourceTables.length, before.tables.length);
    equal(
      before.tree.children.filter((n) => n.type !== "table"),
      source.children.filter((n) => n.type !== "table"),
    );
    equal(
      before.tree.children
        .map((n, i) => (n.type === "table" ? i : null))
        .filter((i) => i !== null),
      source.children
        .map((n, i) => (n.type === "table" ? i : null))
        .filter((i) => i !== null),
    );
    const state = Y.encodeStateVector(doc);
    const blocks = doc.getMap("blocks");
    const added = [];
    doc.transact(() => {
      for (const [tableIndex, info] of before.tables.entries()) {
        assert.equal(
          info.flavour,
          "affine:table",
          "already_repaired_or_different_model",
        );
        const table = sourceTables[tableIndex];
        equal(Object.keys(table).sort(), ["children", "type"]);
        assert.equal(table.children.length, info.rows);
        for (const row of table.children) {
          equal(Object.keys(row).sort(), ["children", "type"]);
          assert.equal(row.type, "tableRow");
          assert.equal(row.children.length, info.columns);
        }
        const cols = info.columnIds.map((id, i) => {
          const content = cellInline(table.children[0].children[i], true);
          for (const n of content) {
            assert.equal(n.type, "text");
            equal(n.marks, []);
          }
          return {
            id,
            name: content.map((n) => n.text).join(""),
            type: i === 0 ? "title" : "rich-text",
            data: {},
          };
        });
        const bodyRows = table.children.slice(1),
          rowIds = [],
          cells = {};
        for (const [rowIndex, row] of bodyRows.entries()) {
          const id =
            "renji-row-" +
            hash(expectedSnapshotHash + info.id + ":" + rowIndex).slice(0, 24);
          assert.equal(blocks.has(id), false, "row_id_collision");
          rowIds.push(id);
          added.push(id);
          const content = row.children.map((c) => cellInline(c, false));
          const p = new Y.Map();
          p.set("sys:id", id);
          p.set("sys:flavour", "affine:paragraph");
          p.set("sys:version", 1);
          p.set("sys:children", new Y.Array());
          p.set("prop:type", "text");
          p.set("prop:text", richText(content[0]));
          blocks.set(id, p);
          cells[id] = {};
          for (let c = 1; c < cols.length; c++)
            cells[id][cols[c].id] = {
              columnId: cols[c].id,
              value: richText(content[c]),
            };
        }
        const b = blocks.get(info.id);
        for (const key of [...b.keys()])
          if (key.startsWith("prop:")) b.delete(key);
        b.set("sys:flavour", "affine:database");
        b.set("sys:version", 3);
        b.set("sys:children", yValue(rowIds));
        b.set("prop:title", new Y.Text());
        b.set("prop:columns", yValue(cols));
        b.set("prop:cells", yValue(cells));
        b.set(
          "prop:views",
          yValue([
            {
              id: "renji-view-" + hash(info.id).slice(0, 16),
              name: "Table View",
              mode: "table",
              columns: cols.map((c) => ({ id: c.id, width: 240, hide: false })),
              filter: { type: "group", op: "and", conditions: [] },
              header: { titleColumn: cols[0].id },
            },
          ]),
        );
      }
    });
    const after = canonicalDoc(doc, expectedTitle);
    equal(after.tree, source);
    const tableIds = new Set(before.tables.map((t) => t.id));
    for (const [id, b] of Object.entries(before.blocks))
      if (!tableIds.has(id)) equal(after.blocks[id], b);
    const update = Y.encodeStateAsUpdate(doc, state),
      patched = Y.encodeStateAsUpdate(doc);
    const replay = load(snapshot);
    try {
      Y.applyUpdate(replay, update);
      equal(canonicalDoc(replay, expectedTitle).tree, source);
    } finally {
      replay.destroy();
    }
    return {
      update,
      patched,
      canonical: after.tree,
      report: {
        profile,
        sourceCanonicalHash: hash(canonicalJSON(source)),
        targetCanonicalHash: hash(canonicalJSON(after.tree)),
        beforeSnapshotHash: hash(snapshot),
        updateHash: hash(update),
        afterSnapshotHash: hash(patched),
        sameDocumentId: true,
        retainedTableBlockIds: [...tableIds],
        preservedOriginalNonTableBlocks:
          Object.keys(before.blocks).length - tableIds.size,
        addedRowBlocks: added.length,
        beforeBlocks: before.visitedBlocks,
        afterBlocks: after.visitedBlocks,
        fullStructureEqual: true,
        unknownOrUnvisitedBlocks: 0,
        targetWrites: 0,
        tableModel: "affine:database",
        tableSchemaVersion: 3,
      },
    };
  } finally {
    doc.destroy();
  }
}
