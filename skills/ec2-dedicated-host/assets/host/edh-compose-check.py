#!/usr/bin/env python3
"""edh-compose-check.py — the compose.yml rules of ec2-dedicated-host, checked on Compose's normalized config.

Run with python3 -I (stdlib only), both on the operator's Mac (deploy.sh, with placeholder values) and on the
server (edh-deploy.sh, with the real values, before anything is installed):

    docker compose -f DIR/compose.yml config --no-env-resolution --format json > CFG.json
    docker compose -f DIR/compose.yml config --variables --format json > VARS.json      # if supported
    python3 -I edh-compose-check.py CFG.json DIR [--dir ALIAS]... [--data-dir /data] \
        (--variables VARS.json | --scan DIR/compose.yml)

Exit 0: allowed. Exit 1: refused; the reasons are printed (each with its service and key). Exit 2: usage or
unreadable input.
"""
import json
import os
import re
import sys

ALLOWED_VARS = {"EDH_NAME", "APP_IMAGE", "APP_PORT", "APP_MEMORY_MB", "DOMAIN", "MAINT_BYPASS",
                "COMPOSE_PROFILES", "EDH_DATA_DIR", "EDH_HTTP_PORT", "EDH_HTTPS_PORT"}
# files and directories the skill keeps next to compose.yml on the server (/opt/edh/app)
RESERVED_NAMES = {"compose.yml", ".env", "previous_image", "maint-templates"}
RESERVED_SUFFIXES = (".env", ".prev", ".rollback")
# /data/<subdir> that belong to one service
DATA_OWNERS = {"caddy": "caddy", "maint": "caddy", "postgres": "postgres"}
# the only top-level env files, and who may read them
ENV_FILES = {"app.env": "app", "postgres.env": "postgres"}


def usage(msg):
    sys.stderr.write("edh-compose-check.py: %s\n" % msg)
    sys.exit(2)


