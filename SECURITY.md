# Security Policy

## Supported Versions

The `latest` and `stable` image streams are maintained and receive security updates through their normal build and release process. Dated tags are snapshots of a stream build and do not receive updates; move to the current stream tag to receive fixes. `feat-*` images are for testing and are not supported for production use.

## Reporting a Vulnerability

Please do not report security vulnerabilities in public issues or discussions.

Report vulnerabilities privately through [GitHub's security advisory reporting page](https://github.com/Boehringer-Ingelheim/fobic/security/advisories/new). If private vulnerability reporting is unavailable, contact the repository maintainers privately through the Boehringer Ingelheim GitHub organization and request a secure reporting channel.

Include the affected image tag or digest, the relevant commit if known, steps to reproduce, and the potential impact. Please redact credentials, personal data, and other sensitive information from reports and logs.

The maintainers will acknowledge reports as soon as practical and coordinate investigation, remediation, and disclosure with the reporter. Please allow time for a fix to be prepared before sharing details publicly.

## Image Signing Incidents

If you suspect the FOBIC image-signing key has been exposed or misused, report it privately using the process above. See [Image Signing & Verification](docs/image-signing.md#4-incident-response-leaked-signing-key) for the key-rotation and incident-response procedure.
