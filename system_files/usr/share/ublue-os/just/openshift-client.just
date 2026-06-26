# # Install/Update/Remove OpenShift client (oc/kubectl) for current user
[group('BI helpers')]
openshift-client-install:
    #!/usr/bin/bash
    echo "▶ Installing/updating OpenShift client to user local bins"
    /usr/share/ublue-os/just/scripts/openshift-client-install.sh install

[group('BI helpers')]
openshift-client-update:
    #!/usr/bin/bash
    echo "▶ Updating OpenShift client"
    /usr/share/ublue-os/just/scripts/openshift-client-install.sh update

[group('BI helpers')]
openshift-client-remove:
    #!/usr/bin/bash
    echo "▶ Removing OpenShift client from user local bins"
    /usr/share/ublue-os/just/scripts/openshift-client-install.sh remove

[group('BI helpers')]
openshift-client-status:
    #!/usr/bin/bash
    /usr/share/ublue-os/just/scripts/openshift-client-install.sh status
