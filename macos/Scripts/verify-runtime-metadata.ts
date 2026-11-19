// Reject old VM artifacts and mismatched builder metadata before packaging.
import { createHash } from "node:crypto";

function values(path: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const line of Deno.readTextFileSync(path).split(/\r?\n/)) {
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 1) throw new Error(`Invalid metadata line: ${line}`);
    const key = line.slice(0, separator);
    if (Object.hasOwn(result, key)) throw new Error(`Duplicate metadata key: ${key}`);
    result[key] = line.slice(separator + 1);
  }
  return result;
}

const [artifact, metadataPath, expectedPath, launcherFormat] = Deno.args;
const metadata = values(metadataPath);
const expected = values(expectedPath);
if (launcherFormat && metadata.XE_RUNTIME_FORMAT !== launcherFormat) {
  throw new Error("VM image does not contain the required launcher services");
}
if (launcherFormat && !/^[0-9a-f]{64}$/.test(metadata.XE_RUNTIME_INPUT_SHA256 ?? "")) {
  throw new Error("VM image is missing its launcher input identity");
}
if (metadata.SMOLVM_RUNTIME_FORMAT !== "containerd-buildkit-2") {
  throw new Error("SmolVM image does not contain the required containerd store and embedded builder");
}
for (const key of ["DOCKER_VERSION", "BUILDX_VERSION", "BUILDKIT_VERSION", "BUILDKIT_IMAGE"]) {
  if (!expected[key] || metadata[key] !== expected[key]) {
    throw new Error(`SmolVM image differs from the launcher requirement: ${key}`);
  }
}
const digest = createHash("sha256");
for await (const chunk of (await Deno.open(artifact)).readable) digest.update(chunk);
if (digest.digest("hex") !== metadata.SMOLVM_COMPOSE_SHA256) {
  throw new Error("SmolVM artifact checksum differs from its builder metadata");
}
console.log("Verified embedded Docker/BuildKit image and artifact checksum");
