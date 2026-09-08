// No network, credentials or filesystem document reads. Go supplies one bounded
// snapshot and source tree over stdin; stdout contains proof hashes only.
import { canonicalSnapshot, canonicalJSON, hash, profile } from "./codec.mjs";
let size = 0;
const chunks = [];
try {
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 6_000_000) throw new Error("input_limit");
    chunks.push(chunk);
  }
  const request = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (
    request.profile !== profile ||
    typeof request.title !== "string" ||
    typeof request.snapshot !== "string" ||
    request.source?.type !== "doc"
  )
    throw new Error("invalid_request");
  const bytes = Buffer.from(request.snapshot, "base64");
  if (bytes.toString("base64") !== request.snapshot)
    throw new Error("invalid_snapshot");
  const native = canonicalSnapshot(bytes, request.title);
  const sourceHash = hash(canonicalJSON(request.source));
  const targetHash = hash(canonicalJSON(native.tree));
  if (sourceHash !== targetHash) throw new Error("native_structure_mismatch");
  process.stdout.write(
    JSON.stringify({
      profile,
      source_hash: sourceHash,
      target_hash: targetHash,
      visited_blocks: native.visitedBlocks,
      snapshot_hash: hash(bytes),
    }) + "\n",
  );
} catch {
  process.stdout.write(
    JSON.stringify({ error_code: "native_structure_not_verified" }) + "\n",
  );
  process.exitCode = 1;
}
