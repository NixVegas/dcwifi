{
  lib,
  config,
  pkgs,
  ...
}:

let
  inherit (builtins) hashString;

  inherit (lib.strings) substring toLower;
  inherit (lib.lists) singleton;
  inherit (lib.options) mkEnableOption mkOption;
  inherit (lib.modules) mkDefault mkMerge mkIf;
  inherit (lib) types;

  cfg = config.nixVegas.dcWifi;

  # Use a random (but deterministic) username to avoid having to patch supplicant
  # to support the "ext:secret_name_here" notation for usernames.
  defaultUsername =
    assert config.networking.hostName != "";
    substring 0 16 (
      hashString "sha256" "dcwifi:${toString config.nixVegas.defcon}:${config.networking.hostName}"
    );

  # Backend selection: use NetworkManager if it manages the host, otherwise the
  # wpa_supplicant path. Both configure the same PEAP/MSCHAPV2 DefCon network.
  useNM = config.networking.networkmanager.enable;

  # Only do anything where there's an actual wifi backend to configure.
  hasBackend = useNM || config.networking.wireless.enable;

  # The registration service (and the secret it writes) run as this user: root
  # under NM (to drive nmcli and reload declarative profiles), otherwise the
  # sandboxed wpa_supplicant user.
  secretUser = if useNM then "root" else "wpa_supplicant";

  # Secret file, written by the registration service and consumed by whichever
  # backend is active (wpa_supplicant ext_password, or NM envsubst).
  secretsFile = "/etc/nixvegas/dc${toString config.nixVegas.defcon}/${toLower config.networking.hostName}.env";

  # Secret name for Supplicant.
  secretName = "dc${toString config.nixVegas.defcon}_${cfg.username}_wifi_pass";

  # Secret name for the random username (only used when randomUsername = true).
  # The hostname-hash key is fine here even when the username itself is random, it's just used locally.
  userSecretName = "dc${toString config.nixVegas.defcon}_${cfg.username}_wifi_user";
