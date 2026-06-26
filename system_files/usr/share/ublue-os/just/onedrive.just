# # OneDrive helpers (call scripts installed to /usr/share/ublue-os/just/scripts)
[group('BI helpers')]
onedrive-auth:
    #!/usr/bin/bash
    /usr/share/ublue-os/just/scripts/onedrive.sh auth

[group('BI helpers')]
onedrive-service:
    #!/usr/bin/bash
    /usr/share/ublue-os/just/scripts/onedrive.sh service
