# -*- coding: utf-8 -*-
"""
Filters for solarwinds/sync.yml: normalize SolarWinds nodes and plan the NetBox changes.

    sw_normalize(nodes, mapping)       SolarWinds rows -> normalized records (see mapping.yml)
    sw_plan(records, netbox_devices)   records + current NetBox devices -> what to create/update/flag

Pure functions (no I/O), so the rules are easy to read and test.
"""
import ipaddress
import re


def _first(rules, text):
    for rule in rules or []:
        if re.search(rule["match"], text or "", re.IGNORECASE):
            return rule
    return None


def _valid_ip(value):
    try:
        return str(ipaddress.ip_address(str(value).strip()))
    except ValueError:
        return None


def _hostname(node, cfg):
    raw = ""
    for field in cfg.get("sources", ["Caption"]):
        raw = str(node.get(field) or "").strip()
        if raw:
            break
    if cfg.get("strip_domain", True) and not _valid_ip(raw):
        raw = raw.split(".")[0]
    if cfg.get("lowercase", True):
        raw = raw.lower()
    return re.sub(r"[^A-Za-z0-9._-]+", "-", raw).strip("-")


def sw_normalize(nodes, mapping):
    records = []
    for node in nodes or []:
        vendor = str(node.get("Vendor") or "")
        rec = {
            "node_id": node.get("NodeID"),
            "caption": node.get("Caption"),
            "name": _hostname(node, mapping.get("hostname", {})),
            "ip": _valid_ip(node.get("IPAddress") or ""),
            "vendor": vendor,
            "model": node.get("MachineType"),
            "os_version": node.get("IOSVersion"),
            "location": node.get("Location"),
            "manufacturer": None,
            "platform": None,
            "site": mapping.get("default_site", "unassigned"),
            "role": mapping.get("default_role", "unassigned"),
            "skip_reason": None,
        }

        for rule in mapping.get("skip", []):
            if re.search(rule["match"], str(node.get(rule["field"]) or ""), re.IGNORECASE):
                rec["skip_reason"] = rule.get("reason") or "%s matches %s" % (rule["field"], rule["match"])
                break

        vendor_rule = _first(mapping.get("vendors"), vendor)
        if vendor_rule:
            rec["manufacturer"] = vendor_rule["manufacturer"]
            platform_text = " ".join(str(node.get(f) or "") for f in mapping.get("platform_fields", ["MachineType", "IOSImage", "IOSVersion"]))
            for rule in mapping.get("platforms", []):
                if rule["manufacturer"] == rec["manufacturer"] and re.search(rule["match"], platform_text, re.IGNORECASE):
                    rec["platform"] = rule["platform"]
                    break
        elif not rec["skip_reason"]:
            rec["skip_reason"] = "vendor '%s' is not a supported network vendor" % (vendor or "unknown")

        if not rec["skip_reason"] and not rec["name"]:
            rec["skip_reason"] = "no usable name"
        if not rec["skip_reason"] and not rec["ip"]:
            rec["skip_reason"] = "no valid IP address"

        site_rule = _first(mapping.get("sites"), str(node.get(mapping.get("site_field", "Location")) or ""))
        if site_rule:
            rec["site"] = site_rule["site"]
        role_rule = _first(mapping.get("roles"), rec["name"])
        if role_rule:
            rec["role"] = role_rule["role"]

        records.append(rec)
    return records


def _host(address):
    return (address or "").split("/")[0] or None


def sw_plan(records, netbox_devices, managed_tag="from-solarwinds", gone_tag="not-in-solarwinds"):
    devices = netbox_devices or []
    by_node, by_name, by_ip = {}, {}, {}
    for d in devices:
        node_id = (d.get("custom_fields") or {}).get("solarwinds_node_id")
        if node_id is not None:
            by_node[int(node_id)] = d
        if d.get("name"):
            by_name[d["name"].lower()] = d
        ip = _host(((d.get("primary_ip4") or {}).get("address")))
        if ip:
            by_ip[ip] = d

    plan = {"create": [], "update": [], "unchanged": [], "skipped": [], "conflicts": [], "gone": []}
    seen_devices, seen_names = set(), {}

    for rec in records or []:
        if rec.get("skip_reason"):
            plan["skipped"].append(rec)
            continue
        if rec["name"] in seen_names:
            plan["conflicts"].append(dict(rec, conflict="same name as SolarWinds node %s" % seen_names[rec["name"]]))
            continue
        seen_names[rec["name"]] = rec["node_id"]

        match, how = None, None
        if rec["node_id"] is not None and int(rec["node_id"]) in by_node:
            match, how = by_node[int(rec["node_id"])], "node id"
        elif rec["name"] in by_name:
            match, how = by_name[rec["name"]], "name"
        elif rec["ip"] in by_ip:
            match, how = by_ip[rec["ip"]], "IP"

        if not match:
            plan["create"].append(rec)
            continue

        seen_devices.add(match["id"])
        tags = [t["slug"] for t in match.get("tags") or []]
        new_tags = [t for t in tags if t != gone_tag]
        if managed_tag not in new_tags:
            new_tags.append(managed_tag)
        changes = {}
        if (match.get("custom_fields") or {}).get("solarwinds_node_id") is None:
            changes["custom_fields"] = {"solarwinds_node_id": rec["node_id"]}
        if not match.get("platform") and rec.get("platform"):
            changes["platform"] = rec["platform"]
        if sorted(new_tags) != sorted(tags):
            changes["tags"] = new_tags
        entry = {"id": match["id"], "name": match["name"], "matched_by": how, "record": rec, "changes": changes}
        (plan["update"] if changes else plan["unchanged"]).append(entry)

    for d in devices:
        node_id = (d.get("custom_fields") or {}).get("solarwinds_node_id")
        tags = [t["slug"] for t in d.get("tags") or []]
        if node_id is not None and d["id"] not in seen_devices and gone_tag not in tags:
            plan["gone"].append({"id": d["id"], "name": d["name"], "node_id": node_id, "tags": tags + [gone_tag]})
    return plan


class FilterModule(object):
    def filters(self):
        return {"sw_normalize": sw_normalize, "sw_plan": sw_plan}