in
{
  options = {
    nixVegas.defcon = mkOption {
      type = types.int;
      default = 34;
      description = "The DEF CON this wifi module is for";
    };
    nixVegas.dcWifi = {
      enable = mkEnableOption "DEF CON wifi autoconfiguration";
      username = mkOption {
        type = types.strMatching "^[a-zA-Z0-9]{8,}$";
        default = defaultUsername;
        defaultText = ''
          substring 0 16 (
            hashString
              "sha256"
              "dcwifi:''${toString config.nixVegas.defcon}:''${config.networking.hostName}"
            )
          )
        '';
        description = ''
          The username to use for wifi registration. Note that wpa_supplicant
          does not support ext:secret_name here without a patch,
          so we derive it deterministically from your hostname by default.
          If you don't want to use the default (maybe you're worried about
          fingerprinting, although we try to obfuscate it) then you can override
          it to something custom here.
        '';
      };
      passwordTemplate = mkOption {
        type = types.str;
        default = "<random:16-24>";
        description = ''
          Template to use for the password. The only token here is <random:min-max>
          or <random:max> which will get substituted at runtime. Defaults to a 16-24
          character random password.
        '';
      };
      randomUsername = mkEnableOption ''
        a random per-machine username, generated at registration time from
        usernameFormat instead of the deterministic hostname-derived one. Needed
        when many machines share a hostname (e.g. netboot), where the derived
        username would collide. On the wpa_supplicant backend this needs an
        identity=ext: supplicant patch, which is applied automatically via an
        overlay; NetworkManager needs no patch (it substitutes the username into
        the profile directly)
      '';
      usernameFormat = mkOption {
        type = types.str;
        default = "<random:16-24>";
        description = ''
          Template for the random username, using the same <random:min-max> /
          <random:max> token as passwordTemplate. Only used when randomUsername
          is true. Defaults to a 16-24 character random username.
        '';
      };
      caCert = mkOption {
        type = types.path;
        default =
          pkgs.runCommand "hellenic-academic-root-ca.crt" { src = ./hellenic-academic-root-ca.crt; }
            ''
              cp $src $out
            '';
        description = ''
          Root CA cert to use.
        '';
      };
      secretName = mkOption {
        type = types.strMatching "^[a-z][a-z0-9_]+$";
        default = secretName;
        description = ''
          Name of the secret. Default 'dc##_<USERNAME>_wifi_pass'.
        '';
      };
    };
  };

  config = mkMerge [
    {
      nixVegas.dcWifi.enable = mkDefault true;
      # Default random usernames on under NetworkManager: NM images (e.g. netboot)
      # share a hostname, so the derived username would collide across machines,
      # and NM needs no supplicant patch to use a random one (it's substituted
      # into the profile directly). wpa_supplicant hosts stay deterministic by
      # default, since there the random path pulls in the identity-ext patch.
      nixVegas.dcWifi.randomUsername = mkDefault useNM;
    }

    (mkIf (cfg.enable && hasBackend) {
      systemd.timers."nixvegas-dc-wifi-registration" = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          OnBootSec = "5m";
          OnUnitActiveSec = "6h";
          Unit = "nixvegas-dc-wifi-registration.service";
        };
      };
      systemd.services."nixvegas-dc-wifi-registration" = {
        serviceConfig =
          let
            wifiReg = pkgs.writeShellApplication {
              name = "nixvegas-dc-wifi-registration";
              text = lib.readFile ./wifi-reg.sh;
              runtimeInputs = [
                pkgs.curl
                pkgs.openssl
              ]
              ++ lib.optional useNM pkgs.networkmanager # nmcli
              ++ lib.optional (!useNM) pkgs.wpa_supplicant; # wpa_cli
            };
          in
          {
            Type = "oneshot";
            User = secretUser;
            Group = secretUser;
            ExecStart = "${lib.getExe wifiReg}";
          };
        environment = {
          WIFIREG_USERNAME = cfg.username;
          WIFIREG_PASSWORD_TEMPLATE = cfg.passwordTemplate;
          WIFIREG_SECRETS_FILE = secretsFile;
          WIFIREG_SECRET_NAME = cfg.secretName;
          WIFIREG_BACKEND = if useNM then "networkmanager" else "wpa_supplicant";
          WIFIREG_WPA_CTRL = "/run/wpa_supplicant/control";
          WIFIREG_NM_PROFILE = "DefCon";
          WIFIREG_BASE = mkDefault "https://wifireg.defcon.org/";
          # Random-username mode: generate the username too, and store it under
          # its own secret name for identity=ext:/envsubst to reference.
          WIFIREG_RANDOM_USERNAME = if cfg.randomUsername then "1" else "0";
          WIFIREG_USERNAME_TEMPLATE = cfg.usernameFormat;
          WIFIREG_USER_SECRET_NAME = userSecretName;
        };
      };
      # Pre-create the secret (owned by the backend's user) so first boot has it:
      # wpa_supplicant BindReadOnly-mounts it, and NM's ensure-profiles loads it
      # as an EnvironmentFile — both fail if it's missing. Registration fills it.
      systemd.tmpfiles.rules = [
        "d ${builtins.dirOf secretsFile} 0700 ${secretUser} ${secretUser} -"
        "f ${secretsFile} 0600 ${secretUser} ${secretUser} -"
      ];
    })
    (mkIf (cfg.enable && !useNM) {
      networking.wireless = {
        fallbackToWPA2 = mkDefault false;
        allowAuxiliaryImperativeNetworks = mkDefault true;
        userControlled = mkDefault true;
        secretsFile = secretsFile;
        networks."DefCon" = {
          priority = mkDefault 5;
          authProtocols = mkDefault (singleton "WPA-EAP");
          auth = mkDefault ''
            proto=RSN
            pairwise=CCMP
            auth_alg=OPEN
            eap=PEAP
            ${if cfg.randomUsername then "identity=ext:${userSecretName}" else "identity=\"${cfg.username}\""}
            password=ext:${cfg.secretName}
            phase1="peaplabel=0"
            phase2="auth=MSCHAPV2"
            ca_cert="${cfg.caCert}"
            subject_match="CN=wifireg.defcon.org"
            altsubject_match="DNS:wifi.defcon.org;DNS:wifireg.defcon.org"
          '';
        };
      };
    })
    (mkIf (cfg.enable && useNM) {
      networking.networkmanager.ensureProfiles = {
        environmentFiles = [ secretsFile ];
        profiles."DefCon" = {
          connection = {
            id = "DefCon";
            type = "wifi";
          };
          wifi = {
            ssid = "DefCon";
            mode = "infrastructure";
          };
          wifi-security.key-mgmt = "wpa-eap";
          "802-1x" = {
            eap = "peap";
            # Random usernames are substituted from the secret file by envsubst;
            # NM hands the identity to wpa_supplicant over D-Bus, so no patch needed.
            identity = if cfg.randomUsername then "\${${userSecretName}}" else cfg.username;
            phase2-auth = "mschapv2";
            password = "\${${cfg.secretName}}";
            password-flags = 0;
            ca-cert = toString cfg.caCert;
            subject-match = "wifireg.defcon.org";
            altsubject-matches = "DNS:wifi.defcon.org;DNS:wifireg.defcon.org";
          };
        };
      };
    })

    # A random username can't be baked into the wpa_supplicant config, so it's
    # referenced as identity=ext:<name>. Stock wpa_supplicant only supports ext:
    # for psk/password, so carry a small patch that extends it to identity.
    # NetworkManager doesn't need this (it substitutes the username directly).
    (mkIf (cfg.enable && cfg.randomUsername && !useNM) {
      nixpkgs.overlays = [
        (final: prev: {
          wpa_supplicant = prev.wpa_supplicant.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./wpa-supplicant-identity-ext.patch ];
          });
        })
      ];
    })
  ];
}
