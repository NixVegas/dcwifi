{
  lib,
  pkgs,
  testers,
  self,
  ...
}:

let
  ssid = "DefCon";
  wlan = "wlan0";
  hostName = "client";

  # vwifi hub address + ports (see the kismet NixOS test for the topology).
  hubAddress = "192.168.1.1";
  vwifiTcp = 8212;

  # A test CA + server cert whose CN/SANs satisfy the module's hard-coded
  # subject_match="CN=wifireg.defcon.org" / altsubject_match=DNS:wifi.defcon.org,
  # DNS:wifireg.defcon.org, so the client's PEAP server-cert validation passes.
  certs = pkgs.runCommand "dcwifi-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$out/ca.key" -out "$out/ca.crt" -subj "/CN=dcwifi-test-ca"
    openssl req -newkey rsa:2048 -nodes \
      -keyout "$out/server.key" -out "$out/server.csr" -subj "/CN=wifireg.defcon.org"
    cat > ext.cnf <<EOF
    subjectAltName = DNS:wifireg.defcon.org, DNS:wifi.defcon.org
    extendedKeyUsage = serverAuth
    EOF
    openssl x509 -req -in "$out/server.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" \
      -CAcreateserial -days 3650 -extfile ext.cnf -out "$out/server.crt"
  '';

  # Fake wifireg backend. Mirrors what wifi-reg.sh POSTs: a urlencoded body of
  # username/password/password2/submit=REGISTER. Validates the shape, records
  # "username=password" (so the test can read back what was registered and feed
  # it to hostapd), and 200s only on a well-formed REGISTER.
  fakeWifireg = pkgs.writers.writePython3 "fake-wifireg" { flakeIgnore = [ "E501" ]; } ''
    import os
    import urllib.parse
    from http.server import BaseHTTPRequestHandler, HTTPServer

    LOG = "/var/lib/wifireg/registrations"


    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            form = urllib.parse.parse_qs(self.rfile.read(n).decode())

            def one(k):
                v = form.get(k, [])
                return v[0] if v else None

            user, pw, pw2, submit = one("username"), one("password"), one("password2"), one("submit")
            if not user or not pw or pw != pw2 or submit != "REGISTER":
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"bad request\n")
                return

            os.makedirs(os.path.dirname(LOG), exist_ok=True)
            with open(LOG, "a") as f:
                f.write(user + "=" + pw + "\n")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"registered\n")

        def log_message(self, *a):
            pass


    HTTPServer(("0.0.0.0", 80), Handler).serve_forever()
  '';

  # Every node with a virtual radio joins the vwifi hub.
  vwifiClient = macPrefix: {
    services.vwifi = {
      module = {
        enable = true;
        inherit macPrefix;
      };
      client = {
        enable = true;
        serverAddress = hubAddress;
      };
    };
  };
  eth1 = addr: {
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = addr;
        prefixLength = 24;
      }
    ];
  };
