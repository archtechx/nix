{ name, domain, ssl ? false, extraNginxConfig ? null, sshKeys ? null, phpPackage, extraPackages ? [], queue ? false, queueArgs ? "", generateSshKey ? true, poolSettings ? {
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
}, ... }:

{ config, lib, pkgs, ... }:
let
  mkUsername = siteName: "laravel-${siteName}";
in {
  # Ensure nginx is enabled
  services.nginx.enable = true;

  # Setup ACME if SSL is enabled
  security.acme.acceptTerms = lib.mkIf ssl true;

  # Create welcome message for user
  environment.etc."laravel-${name}-bashrc".text = ''
    # Laravel site welcome message
    echo "Welcome to ${name} Laravel site!"
    echo "User home: /home/${mkUsername name}"
    echo "Site: /srv/${name}"
    echo "Restart php-fpm: sudo systemctl reload phpfpm-${name}"
    ${lib.optionalString queue ''echo "Restart queue: php artisan queue:restart"''}
    ${lib.optionalString generateSshKey ''echo "SSH public key: cat ~/.ssh/id_ed25519.pub"''}
    echo "---"
  '';

  # Ensure directories exist with proper permissions
  systemd.tmpfiles.rules = [
    "d /srv 0755 root root - -"
    "d /home 0755 root root - -"
    "d /srv/${name} 0755 ${mkUsername name} ${mkUsername name} - -"
    "C /home/${mkUsername name}/.bashrc 0644 ${mkUsername name} ${mkUsername name} - /etc/laravel-${name}-bashrc"
  ];

  # Laravel cron job for scheduler
  services.cron.systemCronJobs = [
    "* * * * * ${mkUsername name} cd /srv/${name} && ${phpPackage}/bin/php artisan schedule:run > /dev/null 2>&1"
  ];

  # Laravel queue worker service
  systemd.services."laravel-queue-${name}" = lib.mkIf queue {
    description = "Laravel Queue Worker for ${name}";
    after = [ "network.target" "phpfpm-${name}.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = mkUsername name;
      Group = mkUsername name;
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
  systemd.services."generate-ssh-key-${name}" = lib.mkIf generateSshKey {
    description = "Generate SSH key for ${mkUsername name}";
    wantedBy = [ "multi-user.target" ];
    after = [ "users.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };
    script = ''
      USER_HOME="/home/${mkUsername name}"
      SSH_DIR="$USER_HOME/.ssh"
      KEY_FILE="$SSH_DIR/id_ed25519"

      if [[ ! -f "$KEY_FILE" ]]; then
        echo "Generating SSH key for ${mkUsername name}"
        mkdir -p "$SSH_DIR"
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "${mkUsername name}@$(hostname)"
        chown -R ${mkUsername name}:${mkUsername name} "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chmod 600 "$KEY_FILE"
        chmod 644 "$KEY_FILE.pub"
        echo "SSH key generated: $KEY_FILE.pub"
        echo "Public key for deploy key:"
        cat "$KEY_FILE.pub"
      else
        echo "SSH key already exists for ${mkUsername name}"
      fi
    '';
  };

  # Nginx virtual host configuration
  services.nginx.virtualHosts.${domain} = {
    enableACME = ssl;
    forceSSL = ssl;
    root = "/srv/${name}/public";

    extraConfig = ''
      add_header X-Frame-Options "SAMEORIGIN";
      add_header X-Content-Type-Options "nosniff";
      charset utf-8;
      index index.php;
      error_page 404 /index.php;
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
  };

  # PHP-FPM pool configuration
  services.phpfpm.pools.${name} = {
    user = mkUsername name;
    phpPackage = phpPackage;
    settings = poolSettings // {
      "listen.owner" = config.services.nginx.user;
    };
  };

  # User and group settings
  users.users.${mkUsername name} = {
    group = mkUsername name;
    isSystemUser = true;
    createHome = true;
    home = "/home/${mkUsername name}";
    homeMode = "750";
    shell = pkgs.bashInteractive;
    packages = [ phpPackage pkgs.git pkgs.unzip phpPackage.packages.composer ] ++ extraPackages;
  } // lib.optionalAttrs (sshKeys != null) {
    openssh.authorizedKeys.keys = sshKeys;
  };

  users.groups.${mkUsername name} = {};

  # Add site group to nginx service
  systemd.services.nginx.serviceConfig.SupplementaryGroups = [ (mkUsername name) ];

  # Sudo rule for reloading PHP-FPM
  security.sudo.extraRules = [{
    users = [ (mkUsername name) ];
    commands = [
      {
        command = "/run/current-system/sw/bin/systemctl reload phpfpm-${name}";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl reload phpfpm-${name}.service";
        options = [ "NOPASSWD" ];
      }
    ];
  }];
}
