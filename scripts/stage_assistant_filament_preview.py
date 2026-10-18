#!/usr/bin/env python3
"""Stage a Debug-only GLB with a declared Y-up frame and chest-owned badge.

This does not alter topology, skin weights or animation. The source is a known
Z-up authoring export, whereas the native glTF renderer expects standard Y-up.
Keep the source untouched and make the preview conversion reproducible.
"""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

SOURCE_SHA = "1e27937f0988ed31dd1199dedfbc8cef8e5b78f0c664d51e0bd041841fa69f9a"


def stage(source: Path, badge: Path, output: Path):
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA:
        raise ValueError("Preview input changed; review its coordinate contract before staging")
    magic, version, size = struct.unpack_from("<4sII", data)
    if magic != b"glTF" or version != 2 or size != len(data):
        raise ValueError("Invalid GLB header")
    json_size, kind = struct.unpack_from("<I4s", data, 12)
    if kind != b"JSON": raise ValueError("Missing JSON chunk")
    doc = json.loads(data[20:20+json_size])
    offset = 20 + json_size
    bin_size, kind = struct.unpack_from("<I4s", data, offset)
    if kind != b"BIN\0": raise ValueError("Missing binary chunk")
    binary = bytearray(data[offset+8:offset+8+bin_size])

    def view(content, target=None):
        binary.extend(b"\0" * (-len(binary) % 4))
        start = len(binary); binary.extend(content)
        item = {"buffer": 0, "byteOffset": start, "byteLength": len(content)}
        if target: item["target"] = target
        doc["bufferViews"].append(item)
        return len(doc["bufferViews"]) - 1

    def accessor(values, count, kind, component=5126, bounds=None):
        item = {"bufferView": view(values, 34963 if component == 5123 else 34962),
                "componentType": component, "count": count, "type": kind}
        if bounds: item["min"], item["max"] = bounds
        doc["accessors"].append(item)
        return len(doc["accessors"]) - 1

    # This source's badge locator has identity world orientation in Z-up and
    # is already parented to chest. Use X/Z for its plane, facing source -Y.
    anchor = next(i for i, n in enumerate(doc["nodes"]) if n.get("name") == "character.badge")
    half = 0.0325
    positions = [(-half, 0, -half), (half, 0, -half), (half, 0, half), (-half, 0, half)]
    pos = accessor(struct.pack("<12f", *(x for v in positions for x in v)), 4, "VEC3",
                   bounds=([-half, 0, -half], [half, 0, half]))
    normal = accessor(struct.pack("<12f", *([0, -1, 0] * 4)), 4, "VEC3")
    uv = accessor(struct.pack("<8f", 0, 1, 1, 1, 1, 0, 0, 0), 4, "VEC2")
    indices = accessor(struct.pack("<6H", 0, 1, 2, 0, 2, 3), 6, "SCALAR", 5123)
    image = {"bufferView": view(badge.read_bytes()), "mimeType": "image/png", "name": "AssistantBadge"}
    doc.setdefault("images", []).append(image)
    doc.setdefault("textures", []).append({"source": len(doc["images"]) - 1})
    doc["materials"].append({"name": "AssistantBadge", "doubleSided": True, "alphaMode": "BLEND",
        "extensions": {"KHR_materials_unlit": {}},
        "pbrMetallicRoughness": {"baseColorTexture": {"index": len(doc["textures"]) - 1},
                                "metallicFactor": 0, "roughnessFactor": 1}})
    doc["meshes"].append({"name": "AssistantBadge", "primitives": [{"attributes": {
        "POSITION": pos, "NORMAL": normal, "TEXCOORD_0": uv}, "indices": indices,
        "material": len(doc["materials"]) - 1}]})
    doc["nodes"].append({"name": "AssistantBadge", "mesh": len(doc["meshes"]) - 1})
    doc["nodes"][anchor].setdefault("children", []).append(len(doc["nodes"]) - 1)
    if "KHR_materials_unlit" not in doc.setdefault("extensionsUsed", []):
        doc["extensionsUsed"].append("KHR_materials_unlit")

    # Wrap every scene root, so mesh and joints share one conversion. Inverse
    # bind matrices remain valid; no per-bone axis patches are introduced.
    for scene in doc["scenes"]:
        doc["nodes"].append({"name": "QF_YUpPreview", "rotation": [-math.sqrt(0.5), 0, 0, math.sqrt(0.5)],
                             "children": scene["nodes"]})
        scene["nodes"] = [len(doc["nodes"]) - 1]
    doc["asset"].setdefault("extras", {}).update({"qfPreviewSourceSHA256": SOURCE_SHA,
        "authoringUpAxis": "Z", "runtimeUpAxis": "Y", "animationAcceptance": "pending"})
    doc["buffers"][0]["byteLength"] = len(binary)
    encoded = json.dumps(doc, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 4)
    binary.extend(b"\0" * (-len(binary) % 4))
    length = 12 + 8 + len(encoded) + 8 + len(binary)
    result = (struct.pack("<4sII", b"glTF", 2, length) + struct.pack("<I4s", len(encoded), b"JSON")
              + encoded + struct.pack("<I4s", len(binary), b"BIN\0") + binary)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(result)
    print("Debug avatar preview staged:", len(result), "bytes; Y-up; badge owned by chest")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path); parser.add_argument("badge", type=Path); parser.add_argument("output", type=Path)
    args = parser.parse_args(); stage(args.source, args.badge, args.output)
