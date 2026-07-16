{ pkgs, ... }: {
  programs.claude-code = {
    enable = true;
    settings = {
      ultracode = true;
      permissions = {
        allow = [
          "Bash(git init *)"
          "Bash(git add *)"
          "Bash(git commit *)"
          "Bash(git *)"
          "Bash(sudo mkosi summary)"
          "Bash(mkosi summary *)"
          "Bash(mkosi *)"
          "Bash(python3 -c \"import importlib.metadata; print\\(importlib.metadata.version\\('mkosi'\\)\\)\")"
          "Bash(python3 -c ' *)"
          "Bash(python3 *)"
          "Bash(pacman -Ql rust)"
          "Bash(rustup which *)"
          "Read(//home/matus/.cargo/bin/**)"
          "Bash(curl -s \"https://archlinux.org/packages/extra/x86_64/rust/\")"
          "Bash(chmod +x *)"
          "Bash(bash -n /var/home/matus/Dokumente/schule/demo-maturitna-praca/mkosi.extra/usr/local/sbin/oci-sysupdate)"
          "Bash(cargo vendor *)"
        ];
        defaultMode = "auto";
      };

      disableClaudeAiConnectors = true;

      statusLine = {
        type = "command";
        command = "~/.cargo/bin/ccbar";
        refreshInterval = 1;
      };

      enabledPlugins = {
        "superpowers@claude-plugins-official" = true;
        "explanatory-output-style@claude-plugins-official" = true;
        "learning-output-style@claude-plugins-official" = true;
        "clangd-lsp@claude-plugins-official" = true;
        "linux-computer@claude-linux-computer" = true;
      };

      extraKnownMarketplaces = {
        "claude-linux-computer" = {
          source = {
            source = "git";
            url = "https://github.com/Nige-l/claude-linux-computer.git";
          };
        };
      };

      skipWorkflowUsageWarning = true;
      theme = "dark";
      remoteControlAtStartup = true;
      inputNeededNotifEnabled = true;
      agentPushNotifEnabled = true;

      model = "claude-fable-5[1m]";
    };
  };
}
