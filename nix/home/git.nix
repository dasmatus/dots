{ pkgs, ... }: {
  programs.git = {
    enable = true;
    package = pkgs.git.override { withLibsecret = true; };
    settings = {
      user = {
        name = "Matus Mastena";
        email = "Shadiness9530@proton.me";
      };
      credential.helper = "libsecret";
    };
  };
}
