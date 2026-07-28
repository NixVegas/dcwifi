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

  # The registration service (and the secret it writes) run as this user: root
  # under NM (to drive nmcli and reload declarative profiles), otherwise the
  # sandboxed wpa_supplicant user.
  secretUser = if useNM then "root" else "wpa_supplicant";

  # Secret file, written by the registration service and consumed by whichever
  # backend is active (wpa_supplicant ext_password, or NM envsubst).
  secretsFile = "/etc/nixvegas/dc${toString config.nixVegas.defcon}/${toLower config.networking.hostName}.env";

  # Secret name for Supplicant.
  secretName = "dc${toString config.nixVegas.defcon}_${cfg.username}_wifi_pass";
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
      caCert = mkOption {
        type = types.path;
        default = ./hellenic-academic-root-ca.crt;
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
    }

    (mkIf cfg.enable {
      systemd.timers."nixvegas-dc-wifi-registration" = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          OnBootSec = "5m";
          OnUnitActiveSec = "5m";
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
            identity="${cfg.username}"
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
            identity = cfg.username;
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
  ];
}
