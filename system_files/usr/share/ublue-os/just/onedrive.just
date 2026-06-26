# OneDrive: enable service (if needed), stop it, authenticate, then start it
[group('BI helpers')]
onedrive:
    #!/usr/bin/bash
    /usr/share/ublue-os/just/scripts/onedrive.sh
