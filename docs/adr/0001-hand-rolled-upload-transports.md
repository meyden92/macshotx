# Hand-rolled upload transports, no third-party SDKs

PRD §10.2 originally planned an S3 client and an SFTP client package via SwiftPM. Instead, S3 uploads sign requests with a hand-rolled AWS SigV4 implementation (`S3Uploader.swift`), and SFTP/FTP shell out to the system's own `/usr/bin/sftp` and `/usr/bin/curl` — the upload layer has zero third-party dependencies. This trades implementation effort (signing, subprocess plumbing) for a smaller supply-chain surface and no SDK version churn, consistent with CONTRIBUTING.md's "no new third-party dependencies without prior discussion" policy.
