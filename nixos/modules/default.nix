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

  # Default secrets file for Supplicant.
  defaultSecretsFile = lib.mkDefault "/etc/nixvegas/dc${toString config.nixVegas.defcon}/${toLower config.networking.hostName}.env";

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

    # Gate only on the module's own switch. Do NOT also gate on
    # config.networking.wireless.enable: this block defines networking.wireless.*
    # options, and reading a sibling wireless option to decide whether to define
    # one creates an infinite recursion once the ISO/initrd build pulls the
    # wireless submodule through environment.etc.
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
                pkgs.wpa_supplicant # wpa_cli, to reconfigure over the control socket
              ];
            };
          in
          {
            # Run as the same user wpa_supplicant does: the secret it writes is
            # then owned by (and only readable by) that user, and it can pick up
            # the new secret over the control socket without root.
            Type = "oneshot";
            User = "wpa_supplicant";
            Group = "wpa_supplicant";
            ExecStart = "${lib.getExe wifiReg}";
          };
        environment = {
          WIFIREG_USERNAME = cfg.username;
          WIFIREG_PASSWORD_TEMPLATE = cfg.passwordTemplate;
          WIFIREG_SECRETS_FILE = config.networking.wireless.secretsFile;
          WIFIREG_SECRET_NAME = cfg.secretName;
          # wpa_supplicant's control-socket dir; wpa_cli reconfigure lives here.
          WIFIREG_WPA_CTRL = "/run/wpa_supplicant/control";
          WIFIREG_BASE = mkDefault "https://wifireg.defcon.org/";
        };
      };
      # The registration service (running as wpa_supplicant) writes the secret
      # here, so the dir must be owned by that user. wpa_supplicant BindReadOnly-
      # mounts the secretsFile, which fails to start if it doesn't exist yet, so
      # pre-create an empty one for first boot (registration fills it in later).
      systemd.tmpfiles.rules = [
        "d ${builtins.dirOf config.networking.wireless.secretsFile} 0700 wpa_supplicant wpa_supplicant -"
        "f ${config.networking.wireless.secretsFile} 0600 wpa_supplicant wpa_supplicant -"
      ];
      networking.wireless = {
        fallbackToWPA2 = mkDefault false;
        allowAuxiliaryImperativeNetworks = mkDefault true;
        userControlled = mkDefault true;
        secretsFile = defaultSecretsFile;
        networks."DefCon" = {
          priority = mkDefault 5;
          authProtocols = mkDefault (singleton "WPA-EAP");
          auth = mkDefault ''
            proto=RSN
            pairwise=CCMP
            auth_alg=OPEN
            eap=PEAP
            identity="${cfg.username}"
            password=ext:${secretName}
            phase1="peaplabel=0"
            phase2="auth=MSCHAPV2"
            ca_cert="${cfg.caCert}"
            subject_match="CN=wifireg.defcon.org"
            altsubject_match="DNS:wifi.defcon.org;DNS:wifireg.defcon.org"
          '';
        };
      };
    })
  ];
}
