# Nix scripts

A collection of scripts and configuration files for our use of Nix tooling.

## Setting up a new server

This is just for getting a working NixOS installation with `/etc/nixos/configuration.nix` deployed onto a generic cloud VM.

The setup also uses `/etc/nixos/flake.nix` since that's an easy way of addressing
[the nixos-anywhere NIX_PATH issue](https://nix-community.github.io/nixos-anywhere/howtos/nix-path.html)
and you likely want to use flakes anyway.

**Note: All of the automated scripts for the steps below assume you're logging in as root**. If that's not the case, just follow
the steps manually. The scripts will also create lockfiles in `anywhere/` and `postinstall/` to make future deployments consistent
and faster (by reusing more things from your nix store). Feel free to delete those if you want a completely fresh install each time.

This section is overall just a thin wrapper around nixos-anywhere.

### Installing NixOS

- Provision a new server. This config works on Hetzner Cloud, may require adjustments for other
  providers, see anywhere/flake.nix
    - The default config uses `aarch64`, you can change this to `x86_64`
- Preferably use passwordless auth with just your SSH key

> Cross-compilation is sometimes buggy so it's recommended to run this on Linux (use a NixOS VM if you're on macOS), preferably
> matching the server's ISA. On macOS I highly recommend creating a NixOS VM (helpful for development anyway) in Parallels with
> no desktop environment, ssh enabled, and shared folders.
>
> That said, running this on macOS *should* still work fine, again ideally on the same ISA as the server (hence the aarch64 default).

Now either run `(cd anywhere && ./auto.sh <server_ip> <path_to_your_ssh_key>)`, with the path being e.g. `~/.ssh/id_ed25519.pub`. Or
if you want to do this manually (or make customizations):
- **Put the key into anywhere/configuration.nix (the REPLACEME) so you can log in after NixOS is installed**
- Run `nix run nixpkgs#nixos-anywhere -- --flake .#cloud root@<your-server-ip>`
    - Replace the output name if you've changed it
    - The user doesn't have to be root but has to be able to `sudo` without entering a password
    - You need Nix installed with the `nix-command` experimental feature enabled.
      If this doesn't work for you on macOS, you can run this from a VM (preferably matching the server ISA).
- If everything goes well, the server will reboot. Shortly after that you should be able to ssh into the server and get root access
    - The server will also have a new SSH key, so you'll have to clear old records from `~/.ssh/known_hosts`

### Adding basic configuration

**Make sure you've removed the server's previous key from `~/.ssh/known_hosts` if you've connected to the server before!**

Following successful installation, run `(cd postinstall && ./auto.sh <server_ip> <path_to_your_ssh_key>)` (once the server has rebooted). Or if you want to
do this manually:
- ssh into the server and run `nixos-generate-config`
- replace `/etc/nixos/configuration.nix` with `postinstall/configuration.nix` from this repo
- copy `postinstall/flake.nix` to `/etc/nixos/flake.nix`
- `nixos-rebuild switch`

### Next steps

Configure your NixOS server as you want. The only things to keep in mind are:
- there are no channels configured
- it's using a flake for the system config and setting the nix path in `/etc/nixos/flake.nix`
- the server's hostname is nixos

You may want to change the hostname, pull in some flake with system config for that particular hostname, or you
may want to just import some modules into your config.

## Setting up a Laravel app

After you have a NixOS server set up, you can use our `laravel.nix` module to start configuring Laravel sites.

The module is fairly generic so it should work for most sites. It's written in a simple way, to be as easy to
customize as possible if needed, while offering enough customization for most applications.

Import the module in your system flake and invoke it with these parameters:
```nix
(laravelSite {
  name = "mysite";
  domains = [ "mysite.com" ];
  phpPackage = pkgs.php84;

  ssl = true; # optional, defaults to false, affects *ALL* domains
  extraNginxConfig = "nginx configuration string"; # optional
  sshKeys = [ "array" "of" "public" "ssh" "keys" ]; # optional
  extraPackages = [ pkgs.nodejs_24 ]; # optional
  queue = true; # start a queue worker - defaults to false, optional
  queueArgs = "--tries=3"; # optional, default empty
  generateSshKey = false; # optional, defaults to true
  poolSettings = { # optional
    "pm.max_children" = 12;
    "php_admin_value[opcache_memory_consumption]" = "512";
    "php_admin_flag[opcache.validate_timestamps]" = true;
  };
})
```

The module creates a new user (`laravel-${name}`), a `/srv/${name}` directory, configures
cron to run every minute optionally starts a queue worker and configures php-fpm with
good defaults (see below). The user has a home directory in `/home/laravel-${name}`
(used mainly for `./cache` used by composer and npm) and the site is served from the srv
directory.

