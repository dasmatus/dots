<!--Claude fill in metadata, must autostart-->

# Context

For some reason, every time I run an agent on the installer (for any OS, not just dasmatus/dots), it breaks the install process. This skill tries to ensure that the process stays the same and can be reproduced across multiple configurations.

# What to do:

- Build the ISO and somehow use $RANDOM bash variable for VM's disk, CPU and RAM. Must be in a nested compositor, since the machine agent runs on is actively used
- Check if installer is broken by the time you made the changes and fix it if the install flow breaks in the VM.
  > [!NOTE]
  > For Claude agent that'll fill in the metadata: the sentence above must be broken down.
- Run through the installer in the VM using a script preferably in Nix that'll automatically go through the installer and capture each stage including triggers for each step in the install stage (not the confirm page - that works well).
