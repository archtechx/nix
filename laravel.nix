{
  name, # Name of the site, the username and /srv/{name} will be based on this
  phpPackage, # e.g. pkgs.php84
  domains ? [], # e.g. [ "example.com" "acme.com" ]
  ssl ? false, # Should SSL be used
  wwwRedirect ? null, # The status code used for www-to-non-www redirects. Null means no redirect
  cloudflareOnly ? false, # Should CF Authenticated Origin Pulls be used
  extraNginxConfig ? null, # Extra nginx config string
  sshKeys ? null, # SSH public keys used to log into the site's user for deployments
  extraPackages ? [], # Any extra packages the user should have in $PATH
  queue ? false, # Should a queue worker systemd service be created
  queueArgs ? "", # Extra args for the queue worker (e.g. "--tries=2")
  generateSshKey ? true, # Generate an SSH key for the user (used for GH deploy keys)
  poolSettings ? { # PHP-FPM pool settings. Changing this will override all of these defaults
      "pm" = "dynamic";
      "pm.max_children" = 8;
      "pm.start_servers" = 2;
      "pm.min_spare_servers" = 1;
      "pm.max_spare_servers" = 3;
      "pm.max_requests" = 200;

      "php_admin_flag[opcache.enable]" = true;
      "php_admin_value[opcache.memory_consumption]" = "256";
      "php_admin_value[opcache.max_accelerated_files]" = "10000";
      "php_admin_value[opcache.revalidate_freq]" = "0";
      "php_admin_flag[opcache.validate_timestamps]" = false;
      "php_admin_flag[opcache.save_comments]" = true;
  },
  extraPoolSettings ? {}, # PHP-FPM pool settings merged into poolSettings. Doesn't override defaults
  ...
}:

{ config, lib, pkgs, ... }:
let
  username = "laravel-${name}";
