# dcwifi

Declarative DEF CON wifi registration using standard wpa_supplicant. Includes NetworkManager support.

## Using it

```nix
# flake.nix
{
    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

        dcwifi = {
            # We'll have branches for every year with this naming scheme:
            url = "github:NixVegas/dcwifi/dc34";

            # Only used for NixOS tests, but this should cut down on fetch:
            inputs.nixpkgs.follows = "nixpkgs";
        };
    };
    outputs = { nixpkgs, dcwifi, ... }: {
        nixosConfigurations.default = nixpkgs.lib.nixosSystem {
            modules = [
                # everything is automatic unless you want to change the defaults (below)
                dcwifi.nixosModules.default

                {
                    # Module only activates on a system with wifi enabled
                    networking.wireless.enable = true;
                }
            ];
        };
    };
}
```

## Options

The defaults should automatically get you on DEF CON wifi if the module is included.
It works by creating a systemd timer that tries hitting wifireg.defcon.org once per day,
and persisting the credentials into wpa_supplicant's env file if it gets an HTTP success.
If the credentials have already been persisted, it won't try (and the systemd timer is a no-op).

The username is derived from a hash of your hostname that changes every year; the password
is random.

There are some things you can tweak, but including the module should make it "just work":

|Option|Default|Description|
|:-----|:------|:----------|
|nixVegas.defcon|`34`|The current DEF CON number|
|nixVegas.dcWifi.enable|`true`|Enables automatic DC wifi registration|
|nixVegas.dcWifi.username|First 16 hex digits of `SHA256("dcwifi:${config.nixVegas.defcon}:${config.networking.hostName}")`|Change this if you don't like to follow the format we prescribe|
|nixVegas.dcWifi.randomUsername|`config.networkmanager.enable`|Set to true to use a random username for wifireg. Note that we enable this by default if NetworkManager is enabled. Turning this on without NetworkManager will add an overlay that applies a patch to wpa_supplicant to make it work.|
|nixVegas.dcWifi.usernameTemplate|`"<random:16-24>"`|Template to use for the username. Only template helper supported is "random", with an argument for the number of characters to generate (this will generate a 16-24 character random username for you via openssl)|
|nixVegas.dcWifi.passwordTemplate|`"<random:16-24>"`|Template to use for the password. See usernameTemplate.|
|nixVegas.dcWifi.caCert|(included)|The root CA cert. Sometimes wifireg.defcon.org only provides the bundle up to the root, we just provide the root that should allow that bundle to verify.|
|nixVegas.dcWifi.secretName|`dc##_<USERNAME>_wifi_pass`|The secret name, for wpa_supplicant to use.|