def main(argv):
    if len(argv) < 2:
        usage("expected CFG.json DIR [options]")
    cfg_path, dirs, data_dir, var_path, scan_path = argv[0], [argv[1]], "/data", None, None
    rest = argv[2:]
    while rest:
        opt = rest.pop(0)
        if not rest:
            usage("%s needs a value" % opt)
        val = rest.pop(0)
        if opt == "--dir":
            dirs.append(val)
        elif opt == "--data-dir":
            data_dir = val
        elif opt == "--variables":
            var_path = val
        elif opt == "--scan":
            scan_path = val
        else:
            usage("unknown option %s" % opt)
    # paths are compared after resolving symlinks (realpath), as the kernel will when it mounts them
    dirs = sorted({os.path.realpath(d) for d in dirs})
    data_dir = os.path.realpath(data_dir)
    try:
        cfg = json.load(open(cfg_path))
    except (OSError, ValueError) as e:
        usage("cannot read %s: %s" % (cfg_path, e))

    found = {"data": [], "host": [], "rules": []}

    def bad(kind, where, why):
        found[kind].append("%s: %s" % (where, why))

    def rel_in(path):
        """path relative to the compose directory if strictly inside it, else None"""
        p = os.path.realpath(path)
        for d in dirs:
            if p.startswith(d + "/"):
                return p[len(d) + 1:]
        return None

    def reserved(name):
        return name in RESERVED_NAMES or name.endswith(RESERVED_SUFFIXES)

    def is_top_file(first):
        return any(os.path.isfile(os.path.join(d, first)) for d in dirs)

    # --- variables: only the ones edh-deploy.sh sets; anything else would come from whatever shell renders it
    names = set()
    if var_path:
        try:
            names = set(json.load(open(var_path)).keys())
        except (OSError, ValueError, AttributeError) as e:
            usage("cannot read %s: %s" % (var_path, e))
    elif scan_path:
        try:
            raw = open(scan_path).read()
        except OSError as e:
            usage("cannot read %s: %s" % (scan_path, e))
        raw = raw.replace("$$", "")
        names = set(re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", raw))
    else:
        usage("give --variables or --scan")
    for n in sorted(names - ALLOWED_VARS):
        bad("rules", "variable ${%s}" % n,
            "not allowed — only %s are set on the server" % ", ".join(sorted(ALLOWED_VARS)))

    for name, svc in sorted((cfg.get("services") or {}).items()):
        w = "service " + name
        if svc.get("build") is not None:
            bad("rules", w + ": build", "not allowed — images are built by deploy.sh and pushed, never on the server")
        for v in svc.get("volumes") or []:
            if v.get("type") != "bind":
                continue
            src = os.path.realpath(v.get("source") or "/")
            if src == data_dir:
                bad("data", w + ": volumes", "bind mount of the whole data directory %s" % src)
                continue
            if src.startswith(data_dir + "/"):
                sub = src[len(data_dir) + 1:].split("/")[0]
                if sub == "backups":
                    bad("data", w + ": volumes", "bind mount of %s (the backup manifest)" % src)
                elif sub in DATA_OWNERS and DATA_OWNERS[sub] != name:
                    bad("rules", w + ": volumes", "%s is reserved for the %s service" % (src, DATA_OWNERS[sub]))
                continue
            rel = rel_in(src)
            if rel is None:
                bad("host", w + ": volumes",
                    "bind mount of %s (allowed: a subdirectory next to compose.yml, or %s/<dir>)" % (src, data_dir))
                continue
            first = rel.split("/")[0]
            if reserved(first):
                bad("rules", w + ": volumes", "bind mount of ./%s — reserved for the skill (secrets and state)" % rel)
            elif is_top_file(first):
                bad("rules", w + ": volumes", "bind mount of the file ./%s — only subdirectories may be mounted" % first)
        for key in ("env_file", "label_file"):
            for item in svc.get(key) or []:
                path = item.get("path") if isinstance(item, dict) else item
                if not path:
                    continue
                rel = rel_in(path)
                if rel is None:
                    bad("rules", "%s: %s" % (w, key), "%s is outside the compose directory" % path)
                elif "/" not in rel:
                    if ENV_FILES.get(rel) != name:
                        bad("rules", "%s: %s" % (w, key), "./%s is not allowed here (only app.env for app, "
                                                          "postgres.env for postgres)" % rel)
                elif reserved(rel.split("/")[0]):
                    bad("rules", "%s: %s" % (w, key), "./%s is reserved for the skill" % rel)
        if svc.get("privileged") is True:
            bad("host", w + ": privileged", "privileged mode")
        for k in ("cap_add", "devices", "device_cgroup_rules", "volumes_from"):
            if svc.get(k):
                bad("host", w + ": " + k, "not allowed")
        for k in ("pid", "ipc", "userns_mode", "network_mode", "cgroup"):
            if str(svc.get(k) or "").lower() == "host":
                bad("host", w + ": " + k, "host namespace")
        for o in svc.get("security_opt") or []:
            if "unconfined" in str(o):
                bad("host", w + ": security_opt", str(o))

    for name, vol in sorted((cfg.get("volumes") or {}).items()):
        if (vol or {}).get("driver_opts"):
            bad("host", "volume " + name + ": driver_opts", "not allowed (a bind device)")
        if (vol or {}).get("external"):
            bad("host", "volume " + name + ": external", "not allowed")
    for name, net in sorted((cfg.get("networks") or {}).items()):
        if (net or {}).get("name") == "host" or (net or {}).get("driver") == "host":
            bad("host", "network " + name, "the host network")
    for top in ("secrets", "configs"):
        for name, item in sorted((cfg.get(top) or {}).items()):
            f = (item or {}).get("file")
            if not f:
                continue
            rel = rel_in(f)
            if rel is None:
                bad("host", "%s %s: file" % (top[:-1], name), "%s is outside the compose directory" % f)
            elif reserved(rel.split("/")[0]):
                bad("rules", "%s %s: file" % (top[:-1], name), "./%s is reserved for the skill" % rel)

    out = []
    if found["data"]:
        out.append("compose.yml mounts the data directory or %s/backups into a container — refusing: that would put "
                   "the backup manifest within the app's reach. Mount only subdirectories such as "
                   "${EDH_DATA_DIR:-/data}/uploads:" % data_dir)
        out += ["  " + x for x in found["data"]]
    if found["host"]:
        out.append("compose.yml gives a container access to the server itself — refusing "
                   "(see references/app-contract.md):")
        out += ["  " + x for x in found["host"]]
    if found["rules"]:
        out.append("compose.yml breaks the compose rules — refusing (see references/app-contract.md):")
        out += ["  " + x for x in found["rules"]]
    if out:
        print("\n".join(out))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
