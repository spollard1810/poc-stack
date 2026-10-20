"""
NetBox custom script: add devices for discovery.

Enter hostname, management IP and platform (one device, or a pasted list).
The device is created with placeholder type/role/site, tagged "discover", and
NetBox then asks AWX to run "NetBox - Discover devices", which logs in and
fills in the real model, serial, OS version and interfaces.

Installed by poc-stack's bootstrap (Customization > Scripts in NetBox).
"""
from django.db import transaction
from django.utils.text import slugify
from netaddr import IPNetwork, AddrFormatError

from dcim.choices import DeviceStatusChoices, InterfaceTypeChoices
from dcim.models import Device, DeviceRole, DeviceType, Interface, Platform, Site
from extras.models import Tag
from extras.scripts import IPAddressWithMaskVar, ObjectVar, Script, StringVar, TextVar
from ipam.models import IPAddress
from utilities.exceptions import AbortScript

DISCOVER_TAG = "discover"
PLACEHOLDER_MODEL = "Pending discovery"
MGMT_IFACE = "mgmt0"

# Shorthands accepted in the bulk list, mapped to platform slugs
PLATFORM_ALIASES = {
    "cisco": "cisco-ios", "ios": "cisco-ios", "iosxe": "cisco-ios", "ios-xe": "cisco-ios",
    "nxos": "cisco-nxos", "nx-os": "cisco-nxos",
    "arista": "arista-eos", "eos": "arista-eos",
    "juniper": "juniper-junos", "junos": "juniper-junos",
}


