#!/usr/bin/env bash
# Regenerates KaChat/Generated/{messages,p2p,rpc}.pb.swift and messages.grpc.swift from
# rusty-kaspa's protos (pinned revision below), with the generator versions the app links:
# swift-protobuf 1.38.1 (protoc-gen-swift) and grpc-swift 1.27.5 (protoc-gen-grpc-swift, v1).
#
#   scripts/regenerate_protowire.sh <rusty-kaspa checkout> <protoc-gen-swift> <protoc-gen-grpc-swift>
#
# The app keeps kaspad's single KaspadMessage envelope (one payload oneof carrying p2p messages,
# RPC requests and RPC responses; services P2P and RPC both stream KaspadMessage). rusty-kaspa
# splits the RPC side into KaspadRequest / KaspadResponse, but the field numbers are the same and
# protobuf is field-number based, so the composed envelope is wire-identical to what a rusty-kaspa
# node sends and accepts. This script builds that envelope from the three rusty-kaspa oneofs:
#   protocol/p2p/proto/messages.proto  KaspadMessage   (p2p payloads 1..63)
#   rpc/grpc/core/proto/messages.proto KaspadRequest   (RPC requests, odd numbers from 1001)
#   rpc/grpc/core/proto/messages.proto KaspadResponse  (RPC responses and notifications)
# The envelope's id fields (p2p response_id/request_id, RPC id = 101) are left out, as before:
# the app matches responses by type.
#
# p2p.proto and rpc.proto are used verbatim.
set -euo pipefail

RK="${1:?rusty-kaspa checkout (rev a41a333b08848f41bf737b72592e463a6011b8ac)}"
SWIFT_PLUGIN="${2:?path to protoc-gen-swift 1.38.1}"
GRPC_PLUGIN="${3:?path to protoc-gen-grpc-swift 1.27.5}"
PROTOC="${PROTOC:-protoc}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/KaChat/Generated"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$RK/protocol/p2p/proto/p2p.proto" "$WORK/p2p.proto"
cp "$RK/rpc/grpc/core/proto/rpc.proto" "$WORK/rpc.proto"

python3 - "$RK" "$WORK/messages.proto" <<'PY'
import re, sys
rk, out = sys.argv[1], sys.argv[2]

def oneof_fields(path, message):
    text = open(path).read()
    m = re.search(r"message\s+" + message + r"\s*\{(.*?)\n\}", text, re.S)
    if not m:
        raise SystemExit(f"{path}: message {message} not found")
    body = m.group(1)
    o = re.search(r"oneof\s+payload\s*\{(.*?)\}", body, re.S)
    fields = []
    for line in o.group(1).splitlines():
        line = line.split("//", 1)[0].strip()
        if not line:
            continue
        f = re.fullmatch(r"(\w+)\s+(\w+)\s*=\s*(\d+)\s*;", line)
        if not f:
            raise SystemExit(f"{path}: cannot parse oneof line {line!r}")
        fields.append((f.group(1), f.group(2), int(f.group(3))))
    return fields

p2p = oneof_fields(f"{rk}/protocol/p2p/proto/messages.proto", "KaspadMessage")
req = oneof_fields(f"{rk}/rpc/grpc/core/proto/messages.proto", "KaspadRequest")
rsp = oneof_fields(f"{rk}/rpc/grpc/core/proto/messages.proto", "KaspadResponse")
fields = sorted(p2p + req + rsp, key=lambda f: f[2])
nums = [f[2] for f in fields]
names = [f[1] for f in fields]
assert len(set(nums)) == len(nums), "duplicate field numbers"
assert len(set(names)) == len(names), "duplicate field names"

lines = [
    "// Composed by scripts/regenerate_protowire.sh from rusty-kaspa's three envelopes (see there).",
    'syntax = "proto3";',
    "package protowire;",
    "",
    'option go_package = "github.com/kaspanet/kaspad/protowire";',
    "",
    'import "p2p.proto";',
    'import "rpc.proto";',
    "",
    "message KaspadMessage {",
    "  oneof payload {",
]
lines += [f"    {t} {n} = {k};" for t, n, k in fields]
lines += [
    "  }",
    "}",
    "",
    "service P2P {",
    "  rpc MessageStream (stream KaspadMessage) returns (stream KaspadMessage) {}",
    "}",
    "",
    "service RPC {",
    "  rpc MessageStream (stream KaspadMessage) returns (stream KaspadMessage) {}",
    "}",
    "",
]
open(out, "w").write("\n".join(lines))
PY

cd "$WORK"
"$PROTOC" \
  --plugin=protoc-gen-swift="$SWIFT_PLUGIN" \
  --plugin=protoc-gen-grpc-swift="$GRPC_PLUGIN" \
  --swift_out="$WORK" --grpc-swift_out="$WORK" \
  -I "$WORK" messages.proto p2p.proto rpc.proto

for f in messages.pb.swift p2p.pb.swift rpc.pb.swift messages.grpc.swift; do
  cp "$WORK/$f" "$OUT/$f"
done
echo "regenerated into $OUT"
