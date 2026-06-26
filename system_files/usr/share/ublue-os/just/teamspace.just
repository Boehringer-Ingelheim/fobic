# Manage Teamspace AWS profiles & SSH config — select action interactively
[group('BI helpers')]
teamspace-manage:
    #!/usr/bin/bash
    /usr/share/ublue-os/just/scripts/manage-teamspace-config.sh

# Connect to a Teamspace EC2 instance via SSH over SSM
[group('BI helpers')]
teamspace-connect:
    #!/usr/bin/bash
    /usr/share/ublue-os/just/scripts/teamspace-connect-ssh.sh

# Forward a port through a Teamspace EC2 instance via SSM
[group('BI helpers')]
teamspace-tunnel:
    #!/usr/bin/bash
    /usr/share/ublue-os/just/scripts/teamspace-tunnel.sh
