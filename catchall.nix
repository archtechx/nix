{
  services.nginx.virtualHosts."catchall" = {
    default = true;
    locations."/".return = "444";
    rejectSSL = true;
  };
}