in {
  services.nginx.enable = true;
  security.acme.acceptTerms = lib.mkIf ssl true;

  # This doesn't override the array, only merges 80 and potentially 443 into it
  networking.firewall.allowedTCPPorts = [ 80 ] ++ lib.optionals ssl [ 443 ];

  # Create welcome message for user
  # todo: the created /etc file should ideally be 0750
  # Note: keep in sync with static.nix
  environment.etc."laravel-${name}-bashrc".text = ''
    export PATH="$HOME/.config/composer/vendor/bin/:$PATH"

    # Laravel site welcome message
    echo "Welcome to ${name} Laravel site!"
    echo "Domains: ${lib.concatStringsSep ", " domains}"
    echo "User home: /home/${username}"
    echo "Site: /srv/${name}"
    echo "Restart php-fpm: sudo systemctl reload phpfpm-${name}"
    ${lib.optionalString queue ''echo "Restart queue: php artisan queue:restart"''}
    ${lib.optionalString queue ''echo "Queue status: sudo systemctl status laravel-queue-${name}"''}
    ${lib.optionalString generateSshKey ''echo "SSH public key: cat ~/.ssh/id_ed25519.pub"''}
    echo "---"
  '';

  # Ensure directories exist with proper permissions
  systemd.tmpfiles.rules = [
    "d /srv 0751 root root - -"
    "d /home 0751 root root - -"
    "d /srv/${name} 0750 ${username} ${username} - -"
    "C /home/${username}/.bashrc 0640 ${username} ${username} - /etc/laravel-${name}-bashrc"
  ];

  services.cron.systemCronJobs = [
    "* * * * * ${username} cd /srv/${name} && ${phpPackage}/bin/php artisan schedule:run > /dev/null 2>&1"
  ];

  # Laravel queue worker service
  systemd.services."laravel-queue-${name}" = lib.mkIf queue {
    description = "Laravel Queue Worker for ${name}";
    after = [ "network.target" "phpfpm-${name}.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = username;
      Group = username;
      WorkingDirectory = "/srv/${name}";
      ExecStart = "${phpPackage}/bin/php artisan queue:work ${queueArgs}";
      Restart = "always";
      RestartSec = 10;
      KillMode = "mixed";
      KillSignal = "SIGTERM";
      TimeoutStopSec = 60;
    };
  };

  # SSH key generation for git deployments
  # Note: keep in sync with static.nix
  systemd.services."generate-ssh-key-${name}" = lib.mkIf generateSshKey {
    description = "Generate SSH key for ${username}";
    wantedBy = [ "multi-user.target" ];
    after = [ "users.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };
    script = ''
      USER_HOME="/home/${username}"
      SSH_DIR="$USER_HOME/.ssh"
      KEY_FILE="$SSH_DIR/id_ed25519"

      if [[ ! -f "$KEY_FILE" ]]; then
        echo "Generating SSH key for ${username}"
        mkdir -p "$SSH_DIR"
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "${username}"
        chown -R ${username}:${username} "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chmod 600 "$KEY_FILE"
        chmod 640 "$KEY_FILE.pub"
        echo "SSH key generated: $KEY_FILE.pub"
        echo "Public key for deploy key:"
        cat "$KEY_FILE.pub"
      else
        echo "SSH key already exists for ${username}"
      fi
    '';
  };

  # Nginx virtual host configuration
  # Note: these assignments within modules do NOT override the existing value that
  # virtualHosts may have. Instead, all vhost configurations get merged into one.
  services.nginx.virtualHosts = lib.genAttrs domains (domain: {
    enableACME = ssl;
    forceSSL = ssl;
    root = "/srv/${name}/public";

    extraConfig = ''
      add_header X-Frame-Options "SAMEORIGIN";
      add_header X-Content-Type-Options "nosniff";
      charset utf-8;
      index index.php;
      error_page 404 /index.php;
      ${lib.optionalString cloudflareOnly ''
      ssl_verify_client on;
      ssl_client_certificate ${pkgs.fetchurl {
        url = "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem";
        sha256 = "0hxqszqfzsbmgksfm6k0gp0hsx9k1gqx24gakxqv0391wl6fsky1";
      }};
      ''}
      ${lib.optionalString (extraNginxConfig != null) extraNginxConfig}
    '';

    locations = {
      "/" = {
        tryFiles = "$uri $uri/ /index.php?$query_string";
      };

      "= /favicon.ico".extraConfig = ''
        access_log off;
        log_not_found off;
      '';

      "= /robots.txt".extraConfig = ''
        access_log off;
        log_not_found off;
      '';

      "~ ^/index\\.php(/|$)".extraConfig = ''
        fastcgi_pass unix:${config.services.phpfpm.pools.${name}.socket};
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include ${pkgs.nginx}/conf/fastcgi_params;
        fastcgi_hide_header X-Powered-By;
      '';

      "~ /\\.(?!well-known).*".extraConfig = ''
        deny all;
      '';
    };
  }) // lib.optionalAttrs (wwwRedirect != null) (lib.genAttrs (map (domain: "www.${domain}") domains) (wwwDomain: {
    enableACME = ssl;
    forceSSL = ssl;

    locations."/" = {
      return = "${toString wwwRedirect} ${if ssl then "https" else "http"}://${lib.removePrefix "www." wwwDomain}$request_uri";
    };
  }));

  # PHP-FPM pool configuration
  services.phpfpm.pools.${name} = {
    user = username;
    phpPackage = phpPackage;
    settings = poolSettings // extraPoolSettings // {
      "listen.owner" = config.services.nginx.user;
    };
  };

  # User and group settings
  users.users.${username} = {
    group = username;
    isSystemUser = true;
    createHome = true;
    home = "/home/${username}";
    homeMode = "750";
    shell = pkgs.bashInteractive;
    packages = [ phpPackage pkgs.git pkgs.unzip phpPackage.packages.composer ] ++ extraPackages;
  } // lib.optionalAttrs (sshKeys != null) {
    openssh.authorizedKeys.keys = sshKeys;
  };

  users.groups.${username} = {};

  # Add site group to nginx service
  systemd.services.nginx.serviceConfig.SupplementaryGroups = [ username ];

  # Sudo rules for service management
  security.sudo.extraRules = [{
    users = [ username ];
    commands = [
      {
        command = "/run/current-system/sw/bin/systemctl reload phpfpm-${name}";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl reload phpfpm-${name}.service";
        options = [ "NOPASSWD" ];
      }
    ] ++ lib.optionals queue [
      {
        command = "/run/current-system/sw/bin/systemctl status laravel-queue-${name}";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl status laravel-queue-${name}.service";
        options = [ "NOPASSWD" ];
      }
    ];
  }];
}