in
testers.runNixOSTest {
  name = "dcwifi";

  nodes = {
    # Fake registration portal + the vwifi hub.
    wifireg =
      { ... }:
      lib.mkMerge [
        (eth1 hubAddress)
        {
          services.vwifi.server = {
            enable = true;
            ports.tcp = vwifiTcp;
            openFirewall = true;
          };
          networking.firewall.allowedTCPPorts = [ 80 ];
          systemd.services.wifireg = {
            description = "fake wifireg backend";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${fakeWifireg}";
              StateDirectory = "wifireg";
            };
          };
        }
      ];

    # WPA2-Enterprise AP acting as its own EAP server (PEAP/MSCHAPV2). The
    # structured hostapd module has no enterprise auth mode, so use mode="none"
    # and define the whole 802.1X/EAP server via freeform settings. hostapd is
    # NOT started at boot: the eap_user file is written by the test (with the
    # creds the client actually registers) before it's brought up.
    ap =
      { ... }:
      lib.mkMerge [
        (eth1 "192.168.1.2")
        (vwifiClient "02:00:00:00:01")
        {
          systemd.services.hostapd.wantedBy = lib.mkForce [ ];
          services.hostapd = {
            enable = true;
            radios.${wlan} = {
              band = "2g";
              channel = 1;
              networks.${wlan} = {
                inherit ssid;
                authentication.mode = "none";
                settings = {
                  wpa = 2;
                  wpa_key_mgmt = "WPA-EAP";
                  rsn_pairwise = "CCMP";
                  ieee8021x = 1;
                  eap_server = 1;
                  eap_user_file = "/etc/hostapd.eap_user";
                  ca_cert = "${certs}/ca.crt";
                  server_cert = "${certs}/server.crt";
                  private_key = "${certs}/server.key";
                };
              };
            };
          };
        }
      ];

    # The device under test: the dcwifi module, pointed at the fake portal, with
    # its PEAP server-cert trust anchored on the test CA.
    client =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        config = lib.mkMerge [
          (eth1 "192.168.1.3")
          (vwifiClient "02:00:00:00:02")
          {
            networking.hostName = hostName;
            nixVegas.dcWifi.caCert = "${certs}/ca.crt";
            # The test framework forces wireless off via mkVMOverride (prio 10),
            # which beats the module's mkDefault; force it back on like the
            # kismet test's station does.
            networking.wireless.enable = lib.mkOverride 0 true;
            networking.wireless.interfaces = [ wlan ];
            # Point registration at the fake portal instead of wifireg.defcon.org.
            systemd.services.nixvegas-dc-wifi-registration.environment.WIFIREG_BASE =
              lib.mkForce "http://${hubAddress}/";
          }
        ];
      };

    # The same module on a NetworkManager-managed host: it must auto-detect NM
    # and configure a declarative NM profile instead of wpa_supplicant.
    nmclient =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        config = lib.mkMerge [
          (eth1 "192.168.1.4")
          (vwifiClient "02:00:00:00:03")
          {
            networking.hostName = "nmclient";
            nixVegas.dcWifi.caCert = "${certs}/ca.crt";
            # Pin deterministic to test the derived-username path (NM now defaults
            # randomUsername on).
            nixVegas.dcWifi.randomUsername = false;
            networking.networkmanager.enable = true;
            networking.wireless.enable = lib.mkOverride 0 true;
            networking.networkmanager.ensureProfiles.profiles.DefCon = {
              ipv4.method = "link-local";
              ipv6.method = "disabled";
            };
            # Keep NM off the wired test interfaces so the static vwifi-hub
            # address survives; NM only needs to manage the wifi radio.
            networking.networkmanager.unmanaged = [
              "interface-name:eth0"
              "interface-name:eth1"
            ];
            systemd.services.nixvegas-dc-wifi-registration.environment.WIFIREG_BASE =
              lib.mkForce "http://${hubAddress}/";
          }
        ];
      };

    # NetworkManager + random per-machine username (the netboot case): the module
    # must generate + persist the username and substitute it into the NM profile
    # (identity=${…}) via envsubst — no supplicant patch needed on this backend.
    # (The wpa_supplicant identity=ext: patch path can't be exercised here: its
    # overlay conflicts with the test framework's read-only nixpkgs; it's checked
    # by a standalone build instead.)
    randomclient =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        config = lib.mkMerge [
          (eth1 "192.168.1.5")
          (vwifiClient "02:00:00:00:04")
          {
            networking.hostName = "randomclient";
            nixVegas.dcWifi.caCert = "${certs}/ca.crt";
            # randomUsername is left unset: it defaults on under NM, so this node
            # also exercises that default.
            networking.networkmanager.enable = true;
            networking.wireless.enable = lib.mkOverride 0 true;
            networking.networkmanager.ensureProfiles.profiles.DefCon = {
              ipv4.method = "link-local";
              ipv6.method = "disabled";
            };
            networking.networkmanager.unmanaged = [
              "interface-name:eth0"
              "interface-name:eth1"
            ];
            systemd.services.nixvegas-dc-wifi-registration.environment.WIFIREG_BASE =
              lib.mkForce "http://${hubAddress}/";
          }
        ];
      };
  };

  testScript = { nodes, ... }: ''
    import shlex

    reg = "nixvegas-dc-wifi-registration.service"

    wpa_secrets = "${nodes.client.networking.wireless.secretsFile}"
    wpa_name = "${nodes.client.nixVegas.dcWifi.secretName}"
    wpa_user = "${nodes.client.nixVegas.dcWifi.username}"

    nm_secrets = "${builtins.head nodes.nmclient.networking.networkmanager.ensureProfiles.environmentFiles}"
    nm_name = "${nodes.nmclient.nixVegas.dcWifi.secretName}"
    nm_user = "${nodes.nmclient.nixVegas.dcWifi.username}"

    rand_secrets = "${builtins.head nodes.randomclient.networking.networkmanager.ensureProfiles.environmentFiles}"
    rand_pass_name = "${nodes.randomclient.nixVegas.dcWifi.secretName}"
    rand_derived_user = "${nodes.randomclient.nixVegas.dcWifi.username}"

    wifireg.start()
    wifireg.wait_for_unit("wifireg.service")
    wifireg.wait_for_open_port(80)
    wifireg.wait_for_unit("vwifi-server.service")
    wifireg.wait_for_open_port(${toString vwifiTcp})

    client.start()
    nmclient.start()
    randomclient.start()
    client.wait_for_unit("multi-user.target")
    nmclient.wait_for_unit("multi-user.target")
    randomclient.wait_for_unit("multi-user.target")

    with subtest("registration: wpa_supplicant backend"):
      # Nothing registered yet.
      client.succeed(f"test ! -e {wpa_secrets} || ! grep -q '^{wpa_name}=' {wpa_secrets}")
      # Run the oneshot; systemctl start blocks until it finishes.
      client.succeed(f"systemctl start {reg}")
      # Secret persisted, password matches the 16-24 alnum template, owned 0600
      # by the sandboxed wpa_supplicant user.
      client.succeed(f"grep -Eq '^{wpa_name}=[0-9A-Za-z]{{16,24}}$' {wpa_secrets}")
      client.succeed(f"test $(stat -c '%a' {wpa_secrets}) = 600")
      client.succeed(f"test $(stat -c '%U' {wpa_secrets}) = wpa_supplicant")
      # The portal saw that username with password == password2, and it matches.
      wifireg.succeed(f"grep -Eq '^{wpa_user}=[0-9A-Za-z]{{16,24}}$' /var/lib/wifireg/registrations")
      stored = client.succeed(f"sed -n 's/^{wpa_name}=//p' {wpa_secrets}").strip()
      received = wifireg.succeed(f"sed -n 's/^{wpa_user}=//p' /var/lib/wifireg/registrations").strip()
      assert stored == received, f"stored {stored!r} != portal {received!r}"
      # Idempotent: a second run must not re-register.
      client.succeed(f"systemctl start {reg}")
      n = int(wifireg.succeed(f"grep -c '^{wpa_user}=' /var/lib/wifireg/registrations").strip())
      assert n == 1, f"expected 1 wpa registration, got {n}"

    with subtest("registration: networkmanager backend"):
      nmclient.wait_for_unit("NetworkManager.service")
      nmclient.succeed(f"systemctl start {reg}")
      nmclient.succeed(f"grep -Eq '^{nm_name}=[0-9A-Za-z]{{16,24}}$' {nm_secrets}")
      # Runs as root under NM (needed for nmcli / profile reload).
      nmclient.succeed(f"test $(stat -c '%a' {nm_secrets}) = 600")
      nmclient.succeed(f"test $(stat -c '%U' {nm_secrets}) = root")
      wifireg.succeed(f"grep -Eq '^{nm_user}=[0-9A-Za-z]{{16,24}}$' /var/lib/wifireg/registrations")

    with subtest("registration: random username (networkmanager)"):
      randomclient.wait_for_unit("NetworkManager.service")
      randomclient.succeed(f"systemctl start {reg}")
      # A random username was generated + persisted (16-24 alnum), plus the password.
      randomclient.succeed(f"grep -Eq '_wifi_user=[0-9A-Za-z]{{16,24}}$' {rand_secrets}")
      randomclient.succeed(f"grep -Eq '^{rand_pass_name}=[0-9A-Za-z]{{16,24}}$' {rand_secrets}")
      rand_user = randomclient.succeed(f"sed -n 's/.*_wifi_user=//p' {rand_secrets}").strip()
      # It is NOT the deterministic hostname-derived username, and the portal saw it.
      assert rand_user != rand_derived_user, "username was not randomized"
      wifireg.succeed("grep -q " + shlex.quote("^" + rand_user + "=") + " /var/lib/wifireg/registrations")

    with subtest("association: start hostapd"):
      ap.start()
      ap.wait_for_unit("vwifi-client.service")

      # Build the EAP user DB from every registration the portal recorded, so
      # both clients' (username, password) pairs authenticate against the AP.
      eap = "*\tPEAP\n"
      for line in wifireg.succeed("cat /var/lib/wifireg/registrations").splitlines():
          line = line.strip()
          if not line or line.startswith("#"):
              continue
          u, pw = line.split("=", 1)
          eap += f'"{u}"\tMSCHAPV2\t"{pw}"\t[2]\n'
      ap.succeed("printf '%s' " + shlex.quote(eap) + " > /etc/hostapd.eap_user")
      ap.succeed("systemctl start hostapd.service")
      ap.wait_for_unit("hostapd.service")

      with subtest("association: wpa_supplicant"):
        # wpa_supplicant client: nudge with reconfigure (the module's own reload path).
        wpa_unit = "wpa_supplicant-${wlan}.service"
        ctrl = "/run/wpa_supplicant/control"
        client.wait_for_unit(wpa_unit)
        wpa_ok = False
        for i in range(60):
            if i % 8 == 0:
                client.succeed(f"wpa_cli -p {ctrl} -i ${wlan} reconfigure || true")
            st, _ = client.execute(f"journalctl -u {wpa_unit} | grep -Eqi '${wlan}: CTRL-EVENT-CONNECTED'")
            if st == 0:
                wpa_ok = True
                break
            client.sleep(2)
        assert wpa_ok, "wpa_supplicant client never associated"

      with subtest("association: networkmanager"):
        # NetworkManager client: activate the declarative DefCon profile.
        nm_ok = False
        for _ in range(60):
            st, _ = nmclient.execute("nmcli -w 5 connection up DefCon")
            if st == 0:
                nm_ok = True
                break
            nmclient.sleep(2)
        assert nm_ok, "networkmanager client never activated the DefCon profile"

      with subtest("association: random username (networkmanager)"):
        # NM substitutes the random identity into the profile via envsubst and
        # authenticates as the random username the AP now knows.
        rand_ok = False
        for _ in range(60):
            st, _ = randomclient.execute("nmcli -w 5 connection up DefCon")
            if st == 0:
                rand_ok = True
                break
            randomclient.sleep(2)
        assert rand_ok, "random-username networkmanager client never activated"
  '';
}
