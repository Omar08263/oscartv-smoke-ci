#!/usr/bin/env python3
"""Generate the docker-compose override that routes the shadow validator's
L1 EL RPC through the one-shot fault proxy (running on the host).

Reads the devnet docker-compose.yml (post-PR tree), copies the
base-shadow-validator service's full `command` list verbatim, and replaces
only the `--l1-eth-rpc` value `http://l1-el:${L1_HTTP_PORT}` with
`http://host.docker.internal:18545`. Adds the host-gateway mapping so the
container can reach the host proxy. Everything else (beacon URL, ports,
volumes, healthcheck) is untouched.

Usage: gen_shadow_override.py <docker-compose.yml> <out-override.yml>
"""
import sys

import yaml

PROXY_URL = "http://host.docker.internal:18545"
L1_EL_URL = "http://l1-el:${L1_HTTP_PORT}"


def bool_safe_loader():
    """A SafeLoader that does NOT resolve YAML 1.1 booleans.

    The shadow validator's command contains the bare word ``Off`` (the
    value of ``--p2p.scoring``). PyYAML's default loader resolves it to
    the boolean False, and re-dumping writes ``false`` — which Docker
    Compose (YAML 1.2) then rejects with "command.N must be a string".
    With bool resolution disabled, ``Off`` stays the string "Off", which
    is exactly what the node's CLI expects and what Compose accepts
    (the base compose file itself carries ``- Off`` unquoted).
    """
    loader = yaml.SafeLoader
    for ch in list(loader.yaml_implicit_resolvers):
        loader.yaml_implicit_resolvers[ch] = [
            (tag, regexp)
            for tag, regexp in loader.yaml_implicit_resolvers[ch]
            if tag != "tag:yaml.org,2002:bool"
        ]
    return loader


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src) as f:
        doc = yaml.load(f, Loader=bool_safe_loader())
    svc = doc["services"]["base-shadow-validator"]
    cmd = list(svc["command"])
    assert "--l1-eth-rpc" in cmd, "shadow validator command has no --l1-eth-rpc"
    assert all(isinstance(x, str) for x in cmd), (
        "non-string command item after bool-safe load: "
        + repr([x for x in cmd if not isinstance(x, str)])
    )
    i = cmd.index("--l1-eth-rpc")
    assert cmd[i + 1] == L1_EL_URL, f"unexpected L1 URL: {cmd[i + 1]!r}"
    cmd[i + 1] = PROXY_URL
    override = {
        "services": {
            "base-shadow-validator": {
                "command": cmd,
                "extra_hosts": ["host.docker.internal:host-gateway"],
            }
        }
    }
    with open(dst, "w") as f:
        yaml.safe_dump(override, f, sort_keys=False)
    print(f"wrote {dst}: --l1-eth-rpc -> {PROXY_URL} (command items: {len(cmd)})")


if __name__ == "__main__":
    main()
