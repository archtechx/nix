{
  name, # Name of the site, /srv/{name} will be based on this as well as the username if user = true
  root, # The directory within /srv/{name} that should be served by nginx
  user ? false, # Should a user be created. If false, static-generic is used
  domains ? [], # e.g. [ "example.com" "acme.com" ]
  ssl ? false, # Should SSL be used
  wwwRedirect ? null, # The status code used for www-to-non-www redirects. Null means no redirect
  cloudflareOnly ? false, # Should CF Authenticated Origin Pulls be used
  extraNginxConfig ? null, # Extra nginx config string
  sshKeys ? null, # SSH public keys used to log into the site's user for deployments
  extraPackages ? [], # Any extra packages the user should have in $PATH (only used with user=true)
  generateSshKey ? true, # Generate an SSH key for the user (used for GH deploy keys)
  ...
}:

{ lib, pkgs, ... }:
let
  username = if user then "static-${name}" else "static-generic";
in {
  services.nginx.enable = true;
  security.acme.acceptTerms = true;
  networking.firewall.allowedTCPPorts = [ 80 ] ++ lib.optionals ssl [ 443 ];

  services.nginx.virtualHosts = lib.genAttrs domains (domain: {
    enableACME = ssl;
    forceSSL = ssl;
    root = "/srv/${name}/${root}";

    extraConfig = ''
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
      "= /favicon.ico".extraConfig = ''
        access_log off;
        log_not_found off;
      '';

      "= /robots.txt".extraConfig = ''
        access_log off;
        log_not_found off;
      '';
    };
  }) // lib.optionalAttrs (wwwRedirect != null) (lib.genAttrs (map (domain: "www.${domain}") domains) (wwwDomain: {
    enableACME = ssl;
    forceSSL = ssl;

    locations."/" = {
      return = "${toString wwwRedirect} ${if ssl then "https" else "http"}://${lib.removePrefix "www." wwwDomain}$request_uri";
    };
  }));

  systemd.tmpfiles.rules = [
    "d /srv 0751 root root - -"
    "d /home 0751 root root - -"
    "d /srv/${name} 0750 ${username} ${username} - -"
  ] ++ lib.optional user
    "C /home/${username}/.bashrc 0640 ${username} ${username} - /etc/static-${name}-bashrc";

  # User and group settings
  users.users.${username} = {
    group = username;
    isSystemUser = true;
    createHome = true;
    home = "/home/${username}";
    homeMode = "750";
    shell = pkgs.bashInteractive;
    packages = [ pkgs.git pkgs.unzip ] ++ lib.optionals user extraPackages;
  } // lib.optionalAttrs (sshKeys != null && user) {
    openssh.authorizedKeys.keys = sshKeys;
  };

  users.groups.${username} = {};

  # Add site group to nginx service
  systemd.services.nginx.serviceConfig.SupplementaryGroups = [ username ];

  # SSH key generation for git deployments
  # Note: keep in sync with laravel.nix
  systemd.services."generate-ssh-key-${username}" = lib.mkIf generateSshKey {
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

  # Create welcome message for user
  # Note: keep in sync with laravel.nix (same block, minor changes here)
  environment.etc."static-${name}-bashrc" = lib.mkIf user {
    text = ''
      echo "Welcome to ${name} static site!"
      echo "Domains: ${lib.concatStringsSep ", " domains}"
      echo "User home: /home/${username}"
      echo "Site: /srv/${name}"
        ${lib.optionalString generateSshKey ''echo "SSH public key: cat ~/.ssh/id_ed25519.pub"''}
      echo "---"
    '';
  } ;
}