class AddDevicesForDiscovery(Script):
    class Meta:
        name = "Add devices for discovery"
        description = (
            "Add devices by hostname, management IP and platform. AWX then logs in and "
            "fills in model, serial, OS version and interfaces."
        )
        commit_default = True
        scheduling_enabled = False
        fieldsets = (
            ("One device", ("hostname", "mgmt_ip", "platform")),
            ("Where it goes (optional)", ("site", "role")),
            ("Or many devices at once", ("bulk",)),
        )

    hostname = StringVar(label="Hostname", required=False, max_length=64)
    mgmt_ip = IPAddressWithMaskVar(
        label="Management IP", required=False,
        description="With prefix length, e.g. 10.10.10.11/24",
    )
    platform = ObjectVar(
        model=Platform, required=False,
        description="Decides how Ansible logs in: Cisco IOS / IOS-XE, Cisco NX-OS, Arista EOS or Juniper Junos.",
    )
    site = ObjectVar(model=Site, required=False, description="Leave empty for 'Unassigned'.")
    role = ObjectVar(model=DeviceRole, required=False, description="Leave empty for 'Unassigned'.")
    bulk = TextVar(
        label="Device list", required=False,
        description=(
            "One device per line: hostname,ip[/prefix],platform[,site]. Platform: slug, name, "
            "or cisco / nxos / arista / juniper. Site: slug or name. Uses the site and role "
            "above when a line has none."
        ),
    )

    # -- helpers -------------------------------------------------------------
    def _platform(self, value):
        key = value.strip().lower()
        slug = PLATFORM_ALIASES.get(key, key)
        p = Platform.objects.filter(slug=slug).first() or Platform.objects.filter(name__iexact=value.strip()).first()
        if p is None:
            raise ValueError(f"unknown platform '{value}'")
        if p.manufacturer is None:
            raise ValueError(f"platform '{p}' has no manufacturer set")
        return p

    def _site(self, value, default):
        if not value:
            return default
        s = Site.objects.filter(slug=value.strip().lower()).first() or Site.objects.filter(name__iexact=value.strip()).first()
        if s is None:
            raise ValueError(f"unknown site '{value}'")
        return s

    @staticmethod
    def _ip(value):
        value = value.strip()
        try:
            net = IPNetwork(value if "/" in value else value + ("/128" if ":" in value else "/32"))
        except (AddrFormatError, ValueError):
            raise ValueError(f"'{value}' is not an IP address")
        return net

    def _placeholder_type(self, manufacturer):
        dt, _ = DeviceType.objects.get_or_create(
            manufacturer=manufacturer,
            slug=f"{manufacturer.slug}-pending-discovery",
            defaults={"model": PLACEHOLDER_MODEL, "u_height": 1,
                      "comments": "Placeholder until AWX discovery sets the real model."},
        )
        return dt

    def _add_one(self, name, ip, platform, site, role, tag):
        if Device.objects.filter(name=name).exists():
            self.log_warning(f"{name}: already in NetBox, skipped. To re-run discovery, add the '{DISCOVER_TAG}' tag to it.")
            return False
        existing_ip = IPAddress.objects.filter(address=str(ip)).first() or IPAddress.objects.filter(address__net_host=str(ip.ip)).first()
        if existing_ip and existing_ip.assigned_object is not None:
            self.log_warning(f"{name}: {ip.ip} is already assigned to {existing_ip.assigned_object.parent_object}, skipped.")
            return False

        device = Device(
            name=name, site=site, role=role, platform=platform,
            device_type=self._placeholder_type(platform.manufacturer),
            status=DeviceStatusChoices.STATUS_PLANNED,
            comments="Added for discovery. Model, serial and interfaces are filled in by AWX.",
        )
        device.full_clean()
        device.save()
        device.tags.add(tag)

        iface = Interface(device=device, name=MGMT_IFACE, type=InterfaceTypeChoices.TYPE_VIRTUAL, mgmt_only=True)
        iface.full_clean()
        iface.save()

        addr = existing_ip or IPAddress(address=ip, status="active")
        addr.assigned_object = iface
        addr.full_clean()
        addr.save()

        if ip.version == 4:
            device.primary_ip4 = addr
        else:
            device.primary_ip6 = addr
        device.full_clean()
        device.save()
        self.log_success(f"{name} ({ip}, {platform}) queued for discovery", device)
        return True

    # -- entry point ---------------------------------------------------------
    def run(self, data, commit):
        default_site = data.get("site") or Site.objects.get_or_create(
            slug="unassigned", defaults={"name": "Unassigned", "status": "planned",
                                         "description": "Devices waiting to be placed"})[0]
        role = data.get("role") or DeviceRole.objects.get_or_create(
            slug="unassigned", defaults={"name": "Unassigned", "color": "9e9e9e"})[0]
        tag = Tag.objects.get_or_create(slug=DISCOVER_TAG, defaults={"name": DISCOVER_TAG, "color": "2196f3"})[0]

        rows = []  # (line label, name, ip, platform, site)
        if data.get("hostname") or data.get("mgmt_ip") or data.get("platform"):
            if not (data.get("hostname") and data.get("mgmt_ip") and data.get("platform")):
                raise AbortScript("For a single device, fill in hostname, management IP and platform.")
            rows.append(("form", data["hostname"].strip(), IPNetwork(str(data["mgmt_ip"])), data["platform"], default_site))

        for n, line in enumerate((data.get("bulk") or "").splitlines(), start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if parts[0].lower() == "hostname":
                continue  # header row
            try:
                if len(parts) < 3:
                    raise ValueError("expected hostname,ip,platform[,site]")
                rows.append((f"line {n}", parts[0], self._ip(parts[1]), self._platform(parts[2]),
                             self._site(parts[3] if len(parts) > 3 else "", default_site)))
            except ValueError as e:
                self.log_failure(f"Line {n} ({line}): {e}")

        if not rows:
            raise AbortScript("Nothing to add. Fill in one device, or paste a list.")

        added = 0
        for label, name, ip, platform, site in rows:
            if slugify(name) == "":
                self.log_failure(f"{label}: '{name}' is not a valid hostname")
                continue
            try:
                with transaction.atomic():
                    added += self._add_one(name, ip, platform, site, role, tag)
            except Exception as e:  # one bad row must not stop the rest
                self.log_failure(f"{label} ({name}): {e}")

        msg = f"{added} device(s) queued for discovery. AWX starts the 'NetBox - Discover devices' job when this script finishes."
        if not commit:
            msg = f"Dry run: {added} device(s) would be queued. Tick 'Commit changes' to add them."
        self.log_info(msg)
        return msg