The default php-fpm opcache configuration is to cache everything *forever* without any
revalidation. Therefore, make sure to include `sudo systemctl reload phpfpm-${name}` in
your deployment script.

To deploy your app, you can use ssh deployments, rather than webhooks triggering pull hooks
or other techniques. Since this module creates a new user for each site, this deployment
technique becomes non-problematic and it's one of the simplest things you can do. Just
ssh-keygen a private key, make a GitHub Actions job use that on push, and include the
public key in the site's `sshKeys` array. Then, to be able to `git pull` the site on the
server, add the user's `~/.ssh/id_ed25519.pub` to the repository's deployment keys. The
ssh key for the user is generated automatically (can be disabled by setting `generateSshKey`
to false).

Also, if you're using `ssl` you should put this line into your system config:
```nix
security.acme.defaults.email = "your@email.com";
```

A full system config can look something like this (excluding any additional configuration
you may want to make):
```nix
{
  description = "System flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations = let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      laravelSite = import ./laravel.nix;
    in {
      nixos = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          {
            nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];
            security.acme.defaults.email = "your@email.com";
          }
          ./configuration.nix

          # your (laravelSite { ... }) calls here
        ];
      };
    };
  };
}
```

There's a million different ways to structure your system flake, so you may prefer to use
something different. Note that `laravel.nix` is explicitly not a flake and not a top-level
"input" - the goal is to just invoke it each time *to change system configuration*. We don't
want an additional lockfile for the laravel module and we don't want to update the system
lockfile whenever we make changes to the laravel module. With the most basic configuration,
you should only have `nixpkgs` in your lockfile.

There also isn't any special shell since Laravel is entirely handled by system daemons like
nginx, php-fpm, cron, and optionally a queue worker systemd service. We do include a .bashrc
with some echos to quickly remind you of the filesystem structure and available commands.

Simply `scp laravel.nix root@<your server ip>:/etc/nixos/` and start writing config as above.

### www redirects

The module doesn't handle www redirects automatically. This may be added in the future.

At this time, I'd recommend handling basic redirects like that on Cloudflare.

### Using real_ip with Cloudflare

If you use Cloudflare, your access log (`/var/log/nginx/access.log`) will show Cloudflare IPs
instead of the actual remote IPs. This also affects what IPs are passed to php-fpm and therefore
Laravel. If you don't care about the access log, you can just make a simple helper like this in
PHP:

```php
<?php
function client_ip(): string
{
    if ($ipv6 = request()->header('CF-Connecting-IPv6')) {
        return $ipv6;
    }

    return request()->hasHeader('CF-Connecting-IP')
        ? request()->header('CF-Connecting-IP')
        : request()->ip();
}
```

However a more proper solution is to use the `real_ip` module in common nginx config. To do that,
we can follow the [guide from the NixOS wiki
](https://nixos.wiki/wiki/Nginx#Using_realIP_when_behind_CloudFlare_or_other_CDN).

```nix
# New module in your modules array
{
  services.nginx.commonHttpConfig =
    let
      realIpsFromList = lib.strings.concatMapStringsSep "\n" (x: "set_real_ip_from  ${x};");
      fileToList = x: lib.strings.splitString "\n" (builtins.readFile x);
      cfipv4 = fileToList (pkgs.fetchurl {
        url = "https://www.cloudflare.com/ips-v4";
        sha256 = "0ywy9sg7spafi3gm9q5wb59lbiq0swvf0q3iazl0maq1pj1nsb7h";
      });
      cfipv6 = fileToList (pkgs.fetchurl {
        url = "https://www.cloudflare.com/ips-v6";
        sha256 = "1ad09hijignj6zlqvdjxv7rjj8567z357zfavv201b9vx3ikk7cy";
      });
    in
    ''
      ${realIpsFromList cfipv4}
      ${realIpsFromList cfipv6}
      real_ip_header CF-Connecting-IP;
    '';
}
```

To make `lib` accessible, also update:
```diff
 nixosConfigurations = let
   system = "aarch64-linux";
   pkgs = nixpkgs.legacyPackages.${system};
+  lib = pkgs.lib;
   laravelSite = import ./laravel.nix;
 in {
```

To check the up-to-date hashes, you can use:

```sh
curl -s https://www.cloudflare.com/ips-v4 | sha256 | xargs nix hash convert --hash-algo sha256 --to nix32
curl -s https://www.cloudflare.com/ips-v6 | sha256 | xargs nix hash convert --hash-algo sha256 --to nix32
```
