# Nix scripts

A collection of scripts and configuration files for our use of Nix tooling.

> [!NOTE]
> You may want to read [**this article**](https://stancl.substack.com/p/deploying-laravel-on-nixos) for more detailed information.

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
  poolSettings = { # optional - overrides all of our defaults
    "pm.max_children" = 12;
    "php_admin_value[opcache_memory_consumption]" = "512";
    "php_admin_flag[opcache.validate_timestamps]" = true;
  };
  # alternatively:
  extraPoolSettings = { # merged with poolSettings, doesn't override our defaults
    "pm.max_children" = 12;
  }
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

To deploy your app, you can use
[ssh deployments](https://stancl.substack.com/i/170830424/setting-up-deployments),
rather than webhooks triggering pull hooks or other techniques. Since this module
creates a new user for each site, this deployment technique becomes non-problematic
and it's one of the simplest things you can do. Just ssh-keygen a private key, make a
GitHub Actions job use that on push, and include the public key in the site's `sshKeys` array.
Then, to be able to `git pull` the site on the server, add the user's `~/.ssh/id_ed25519.pub`
to the repository's deployment keys. The ssh key for the user is generated automatically
(can be disabled by setting `generateSshKey` to false).

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

To redirect `www.acme.com` to `acme.com`, you can use the `wwwRedirect` attribute. It should be
null for no redirect, or an integer status code for an enabled redirect.

```nix
(laravelSite {
  name = "foo";
  domains = [ "foo.com" ]
  wwwRedirect = 301; # permanent redirect
  # ...
})
```

With the config above, `www.foo.com/bar` will return a redirect to `foo.com/bar`, with the schema
matching the site's `ssl` config.

### Default nginx server

Out of the box, if nginx cannot match an incoming request's host to a specific virtual host it will
just use _some_ vhost. You can prevent behavior that by adding a module like this:

> [!NOTE]
> You can also use the `catchall.nix` module here (which includes the code below):
>
> `scp catchall.nix root@<server ip>:/etc/nixos/`
>
> Then just add `./catchall.nix` to your modules array.

```nix
{
  services.nginx.virtualHosts."catchall" = {
    default = true;
    locations."/".return = "444";
    rejectSSL = true;
  };
}
```

This creates a `default_server` vhost that returns an empty response to any request. The name of the
vhost is irrelevant.

### Authenticated Origin Pulls (AOP)

To make your sites reachable ONLY using Cloudflare, you can use [authenticated origin
pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/).

AOP basically ensures that any SSL traffic is using Cloudflare's "client certificate". With
all non-HTTPS traffic being presumably force-redirected to HTTPS (`ssl = true;`).

This means that if someone discovers your server's IP, they can send requests bypassing
Cloudflare (and all the settings you may have there), but they will go nowhere. Nginx will
see they don't have the client certificate and simply return a 400 error ("No required SSL
certificate was sent"). The requests will never reach your Laravel application.

There are many ways this can be configured. Some people prefer using their own client certificates
but Cloudflare lets you use a default global one. That means less config and unless you have some
very special needs, it will work perfectly fine for this purpose.

To enable AOP on the server, simply set:
```nix
cloudflareOnly = true;
```

in the site config. This will automatically add:
```nginx
ssl_verify_client on;
ssl_client_certificate "path to Cloudflare's default cert";
```

Then just enable AOP in the `SSL/TLS -> Origin Server` setting of your CF zone.

> The only caveat with using AOP is that you will not be able to access your app directly
> *even from the same server* -- HTTP requests will be redirected to HTTPS and HTTPS will
> fail due to a missing certificate. **But this is generally not an issue in practice** since
> the server config we use doesn't use any special hosts records that'd try to bypass CF.
> So running `curl https://your-app.com` on the server will work without issues. The only
> thing that will NOT work is:
> ```sh
> curl --resolve your-app.com:443:127.0.0.1 https://your-app.com/
> curl --connect-to your-app.com:443:127.0.0.1:443 https://your-app.com/
> ```
> And any equivalents.

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

    return request()->header('CF-Connecting-IP') ?: request()->ip();
}
```

However a more proper solution is to use the `real_ip` module in common nginx config. To do that,
we can follow the [guide from the NixOS
wiki](https://nixos.wiki/wiki/Nginx#Using_realIP_when_behind_CloudFlare_or_other_CDN).

> [!NOTE]
> You can also use the `realip.nix` module here (which wraps the code below):
>
> `scp realip.nix root@<server ip>:/etc/nixos/`
>
> Then just add `./realip.nix` to your modules array.

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

## Static sites

For hosting static sites, you can use `static.nix` very similarly to `laravel.nix`. Notable differences:
1. `root` is required, e.g. `name="foo"; root="build";` means `/srv/foo/build` will be served. In other
   words, even though this is for static sites, we do not serve the entire `/srv/{name}` dir to allow
   for version control and build steps.
2. By default, the `static-generic` user is used. Static sites do not always need strict user separation
   since there's no request runtime. That said, the user is *very* limited and only has `pkgs.git` and
   `pkgs.unzip`. Therefore it's only suited for static sites that are at most pulled from somewhere,
   rather than built using Node.js. Also note that GitHub generally doesn't allow using a single SSH key
   as the deploy key on multiple repos. For these reasons, it's still recommended to enable user creation
   via `user = true;`.

Full usage:
```nix
(staticSite {
  name = "foo"; # name of the site
  root = "build"; # directory within /srv/foo to be served by nginx

  user = true; # if false, static-generic is used. Default: false
  domains = [ "foo.com" "bar.com" ]; # domains to serve the site on
  ssl = true; # enableACME + forceSSL. Default: false
  # Status code for www-to-non-www redirects. No redirect if null. Applies to all sites
  wwwRedirect = 301; # Default: null
  cloudflareOnly = true; # use Authenticated Origin Pulls. See the dedicated section. Default: false
  extraPackages = [ pkgs.nodejs_24 ]; # only applies if user=true
  generateSshKey = true; # defaults to true, used even with user=false
  sshKeys = [ "array" "of" "public" "ssh" "keys" ]; # optional
  extraNginxConfig = "nginx configuration string"; # optional
})
```

## Maintenance

It's a good idea to have `/etc/nixos` tracked in version control so you can easily revert the config
including the lockfile, not just system state.

The only thing in your lockfile should be `nixpkgs` unless you add more inputs to your system config.

After rebuilding the system several times, you will have some past generations and unused files in the Nix
store that can be cleaned up.

List past generations with:
```sh
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
```

Delete old ones:
```sh
sudo nix-env --delete-generations old --profile /nix/var/nix/profiles/system
```

Then clean garbage:
```sh
sudo nix-collect-garbage -d
```

## Rebuilding

From personal testing, running `nixos-rebuild switch` doesn't necessarily cause any downtime for users
if your website is behind Cloudflare. NixOS first builds everything it needs and only then, usually pretty
quickly, restarts (and adds, removes, etc) services as needed. This means your nginx **might** be down for
a very brief period, but if Cloudflare cannot connect to your server it will retry a couple of times. So at
most some requests will be very slightly delayed, but users should not see any errors on most rebuilds.
