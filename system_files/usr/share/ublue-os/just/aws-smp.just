# # Install/Update/Remove AWS CLI v2 and Session Manager Plugin for current user
[group('BI helpers')]
aws-smp-install:
    #!/usr/bin/bash
    echo "▶ Installing/updating AWS CLI and Session Manager Plugin to user local bins"
    /usr/share/ublue-os/just/scripts/aws-smp-install.sh install

[group('BI helpers')]
aws-smp-update:
    #!/usr/bin/bash
    echo "▶ Updating AWS CLI and Session Manager Plugin"
    /usr/share/ublue-os/just/scripts/aws-smp-install.sh update

[group('BI helpers')]
aws-smp-remove:
    #!/usr/bin/bash
    echo "▶ Removing AWS CLI and Session Manager Plugin from user local bins"
    /usr/share/ublue-os/just/scripts/aws-smp-install.sh remove

[group('BI helpers')]
aws-smp-status:
    #!/usr/bin/bash
    /usr/share/ublue-os/just/scripts/aws-smp-install.sh status
